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
	MaxLeaseTTL = 10 * time.Minute
	// DefaultSweepInterval bounds how long an expired durable attempt waits
	// before the supervised reconciler retries exact cleanup.
	DefaultSweepInterval = 15 * time.Second

	// StagedCleanupTimeout bounds the external cleanup of a resource whose
	// identity is already known, on a context that survives the caller's
	// cancellation. The concrete resource adapter shares it for the same
	// reason, so the two budgets cannot drift apart.
	StagedCleanupTimeout = 5 * time.Second
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
// lifecycle. Provision performs the one external allocation dispatch permitted
// for an attempt. Reconcile observes only that exact attempt and never
// dispatches. Resolve must return the exact durable resource, while Release must
// be idempotent for that exact resource. Its concrete Agones and Kubernetes
// implementation is the agonesresources package. Release must also discover
// an attempt from AttemptID alone when a staging lease has no allocation material
// yet; this makes a crash after Provision recoverable.
type GameServerResources interface {
	Provision(context.Context, handoff.AllocationRequest, time.Time) (Provisioned, error)
	Reconcile(context.Context, handoff.AllocationRequest, time.Time) (Provisioned, error)
	Resolve(context.Context, nakamalease.Lease) (handoff.Allocation, error)
	Release(context.Context, nakamalease.Lease) error
}

// Config sets the unclaimed allocation lease policy.
type Config struct {
	LeaseTTL      time.Duration
	SweepInterval time.Duration
	Now           func() time.Time
}

