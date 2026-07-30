// Package agonesalloc reserves envelope-ready zone GameServers through
// Agones's generated allocation API.
package agonesalloc

import (
	"context"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"strings"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"google.golang.org/grpc/status"
)

const (
	fleetLabel       = "agones.dev/fleet"
	reservationLabel = "world-at-ruin.dev/handoff-reservation"
	attemptLabel     = "world-at-ruin.dev/handoff-attempt"

	wrappingKeyFingerprintLength = 52
	leaseObjectIDLength          = 64
	admissionEnvelopePrefix      = "v1."
	admissionReadyPrefix         = "v1-"
	claimLocatorPrefix           = "v1."
	minAdmissionEnvelopeBytes    = 384
	maxAdmissionEnvelopeBytes    = 4096
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
		readyValue:  admissionReadyPrefix + cfg.WrappingKeyFingerprint,
	}, nil
}

// Reserve allocates one envelope-ready GameServer and returns its endpoint
// together with the validated sealed admission material.
func (c *Client) Reserve(ctx context.Context, request Request) (GameServer, error) {
	if !validCorrelationID(request.ReservationID) {
		return GameServer{}, errors.New("agonesalloc: reservation ID is invalid")
	}
	if !validCorrelationID(request.AttemptID) {
		return GameServer{}, errors.New("agonesalloc: attempt ID is invalid")
	}
	if !validLeaseObjectID(request.LeaseObjectID) {
		return GameServer{}, errors.New("agonesalloc: private lease object ID is invalid")
	}
	claimLocator := claimLocator(request.LeaseObjectID, request.AttemptID)
	response, err := c.api.Allocate(ctx, &allocationpb.AllocationRequest{
		Namespace:  c.namespace,
		Scheduling: allocationpb.AllocationRequest_Packed,
		Metadata: &allocationpb.MetaPatch{
			Labels: map[string]string{
				reservationLabel: correlationLabel(request.ReservationID),
				attemptLabel:     correlationLabel(request.AttemptID),
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

func correlationLabel(value string) string {
	digest := sha256.Sum256([]byte(value))
	return strings.ToLower(
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:]),
	)
}

func claimLocator(leaseObjectID, attemptID string) string {
	return claimLocatorPrefix + leaseObjectID + "." + correlationLabel(attemptID)
}

func validWrappingKeyFingerprint(value string) bool {
	if len(value) != wrappingKeyFingerprintLength {
		return false
	}
	decoded, err := base32.StdEncoding.WithPadding(base32.NoPadding).
		DecodeString(strings.ToUpper(value))
	if err != nil || len(decoded) != sha256.Size {
		return false
	}
	return strings.ToLower(
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(decoded),
	) == value
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

func validCorrelationID(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') &&
			(char < 'A' || char > 'Z') &&
			(char < '0' || char > '9') &&
			char != '-' &&
			char != '_' {
			return false
		}
	}
	return true
}

func validDNSSubdomain(value string) bool {
	if value == "" || len(value) > 253 {
		return false
	}
	for _, label := range strings.Split(value, ".") {
		if !validDNSLabel(label) {
			return false
		}
	}
	return true
}

func validFleetName(value string) bool {
	return len(value) <= 63 && validDNSSubdomain(value)
}

func validDNSLabel(value string) bool {
	if value == "" || len(value) > 63 ||
		value[0] == '-' || value[len(value)-1] == '-' {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') &&
			(char < '0' || char > '9') &&
			char != '-' {
			return false
		}
	}
	return true
}
