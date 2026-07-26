// Package agonesalloc reserves Ready zone GameServers through Agones's
// generated allocation API.
package agonesalloc

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	"google.golang.org/grpc/status"
)

const (
	fleetLabel       = "agones.dev/fleet"
	reservationLabel = "world-at-ruin.dev/handoff-reservation"
	attemptLabel     = "world-at-ruin.dev/handoff-attempt"
)

// Config identifies the Ready GameServer pool and its player-facing TLS port.
type Config struct {
	Namespace   string
	Fleet       string
	TLSPortName string
}

// Request carries only opaque allocation correlation values.
type Request struct {
	ReservationID string
	AttemptID     string
}

// GameServer is the allocated zone endpoint material this boundary trusts.
type GameServer struct {
	Name string
	Port uint16
}

// Client reserves GameServers through Agones's generated gRPC API.
type Client struct {
	api         allocationpb.AllocationServiceClient
	namespace   string
	fleet       string
	tlsPortName string
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
	return &Client{
		api:         api,
		namespace:   cfg.Namespace,
		fleet:       cfg.Fleet,
		tlsPortName: cfg.TLSPortName,
	}, nil
}

// Reserve allocates one Ready GameServer and returns its named TLS port.
func (c *Client) Reserve(ctx context.Context, request Request) (GameServer, error) {
	if !validCorrelationID(request.ReservationID) {
		return GameServer{}, errors.New("agonesalloc: reservation ID is invalid")
	}
	if !validCorrelationID(request.AttemptID) {
		return GameServer{}, errors.New("agonesalloc: attempt ID is invalid")
	}
	response, err := c.api.Allocate(ctx, &allocationpb.AllocationRequest{
		Namespace:  c.namespace,
		Scheduling: allocationpb.AllocationRequest_Packed,
		Metadata: &allocationpb.MetaPatch{
			Labels: map[string]string{
				reservationLabel: correlationLabel(request.ReservationID),
				attemptLabel:     correlationLabel(request.AttemptID),
			},
		},
		GameServerSelectors: []*allocationpb.GameServerSelector{
			{
				MatchLabels: map[string]string{
					fleetLabel: c.fleet,
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
	return GameServer{
		Name: response.GetGameServerName(),
		Port: uint16(tlsPort),
	}, nil
}

func correlationLabel(value string) string {
	digest := sha256.Sum256([]byte(value))
	return base64.RawURLEncoding.EncodeToString(digest[:])
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
