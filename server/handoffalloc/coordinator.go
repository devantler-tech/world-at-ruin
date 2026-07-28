// Package handoffalloc coordinates durable ownership of player GameServer
// handoffs.
package handoffalloc

import (
	"context"
	"errors"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"google.golang.org/grpc/status"
)

const (
	// DefaultLeaseTTL gives a pre-connected client enough time to complete zone
	// admission without leaving an unclaimed allocation indefinitely.
	DefaultLeaseTTL = 2 * time.Minute
	// MaxLeaseTTL bounds the lifetime of resources that never complete
	// admission.
	MaxLeaseTTL          = 10 * time.Minute
	stagedCleanupTimeout = 5 * time.Second
)

var (
	// ErrReconciliation means external resource ownership could not be made
	// consistent with the durable lease outcome.
	ErrReconciliation = errors.New(
		"handoff allocation: resource outcome could not be reconciled",
	)
	// ErrInvalidResource means resource material does not match the durable
	// allocation lease that authorizes it.
	ErrInvalidResource = errors.New(
		"handoff allocation: resource does not match durable lease",
	)
)

// Provisioned pairs player connection material with the durable reference to
// its allocation-scoped admission secret.
type Provisioned struct {
	Allocation handoff.Allocation
	SecretRef  string
}

// GameServerResources owns the external GameServer and admission-secret
// lifecycle. Provision reports any resource staged before an error so the
// coordinator can reclaim it. Resolve must return the exact durable resource,
// while Release must be idempotent for that exact resource. Its concrete Agones
// and Kubernetes implementation is a later server-foundation child.
type GameServerResources interface {
	Provision(context.Context, handoff.AllocationRequest, time.Time) (Provisioned, error)
	Resolve(context.Context, nakamalease.Lease) (handoff.Allocation, error)
	Release(context.Context, nakamalease.Lease) error
}

// Config sets the unclaimed allocation lease policy.
type Config struct {
	LeaseTTL time.Duration
	Now      func() time.Time
}

// Coordinator makes external GameServer resources durable through Nakama.
type Coordinator struct {
	resources GameServerResources
	leases    *nakamalease.Store
	leaseTTL  time.Duration
	now       func() time.Time
}

