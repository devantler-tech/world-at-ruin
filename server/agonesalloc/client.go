// Package agonesalloc reserves envelope-ready zone GameServers through
// Agones's generated allocation API.
package agonesalloc

import (
	"context"
	"encoding/base64"
	"errors"
	"strings"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// ErrUnallocated is the allocator's own answer that one allocation request
// allocated no GameServer: Agones's UnAllocated state (no Ready GameServer
// matched the selector — an empty pool) or its Contention state. Every other
// failure, including a transport-generated status that shares one of those
// codes, keeps its own status because it cannot prove nothing was allocated.
//
// Agones retries a request whose GameServer update it saw fail, and answers
// UnAllocated once a retry finds no Ready GameServer — yet a failed update can
// still have committed. So this proves the allocator completed no allocation
// for the request, not that no write it sent can still land. A caller that
// treats it as terminal must release by the exact attempt label before
// forgetting the attempt.
var ErrUnallocated = status.Error(
	codes.ResourceExhausted,
	"agonesalloc: no GameServer was allocated",
)

// unallocatedAnswers are the exact statuses the pinned Agones allocator
// returns for those two states (pkg/allocation/converters). UnAllocated
// carries the allocator's configured unallocated code, ResourceExhausted by
// default; an allocator configured with another code falls back to the
// ambiguous outcome, which only costs availability. Matching the message as
// well as the code keeps a gRPC transport limit or a proxy's rate limit, which
// also report ResourceExhausted, out of the terminal outcome.
var unallocatedAnswers = []struct {
	code    codes.Code
	message string
}{
	{codes.ResourceExhausted, "there is no available GameServer to allocate"},
	{codes.Aborted, "too many concurrent requests have overwhelmed the system"},
}

func unallocated(err error) bool {
	answer, ok := status.FromError(err)
	if !ok {
		return false
	}
	for _, known := range unallocatedAnswers {
		if answer.Code() == known.code && answer.Message() == known.message {
			return true
		}
	}
	return false
}

const (
	fleetLabel       = agones.FleetLabel
	reservationLabel = "world-at-ruin.dev/handoff-reservation"
	attemptLabel     = agones.AttemptLabel

	leaseObjectIDLength       = 64
	admissionEnvelopePrefix   = "v1."
	claimLocatorPrefix        = "v1."
	minAdmissionEnvelopeBytes = 384
	maxAdmissionEnvelopeBytes = 4096
)

// Config identifies the envelope-ready GameServer pool and its player-facing
// TLS port.
type Config struct {
	Namespace              string
	Fleet                  string
	TLSPortName            string
	WrappingKeyFingerprint string
}

// Request carries only opaque allocation correlation values.
type Request struct {
	ReservationID string
	AttemptID     string
	LeaseObjectID string
}

// GameServer is the allocated zone endpoint material this boundary trusts.
type GameServer struct {
	Name                   string
	Port                   uint16
	WrappingKeyFingerprint string
	AdmissionEnvelope      string
}

// Client reserves GameServers through Agones's generated gRPC API.
type Client struct {
	api         allocationpb.AllocationServiceClient
	namespace   string
	fleet       string
	tlsPortName string
	fingerprint string
	readyValue  string
}

// NewClient builds an Agones allocation boundary.
func NewClient(api allocationpb.AllocationServiceClient, cfg Config) (*Client, error) {
	if api == nil {
		return nil, errors.New("agonesalloc: allocation API is required")
	}
	if !validDNSLabel(cfg.Namespace) {
		return nil, errors.New("agonesalloc: namespace is invalid")
	}
	if !validFleetName(cfg.Fleet) {
		return nil, errors.New("agonesalloc: fleet is invalid")
	}
	if !validDNSLabel(cfg.TLSPortName) {
		return nil, errors.New("agonesalloc: TLS port name is invalid")
	}
	if !validWrappingKeyFingerprint(cfg.WrappingKeyFingerprint) {
		return nil, errors.New("agonesalloc: wrapping-key fingerprint is invalid")
	}
	return &Client{
		api:         api,
		namespace:   cfg.Namespace,
		fleet:       cfg.Fleet,
		tlsPortName: cfg.TLSPortName,
		fingerprint: cfg.WrappingKeyFingerprint,
		readyValue:  agones.AdmissionReadyValue(cfg.WrappingKeyFingerprint),
	}, nil
}

// WrappingKeyFingerprint is the envelope-ready pool this client selects, so a
// composition can prove its keyring opens what it allocates instead of
// configuring a second copy of the value.
func (c *Client) WrappingKeyFingerprint() string {
	return c.fingerprint
}

// Namespace, Fleet and TLSPortName report the pool this client allocates from,
// so a composition can prove every client it wires names the same one.
func (c *Client) Namespace() string { return c.namespace }

// Fleet reports the configured Fleet this client allocates from.
func (c *Client) Fleet() string { return c.fleet }

// TLSPortName reports the configured player-facing TLS port name.
func (c *Client) TLSPortName() string { return c.tlsPortName }

// Reserve allocates one envelope-ready GameServer and returns its endpoint
// together with the validated sealed admission material.
func (c *Client) Reserve(ctx context.Context, request Request) (GameServer, error) {
	reservationValue, err := agones.CorrelationLabel(request.ReservationID)
	if err != nil {
		return GameServer{}, errors.New("agonesalloc: reservation ID is invalid")
	}
	attemptValue, err := agones.CorrelationLabel(request.AttemptID)
	if err != nil {
		return GameServer{}, errors.New("agonesalloc: attempt ID is invalid")
	}
	if !validLeaseObjectID(request.LeaseObjectID) {
		return GameServer{}, errors.New("agonesalloc: private lease object ID is invalid")
	}
	claimLocator := claimLocator(request.LeaseObjectID, attemptValue)
	response, err := c.api.Allocate(ctx, &allocationpb.AllocationRequest{
		Namespace:  c.namespace,
		Scheduling: allocationpb.AllocationRequest_Packed,
		Metadata: &allocationpb.MetaPatch{
			Labels: map[string]string{
				reservationLabel: reservationValue,
				attemptLabel:     attemptValue,
			},
			Annotations: map[string]string{
				agones.ClaimLocatorAnnotation: claimLocator,
			},
		},
		GameServerSelectors: []*allocationpb.GameServerSelector{
			{
				MatchLabels: map[string]string{
					fleetLabel:                 c.fleet,
					agones.AdmissionReadyLabel: c.readyValue,
				},
				GameServerState: allocationpb.GameServerSelector_READY,
			},
		},
	})
	if err != nil {
		if unallocated(err) {
			return GameServer{}, ErrUnallocated
		}
		return GameServer{}, status.Error(
			status.Code(err),
			"agonesalloc: reserve GameServer",
		)
	}
	if !validDNSSubdomain(response.GetGameServerName()) {
		return GameServer{}, errors.New("agonesalloc: allocated GameServer name is invalid")
	}
	var tlsPort int32
	matches := 0
	for _, port := range response.GetPorts() {
		if port.GetName() == c.tlsPortName {
			matches++
			tlsPort = port.GetPort()
		}
	}
	if matches != 1 || tlsPort < 1 || tlsPort > 65535 {
		return GameServer{}, errors.New("agonesalloc: allocated GameServer TLS port is invalid")
	}
	envelope, err := c.validateAdmissionMetadata(response.GetMetadata(), claimLocator)
	if err != nil {
		return GameServer{}, err
	}
	return GameServer{
		Name:                   response.GetGameServerName(),
		Port:                   uint16(tlsPort),
		WrappingKeyFingerprint: c.fingerprint,
		AdmissionEnvelope:      envelope,
	}, nil
}

func (c *Client) validateAdmissionMetadata(
	metadata *allocationpb.AllocationResponse_GameServerMetadata,
	claimLocator string,
) (string, error) {
	if metadata == nil ||
		metadata.GetLabels()[fleetLabel] != c.fleet ||
		metadata.GetLabels()[agones.AdmissionReadyLabel] != c.readyValue ||
		metadata.GetAnnotations()[agones.AdmissionKeyAnnotation] != c.fingerprint ||
		metadata.GetAnnotations()[agones.ClaimLocatorAnnotation] != claimLocator {
		return "", errors.New("agonesalloc: allocated GameServer admission metadata is invalid")
	}
	envelope := metadata.GetAnnotations()[agones.AdmissionEnvelopeAnnotation]
	if !validAdmissionEnvelope(envelope) {
		return "", errors.New("agonesalloc: allocated GameServer admission envelope is invalid")
	}
	return envelope, nil
}

func claimLocator(leaseObjectID, attemptValue string) string {
	return claimLocatorPrefix + leaseObjectID + "." + attemptValue
}

func validWrappingKeyFingerprint(value string) bool {
	return handoffidentity.Fingerprint(value)
}

func validLeaseObjectID(value string) bool {
	if len(value) != leaseObjectIDLength {
		return false
	}
	for _, char := range value {
		if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
			return false
		}
	}
	return true
}

func validAdmissionEnvelope(value string) bool {
	if !strings.HasPrefix(value, admissionEnvelopePrefix) {
		return false
	}
	encoded := strings.TrimPrefix(value, admissionEnvelopePrefix)
	ciphertext, err := base64.RawURLEncoding.Strict().DecodeString(encoded)
	if err != nil ||
		len(ciphertext) < minAdmissionEnvelopeBytes ||
		len(ciphertext) > maxAdmissionEnvelopeBytes {
		return false
	}
	return base64.RawURLEncoding.EncodeToString(ciphertext) == encoded
}

func validDNSSubdomain(value string) bool {
	return handoffidentity.DNSSubdomain(value)
}

func validFleetName(value string) bool {
	return len(value) <= 63 && validDNSSubdomain(value)
}

func validDNSLabel(value string) bool {
	return handoffidentity.DNSLabel(value)
}