// Coordinator makes external GameServer resources durable through Nakama.
type Coordinator struct {
	resources     GameServerResources
	leases        *nakamalease.Store
	leaseTTL      time.Duration
	sweepInterval time.Duration
	now           func() time.Time
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
	sweepInterval := cfg.SweepInterval
	if sweepInterval == 0 {
		sweepInterval = DefaultSweepInterval
		if leaseTTL < sweepInterval {
			sweepInterval = leaseTTL
		}
	}
	if sweepInterval < time.Second || sweepInterval > leaseTTL {
		return nil, errors.New(
			"handoff allocation: sweep interval must be between one second and the lease TTL",
		)
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return &Coordinator{
		resources:     resources,
		leases:        leases,
		leaseTTL:      leaseTTL,
		sweepInterval: sweepInterval,
		now:           now,
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
	case err == nil &&
		current.Lease.AttemptID == request.AttemptID &&
		!current.Lease.Staging:
		return c.resolveDurable(ctx, current.Lease)
	case err == nil && current.Lease.AttemptID == request.AttemptID:
		// Recover the durable staging intent by replaying the external
		// operation with the same attempt and expiry.
	case err == nil:
	case errors.Is(err, nakamalease.ErrNotFound):
	default:
		return handoff.Allocation{}, err
	}
	if hasCurrent &&
		current.Lease.AttemptID == request.AttemptID &&
		current.Lease.Staging &&
		!current.Lease.Dispatched &&
		!now.Before(current.Lease.ExpiresAt) {
		if releaseErr := c.reconcileAttempt(ctx, request, nil); releaseErr != nil {
			return handoff.Allocation{}, ErrReconciliation
		}
		return handoff.Allocation{}, nakamalease.ErrExpired
	}
	if hasCurrent && current.Lease.AttemptID != request.AttemptID {
		switch {
		case current.State(now) == nakamalease.StateUnclaimed:
			return c.resolveDurable(ctx, current.Lease)
		case current.Lease.Staging &&
			current.Lease.Dispatched &&
			current.Lease.Releasing:
			return handoff.Allocation{}, nakamalease.ErrReleasing
		case current.Lease.Staging && current.Lease.Dispatched:
			// A transport retry creates a fresh transient attempt ID. Adopt the
			// durable dispatch owner so the retry observes that exact external
			// operation instead of wedging the quarantine forever.
			request.AttemptID = current.Lease.AttemptID
		case current.State(now) == nakamalease.StateClaimed:
			return handoff.Allocation{}, nakamalease.ErrClaimed
		default:
			current, err = c.leases.BeginRelease(
				ctx,
				current,
				current.Lease.AttemptID,
			)
			if err != nil {
				return handoff.Allocation{}, err
			}
			if err := c.releaseResource(ctx, current.Lease); err != nil {
				return handoff.Allocation{}, ErrReconciliation
			}
		}
	}

	var staging nakamalease.Record
	if current.Lease.AttemptID == request.AttemptID && current.Lease.Staging {
		staging = current
	} else {
		stagingLease := nakamalease.Lease{
			UserID:        request.UserID,
			ReservationID: request.ReservationID,
			AttemptID:     request.AttemptID,
			ExpiresAt:     c.now().Add(c.leaseTTL),
			Staging:       true,
		}
		if hasCurrent {
			staging, err = c.leases.Replace(ctx, current, stagingLease)
		} else {
			staging, err = c.leases.Create(ctx, stagingLease)
		}
		if err != nil {
			return handoff.Allocation{}, err
		}
	}
	if !staging.Lease.Staging {
		return c.resolveDurable(ctx, staging.Lease)
	}

	dispatch := false
	if !staging.Lease.Dispatched {
		staging, dispatch, err = c.leases.BeginDispatch(
			ctx,
			staging,
			request.AttemptID,
		)
		if err != nil {
			return handoff.Allocation{}, err
		}
	}
	var provisioned Provisioned
	resourceOperation := "handoff allocation: reconcile GameServer resource"
	if dispatch {
		resourceOperation = "handoff allocation: provision GameServer resource"
		provisioned, err = c.resources.Provision(
			ctx,
			request,
			staging.Lease.ExpiresAt,
		)
	} else {
		provisioned, err = c.resources.Reconcile(
			ctx,
			request,
			staging.Lease.ExpiresAt,
		)
	}
	if err != nil {
		progressCtx, cancel := context.WithTimeout(
			context.WithoutCancel(ctx),
			StagedCleanupTimeout,
		)
		defer cancel()
		if winner, progressed, winnerErr := c.resolveProgressedAttempt(
			progressCtx,
			request,
		); progressed {
			if winnerErr != nil {
				return handoff.Allocation{}, handoff.RetainAllocationOutcome(winnerErr)
			}
			return winner, winnerErr
		} else if winnerErr != nil {
			return handoff.Allocation{}, handoff.RetainAllocationOutcome(winnerErr)
		}
		return handoff.Allocation{}, handoff.RetainAllocationOutcome(
			sanitizedResourceError(err, resourceOperation),
		)
	}
	resourceExpiry := provisioned.Allocation.LeaseExpiresAt
	next := leaseFromProvisioned(request, provisioned, resourceExpiry)
	if !resourceExpiry.After(c.now()) ||
		resourceExpiry.After(staging.Lease.ExpiresAt) {
		if releaseErr := c.reconcileAttempt(ctx, request, &next); releaseErr != nil {
			return handoff.Allocation{}, ErrReconciliation
		}
		return handoff.Allocation{}, ErrInvalidResource
	}
	if !matchesLease(provisioned.Allocation, next) {
		if releaseErr := c.reconcileAttempt(ctx, request, &next); releaseErr != nil {
			return handoff.Allocation{}, ErrReconciliation
		}
		return handoff.Allocation{}, ErrInvalidResource
	}
	_, err = c.leases.Finalize(ctx, staging, next)
	if err != nil {
		progressCtx, cancel := context.WithTimeout(
			context.WithoutCancel(ctx),
			StagedCleanupTimeout,
		)
		defer cancel()
		if winner, progressed, winnerErr := c.resolveProgressedAttempt(
			progressCtx,
			request,
		); progressed {
			if winnerErr != nil {
				return handoff.Allocation{}, handoff.RetainAllocationOutcome(winnerErr)
			}
			return winner, winnerErr
		} else if winnerErr != nil {
			return handoff.Allocation{}, handoff.RetainAllocationOutcome(winnerErr)
		}
		if releaseErr := c.reconcileAttempt(progressCtx, request, &next); releaseErr != nil {
			return handoff.Allocation{}, ErrReconciliation
		}
		return handoff.Allocation{}, err
	}
	provisioned.Allocation.RetainOnFailure = true
	return provisioned.Allocation, nil
}

func (c *Coordinator) resolveProgressedAttempt(
	ctx context.Context,
	request handoff.AllocationRequest,
) (handoff.Allocation, bool, error) {
	current, err := c.leases.Load(ctx, request.UserID, request.ReservationID)
	switch {
	case errors.Is(err, nakamalease.ErrNotFound):
		return handoff.Allocation{}, false, nil
	case err != nil:
		return handoff.Allocation{}, false, err
	case current.Lease.AttemptID != request.AttemptID,
		current.Lease.Staging,
		current.Lease.Releasing:
		return handoff.Allocation{}, false, nil
	default:
		allocation, resolveErr := c.resolveDurable(ctx, current.Lease)
		return allocation, true, resolveErr
	}
}

func (c *Coordinator) resolveDurable(
	ctx context.Context,
	lease nakamalease.Lease,
) (handoff.Allocation, error) {
	allocation, err := c.resources.Resolve(ctx, lease)
	if err != nil {
		return handoff.Allocation{}, sanitizedResourceError(
			err,
			"handoff allocation: resolve GameServer resource",
		)
	}
	if !matchesLease(allocation, lease) {
		return handoff.Allocation{}, ErrInvalidResource
	}
	allocation.RetainOnFailure = true
	return allocation, nil
}

// ReconcileExpired reclaims every expired durable attempt visible in the
// private lease collection. Exact-version fencing arbitrates with zone claim.
func (c *Coordinator) ReconcileExpired(ctx context.Context) error {
	err := c.leases.ReclaimExpired(
		ctx,
		c.now(),
		func(reclaimCtx context.Context, lease nakamalease.Lease) error {
			return c.releaseResource(reclaimCtx, lease)
		},
	)
	if err != nil {
		if errors.Is(err, context.Canceled) ||
			errors.Is(err, context.DeadlineExceeded) {
			return err
		}
		return ErrReconciliation
	}
	return nil
}

// RunExpiryReconciler supervises no-show cleanup until the host context ends.
// A concrete Nakama composition must run this loop for the Allocator contract.
func (c *Coordinator) RunExpiryReconciler(ctx context.Context) error {
	ticker := time.NewTicker(c.sweepInterval)
	defer ticker.Stop()
	for {
		if err := c.ReconcileExpired(ctx); err != nil {
			if ctxErr := ctx.Err(); ctxErr != nil {
				return ctxErr
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
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

func (c *Coordinator) releaseResource(
	ctx context.Context,
	lease nakamalease.Lease,
) error {
	cleanupCtx, cancel := context.WithTimeout(
		context.WithoutCancel(ctx),
		StagedCleanupTimeout,
	)
	defer cancel()
	return c.resources.Release(cleanupCtx, lease)
}

func (c *Coordinator) reconcileAttempt(
	ctx context.Context,
	request handoff.AllocationRequest,
	resource *nakamalease.Lease,
) error {
	if resource != nil {
		cleanupCtx, cancel := context.WithTimeout(
			context.WithoutCancel(ctx),
			StagedCleanupTimeout,
		)
		defer cancel()
		ctx = cleanupCtx
	}
	current, err := c.leases.Load(ctx, request.UserID, request.ReservationID)
	if errors.Is(err, nakamalease.ErrNotFound) {
		if resource != nil {
			return c.releaseResource(ctx, *resource)
		}
		return nil
	}
	if err != nil {
		return err
	}
	if current.Lease.AttemptID != request.AttemptID {
		if resource != nil {
			return c.releaseResource(ctx, *resource)
		}
		return nil
	}
	if current.State(c.now()) == nakamalease.StateClaimed {
		return nakamalease.ErrClaimed
	}
	// Release is also the handoff service's best-effort response to an
	// allocation error. Once dispatch has crossed its durable barrier, that
	// error cannot prove that no resource was created. Preserve the quarantine
	// until observation supplies the resource identity or a fenced cleanup is
	// already in progress.
	if resource == nil &&
		current.Lease.Staging &&
		current.Lease.Dispatched &&
		!current.Lease.Releasing {
		return nil
	}
	releasing, err := c.leases.BeginRelease(ctx, current, request.AttemptID)
	if err != nil {
		return err
	}
	releaseLease := releasing.Lease
	if resource != nil {
		releaseLease.AllocationID = resource.AllocationID
		releaseLease.Observer = resource.Observer
		releaseLease.SecretRef = resource.SecretRef
		releaseLease.ExpiresAt = resource.ExpiresAt
		releaseLease.Staging = false
	}
	if err := c.releaseResource(ctx, releaseLease); err != nil {
		return err
	}
	return c.leases.Release(
		ctx,
		request.UserID,
		request.ReservationID,
		request.AttemptID,
	)
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
	if err := c.reconcileAttempt(ctx, request, nil); err != nil {
		if errors.Is(err, nakamalease.ErrClaimed) {
			return err
		}
		return ErrReconciliation
	}
	return nil
}
