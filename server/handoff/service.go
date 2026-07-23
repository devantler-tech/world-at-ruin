// Package handoff composes Nakama identity, GameServer allocation, and zone
// admission into one fail-closed player handoff.
package handoff

import (
	"context"
	"crypto/rand"
	"encoding/hex"
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

// Allocator binds one authenticated user to one GameServer and observer. The
// reservation ID, scoped to the verified user ID, is the idempotency key for
// an allocation attempt: repeated Allocate calls must not create duplicates,
// and Release must idempotently reconcile that owner/key pair even when
// Allocate returned an ambiguous timeout after the fleet committed it. A
// newer AttemptID conditionally owns the same lease; Release from a stale
// attempt must be a no-op so overlapping retries cannot tear down the winner.
// Unclaimed allocations must be reclaimed automatically at LeaseExpiresAt;
// the zone admission adapter claims the current attempt on first valid use.
// Concrete Agones allocation is deliberately outside this transport-neutral
// core; an adapter must return the allocation that owns the endpoint.
type Allocator interface {
	Allocate(context.Context, AllocationRequest) (Allocation, error)
	Release(context.Context, AllocationRequest) error
}

// Request is the authenticated session and caller-stable idempotency key for
// one handoff attempt. A transport retry must reuse ReservationID.
type Request struct {
	Session       string
	ReservationID string
}

// AllocationRequest is the identity and idempotency key trusted by the
// allocator after session verification.
type AllocationRequest struct {
	UserID        string
	ReservationID string
	AttemptID     string
}

// Allocation is the trusted result of allocating one GameServer.
type Allocation struct {
	ID              string
	ServerName      string
	Port            uint16
	Observer        sim.EntityID
	AdmissionSecret []byte
	LeaseExpiresAt  time.Time
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
	ZoneDomain   string
	TokenTTL     time.Duration
	Now          func() time.Time
	NewAttemptID func() (string, error)
}

// Service creates allocation-scoped player handoffs.
type Service struct {
	verifier     SessionVerifier
	allocator    Allocator
	zoneDomain   string
	tokenTTL     time.Duration
	now          func() time.Time
	newAttemptID func() (string, error)
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
	newAttemptID := cfg.NewAttemptID
	if newAttemptID == nil {
		newAttemptID = secureAttemptID
	}

	return &Service{
		verifier:     verifier,
		allocator:    allocator,
		zoneDomain:   zoneDomain,
		tokenTTL:     tokenTTL,
		now:          now,
		newAttemptID: newAttemptID,
	}, nil
}

// CreateHandoff authenticates a Nakama session, allocates its GameServer, and
// returns a token the allocated zone can verify. Every failed stage returns a
// zero Handoff, so callers cannot accidentally expose a partial endpoint.
func (s *Service) CreateHandoff(ctx context.Context, request Request) (Handoff, error) {
	if !validAllocationID(request.ReservationID) {
		return Handoff{}, errors.New("handoff: reservation ID is invalid")
	}

	userID, err := s.verifier.VerifySession(ctx, request.Session)
	if err != nil {
		return Handoff{}, status.Error(status.Code(err), "handoff: authenticate player")
	}
	if userID == "" {
		return Handoff{}, errors.New("handoff: verifier returned no user ID")
	}
	attemptID, err := s.newAttemptID()
	if err != nil || !validAllocationID(attemptID) {
		return Handoff{}, errors.New("handoff: create allocation attempt ID")
	}

	allocationRequest := AllocationRequest{
		UserID:        userID,
		ReservationID: request.ReservationID,
		AttemptID:     attemptID,
	}
	allocation, err := s.allocator.Allocate(ctx, allocationRequest)
	if err != nil {
		return Handoff{}, s.releaseReservationAfterFailure(
			ctx,
			allocationRequest,
			status.Error(status.Code(err), "handoff: allocate GameServer"),
		)
	}
	if err := ctx.Err(); err != nil {
		return Handoff{}, s.releaseReservationAfterFailure(
			ctx,
			allocationRequest,
			err,
		)
	}
	allocation.ServerName = strings.TrimSuffix(allocation.ServerName, ".")
	now := s.now()
	if err := s.validateAllocation(allocation, now); err != nil {
		return Handoff{}, s.releaseReservationAfterFailure(
			ctx,
			allocationRequest,
			err,
		)
	}

	expiresAt := now.Add(s.tokenTTL)
	if allocation.LeaseExpiresAt.Before(expiresAt) {
		expiresAt = allocation.LeaseExpiresAt
	}
	expiresAt = time.Unix(0, expiresAt.UnixNano())
	token, err := zonesock.MintToken(
		allocation.AdmissionSecret,
		allocation.ID,
		allocation.Observer,
		expiresAt,
	)
	if err != nil {
		return Handoff{}, s.releaseReservationAfterFailure(
			ctx,
			allocationRequest,
			errors.New("handoff: mint allocation token"),
		)
	}
	if err := ctx.Err(); err != nil {
		return Handoff{}, s.releaseReservationAfterFailure(
			ctx,
			allocationRequest,
			err,
		)
	}

	return Handoff{
		ServerName: allocation.ServerName,
		Port:       allocation.Port,
		Token:      token,
		ExpiresAt:  expiresAt,
	}, nil
}

func (s *Service) validateAllocation(allocation Allocation, now time.Time) error {
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
	if allocation.LeaseExpiresAt.Sub(now) < time.Second {
		return errors.New("handoff: unclaimed allocation lease is expired")
	}
	return nil
}

func (s *Service) releaseReservationAfterFailure(
	ctx context.Context,
	request AllocationRequest,
	handoffErr error,
) error {
	releaseCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), releaseTimeout)
	defer cancel()
	if err := s.allocator.Release(releaseCtx, request); err != nil {
		return status.Error(
			status.Code(err),
			"handoff: allocation outcome could not be reconciled",
		)
	}
	return handoffErr
}

func secureAttemptID() (string, error) {
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(random[:]), nil
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