// NewCoordinator builds a durable handoff allocation coordinator.
func NewCoordinator(
	resources GameServerResources,
	leases *nakamalease.Store,
	cfg Config,
) (*Coordinator, error) {
	if resources == nil {
		return nil, errors.New("handoff allocation: GameServer resources are required")
	}
	if leases == nil {
		return nil, errors.New("handoff allocation: lease store is required")
	}
	leaseTTL := cfg.LeaseTTL
	if leaseTTL == 0 {
		leaseTTL = DefaultLeaseTTL
	}
	if leaseTTL < time.Second || leaseTTL > MaxLeaseTTL {
		return nil, errors.New(
			"handoff allocation: lease TTL must be between one second and ten minutes",
		)
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return &Coordinator{
		resources: resources,
		leases:    leases,
		leaseTTL:  leaseTTL,
		now:       now,
	}, nil
}

// Allocate provisions one GameServer resource and records its attempt before
// returning any player connection material.
func (c *Coordinator) Allocate(
	ctx context.Context,
	request handoff.AllocationRequest,
) (handoff.Allocation, error) {
	now := c.now()
	current, err := c.leases.Load(ctx, request.UserID, request.ReservationID)
	hasCurrent := err == nil
	switch {
	case err == nil &&
		current.Lease.AttemptID == request.AttemptID &&
		current.Lease.Releasing:
		return handoff.Allocation{}, nakamalease.ErrReleasing
	case err == nil && current.Lease.AttemptID == request.AttemptID:
		allocation, resolveErr := c.resources.Resolve(ctx, current.Lease)
		if resolveErr != nil {
			return handoff.Allocation{}, sanitizedResourceError(
				resolveErr,
				"handoff allocation: resolve GameServer resource",
			)
		}
		if !matchesLease(allocation, current.Lease) {
			return handoff.Allocation{}, ErrInvalidResource
		}
		return allocation, nil
	case err == nil:
	case errors.Is(err, nakamalease.ErrNotFound):
	default:
		return handoff.Allocation{}, err
	}
	if hasCurrent {
		if current.State(now) == nakamalease.StateClaimed {
			return handoff.Allocation{}, nakamalease.ErrClaimed
		}
		current, err = c.leases.BeginRelease(
			ctx,
			current,
			current.Lease.AttemptID,
		)
		if err != nil {
			return handoff.Allocation{}, err
		}
		if err := c.resources.Release(ctx, current.Lease); err != nil {
			return handoff.Allocation{}, ErrReconciliation
		}
	}

	expiresAt := now.Add(c.leaseTTL)
	provisioned, err := c.resources.Provision(ctx, request, expiresAt)
	if err != nil {
		if hasReportedStagedResource(provisioned) {
			staged := leaseFromProvisioned(request, provisioned, expiresAt)
			if releaseErr := c.releaseStaged(ctx, staged); releaseErr != nil {
				return handoff.Allocation{}, ErrReconciliation
			}
		}
		return handoff.Allocation{}, sanitizedResourceError(
			err,
			"handoff allocation: provision GameServer resource",
		)
	}
	next := leaseFromProvisioned(request, provisioned, expiresAt)
	if !matchesLease(provisioned.Allocation, next) {
		if releaseErr := c.releaseStaged(ctx, next); releaseErr != nil {
			return handoff.Allocation{}, ErrReconciliation
		}
		return handoff.Allocation{}, ErrInvalidResource
	}
	if hasCurrent {
		_, err = c.leases.Replace(ctx, current, next)
	} else {
		_, err = c.leases.Create(ctx, next)
	}
	if err != nil {
		if releaseErr := c.releaseStaged(ctx, next); releaseErr != nil {
			return handoff.Allocation{}, ErrReconciliation
		}
		return handoff.Allocation{}, err
	}
	return provisioned.Allocation, nil
}

func leaseFromProvisioned(
	request handoff.AllocationRequest,
	provisioned Provisioned,
	expiresAt time.Time,
) nakamalease.Lease {
	return nakamalease.Lease{
		UserID:        request.UserID,
		ReservationID: request.ReservationID,
		AttemptID:     request.AttemptID,
		AllocationID:  provisioned.Allocation.ID,
		Observer:      provisioned.Allocation.Observer,
		SecretRef:     provisioned.SecretRef,
		ExpiresAt:     expiresAt,
	}
}

func hasReportedStagedResource(provisioned Provisioned) bool {
	return provisioned.Allocation.ID != "" || provisioned.SecretRef != ""
}

func (c *Coordinator) releaseStaged(
	ctx context.Context,
	lease nakamalease.Lease,
) error {
	cleanupCtx, cancel := context.WithTimeout(
		context.WithoutCancel(ctx),
		stagedCleanupTimeout,
	)
	defer cancel()
	return c.resources.Release(cleanupCtx, lease)
}

func matchesLease(allocation handoff.Allocation, lease nakamalease.Lease) bool {
	return allocation.ID == lease.AllocationID &&
		allocation.Observer == lease.Observer &&
		allocation.LeaseExpiresAt.Equal(lease.ExpiresAt)
}

func sanitizedResourceError(err error, message string) error {
	switch {
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, context.DeadlineExceeded):
		return context.DeadlineExceeded
	default:
		return status.Error(status.Code(err), message)
	}
}

// Release reclaims the exact unclaimed GameServer resource before deleting
// its durable cleanup record.
func (c *Coordinator) Release(
	ctx context.Context,
	request handoff.AllocationRequest,
) error {
	current, err := c.leases.Load(ctx, request.UserID, request.ReservationID)
	if errors.Is(err, nakamalease.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if current.Lease.AttemptID != request.AttemptID {
		return nakamalease.ErrStaleAttempt
	}
	if current.State(c.now()) == nakamalease.StateClaimed {
		return nakamalease.ErrClaimed
	}
	releasing, err := c.leases.BeginRelease(ctx, current, request.AttemptID)
	if err != nil {
		return err
	}
	if err := c.resources.Release(ctx, releasing.Lease); err != nil {
		return ErrReconciliation
	}
	return c.leases.Release(
		ctx,
		request.UserID,
		request.ReservationID,
		request.AttemptID,
	)
}
