// Package handoff composes Nakama identity, GameServer allocation, and zone
// admission into one fail-closed player handoff.
package handoff

import (
	"context"
	"errors"
	"net"
	"strings"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
	"google.golang.org/grpc/status"
)

const (
	// DefaultTokenTTL keeps an allocation token useful only for the immediate
	// pre-connect handoff.
	DefaultTokenTTL = 30 * time.Second
	// MaxTokenTTL is the hard ceiling for the configured short-lived token TTL.
	MaxTokenTTL = 5 * time.Minute
	// releaseTimeout lets rollback outlive a cancelled client request without
	// allowing a broken allocator to hold the RPC forever.
	releaseTimeout = 5 * time.Second
)

// SessionVerifier resolves the authenticated user behind a Nakama session.
type SessionVerifier interface {
	VerifySession(context.Context, string) (string, error)
}

// Allocator binds one authenticated user to one GameServer and observer.
// Concrete Agones allocation is deliberately outside this transport-neutral
// core; an adapter must return the allocation that owns the endpoint.
type Allocator interface {
	Allocate(context.Context, string) (Allocation, error)
	Release(context.Context, Allocation) error
}

// Allocation is the trusted result of allocating one GameServer.
type Allocation struct {
	ID         string
	ServerName string
	Port       uint16
	Observer   sim.EntityID
}

// Handoff is the only connection material returned to a player.
type Handoff struct {
	ServerName string
	Port       uint16
	Token      string
	ExpiresAt  time.Time
}

// Config sets the admission-key material and lifetime policy.
type Config struct {
	AdmissionSecret []byte
	ZoneDomain      string
	TokenTTL        time.Duration
	Now             func() time.Time
}

// Service creates allocation-scoped player handoffs.
type Service struct {
	verifier   SessionVerifier
	allocator  Allocator
	secret     []byte
	zoneDomain string
	tokenTTL   time.Duration
	now        func() time.Time
}

// NewService validates the handoff dependencies and token policy.
func NewService(verifier SessionVerifier, allocator Allocator, cfg Config) (*Service, error) {
	if verifier == nil {
		return nil, errors.New("handoff: session verifier is required")
	}
	if allocator == nil {
		return nil, errors.New("handoff: allocator is required")
	}

	tokenTTL := cfg.TokenTTL
	if tokenTTL == 0 {
		tokenTTL = DefaultTokenTTL
	}
	if tokenTTL < time.Second || tokenTTL > MaxTokenTTL {
		return nil, errors.New("handoff: token TTL must be between one second and five minutes")
	}

	zoneDomain := strings.ToLower(strings.TrimSuffix(cfg.ZoneDomain, "."))
	if !validDNSName(zoneDomain) {
		return nil, errors.New("handoff: managed zone domain is invalid")
	}

	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	if _, err := zonesock.MintToken(
		cfg.AdmissionSecret,
		"configuration-check",
		sim.EntityID(1),
		now().Add(tokenTTL),
	); err != nil {
		return nil, errors.New("handoff: admission secret is invalid")
	}

	return &Service{
		verifier:   verifier,
		allocator:  allocator,
		secret:     append([]byte(nil), cfg.AdmissionSecret...),
		zoneDomain: zoneDomain,
		tokenTTL:   tokenTTL,
		now:        now,
	}, nil
}

// CreateHandoff authenticates a Nakama session, allocates its GameServer, and
// returns a token the allocated zone can verify. Every failed stage returns a
// zero Handoff, so callers cannot accidentally expose a partial endpoint.
func (s *Service) CreateHandoff(ctx context.Context, session string) (Handoff, error) {
	userID, err := s.verifier.VerifySession(ctx, session)
	if err != nil {
		return Handoff{}, status.Error(status.Code(err), "handoff: authenticate player")
	}
	if userID == "" {
		return Handoff{}, errors.New("handoff: verifier returned no user ID")
	}

	allocation, err := s.allocator.Allocate(ctx, userID)
	if err != nil {
		return Handoff{}, status.Error(status.Code(err), "handoff: allocate GameServer")
	}
	if err := ctx.Err(); err != nil {
		return Handoff{}, s.releaseAfterFailure(ctx, allocation, err)
	}
	if err := s.validateAllocation(allocation); err != nil {
		return Handoff{}, s.releaseAfterFailure(ctx, allocation, err)
	}

	deadline := s.now().Add(s.tokenTTL)
	expiresAt := time.Unix(deadline.Unix(), 0)
	if deadline.Nanosecond() != 0 {
		expiresAt = expiresAt.Add(time.Second)
	}
	token, err := zonesock.MintToken(
		s.secret,
		allocation.ID,
		allocation.Observer,
		expiresAt,
	)
	if err != nil {
		return Handoff{}, s.releaseAfterFailure(
			ctx,
			allocation,
			errors.New("handoff: mint allocation token"),
		)
	}

	return Handoff{
		ServerName: allocation.ServerName,
		Port:       allocation.Port,
		Token:      token,
		ExpiresAt:  expiresAt,
	}, nil
}

func (s *Service) validateAllocation(allocation Allocation) error {
	if !validAllocationID(allocation.ID) {
		return errors.New("handoff: allocation ID is invalid")
	}
	if !validDNSName(allocation.ServerName) {
		return errors.New("handoff: GameServer DNS name is invalid")
	}
	if !strings.HasSuffix(strings.ToLower(allocation.ServerName), "."+s.zoneDomain) {
		return errors.New("handoff: GameServer is outside the managed zone domain")
	}
	if allocation.Port == 0 {
		return errors.New("handoff: GameServer TLS port is missing")
	}
	if allocation.Observer == 0 {
		return errors.New("handoff: observer binding is missing")
	}
	return nil
}

func (s *Service) releaseAfterFailure(
	ctx context.Context,
	allocation Allocation,
	handoffErr error,
) error {
	releaseCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), releaseTimeout)
	defer cancel()
	if err := s.allocator.Release(releaseCtx, allocation); err != nil {
		return errors.New("handoff: invalid allocation could not be released")
	}
	return handoffErr
}

func validAllocationID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for _, char := range id {
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

func validDNSName(name string) bool {
	if name == "" || len(name) > 253 || net.ParseIP(name) != nil {
		return false
	}

	for _, label := range strings.Split(name, ".") {
		if label == "" || len(label) > 63 ||
			label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, char := range label {
			if (char < 'a' || char > 'z') &&
				(char < 'A' || char > 'Z') &&
				(char < '0' || char > '9') &&
				char != '-' {
				return false
			}
		}
	}
	return true
}
