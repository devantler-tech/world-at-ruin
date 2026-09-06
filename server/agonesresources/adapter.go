// Package agonesresources is the concrete GameServer resource adapter behind
// the durable handoff coordinator. It composes the Agones allocation boundary,
// the exact-UID GameServer resource boundary and the sealed-admission keyring
// into handoffalloc.GameServerResources the way ADR 0002 prescribes: one
// allocation dispatch per attempt, observation-only reconciliation, an exact
// resolve that recomputes every durable reference component, and release that
// deletes only with each target's own UID precondition.
//
// The allocator-generation fence that ADR 0002 names as the only other way to
// clear a dispatched-no-match quarantine is a separate authority and is not
// composed here; until it exists an ambiguous dispatch stays quarantined
// exactly as the coordinator already keeps it.
package agonesresources

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/agonesalloc"
	"github.com/devantler-tech/world-at-ruin/server/gameserverapi"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/handoffalloc"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/util/validation"
)

const (
	// DefaultObservationTimeout bounds how long a fresh dispatch waits for the
	// exact attempt-labelled GameServer to become observable through the
	// Kubernetes API before the dispatch is reported ambiguous.
	DefaultObservationTimeout = 10 * time.Second
	// MaxObservationTimeout keeps a misconfigured wait from holding a handoff
	// RPC open indefinitely.
	MaxObservationTimeout = time.Minute
	// DefaultObservationInterval paces the read-after-allocation retries.
	DefaultObservationInterval = 250 * time.Millisecond
)

// Sentinel outcomes are gRPC status errors, so status.Code reports the class
// through the coordinator's sanitized error path and errors.Is still matches
// them after wrapping, without any resource detail reaching a caller. Note the
// coordinator rebuilds the status with its own message, so only the CODE
// survives that boundary; the identities below are for callers inside this
// composition.
var (
	// ErrAmbiguousDispatch means an allocation may have committed but no exact
	// attempt-labelled GameServer is observable yet. The attempt stays
	// quarantined; the adapter never dispatches it again.
	ErrAmbiguousDispatch = status.Error(
		codes.Unavailable,
		"agones resources: allocation outcome is not yet observable",
	)
	// ErrDuplicateAttempt means more than one GameServer carried the exact
	// attempt label. Every match was released by its own UID precondition and
	// the attempt fails closed.
	ErrDuplicateAttempt = status.Error(
		codes.Aborted,
		"agones resources: attempt matched more than one GameServer",
	)
	// ErrDuplicateAttemptRetained is ErrDuplicateAttempt's worse half: the
	// attempt matched more than one GameServer and at least one of them could
	// not be deleted, so a duplicate survives. It is reported separately
	// because the two need different operator attention, and a silently
	// swallowed cleanup failure is how a leak becomes invisible.
	ErrDuplicateAttemptRetained = status.Error(
		codes.Aborted,
		"agones resources: attempt matched more than one GameServer and one could not be released",
	)
	// ErrInvalidResource means the exact GameServer exists but its identity,
	// state, label, port, key or envelope no longer matches what the attempt or
	// lease pinned. It is never repaired in place.
	ErrInvalidResource = status.Error(
		codes.FailedPrecondition,
		"agones resources: GameServer does not match the durable attempt",
	)
	// ErrNotFound means the exact GameServer a lease names no longer exists.
	ErrNotFound = status.Error(codes.NotFound, "agones resources: GameServer not found")

	errAPIUnavailable = status.Error(
		codes.Unavailable,
		"agones resources: GameServer API is unavailable",
	)
)

// Config binds the adapter to the managed zone domain and the observer-binding
// policy. Everything about the pool — namespace, Fleet, TLS port name and the
// current wrapping key — is read back from the composed clients and
// cross-checked, so there is no second copy of it to keep in agreement.
type Config struct {
	// ZoneDomain is the managed zone-edge domain; a handoff advertises
	// <node name>.<ZoneDomain> because certificates bind node names, never a
	// GameServer's address. It is lower-cased and a trailing dot is dropped,
	// exactly as the handoff service normalizes the same value — and it must be
	// the SAME value that service is given, because it validates the name this
	// adapter mints against its own copy.
	ZoneDomain string
	// Observer decides which simulated entity an allocation binds the player
	// to. Observer binding is a composition decision this adapter does not own,
	// so it is required and must be deterministic for one request.
	Observer func(handoff.AllocationRequest) (sim.EntityID, error)
	// ObservationTimeout bounds the read-after-allocation wait. Zero selects
	// DefaultObservationTimeout.
	ObservationTimeout time.Duration
	// ObservationInterval paces that wait. Zero selects
	// DefaultObservationInterval.
	ObservationInterval time.Duration
}

// Adapter implements handoffalloc.GameServerResources over Agones.
type Adapter struct {
	allocator           *agonesalloc.Client
	resources           *gameserverapi.Client
	keyring             *admissionref.Keyring
	zoneDomain          string
	observer            func(handoff.AllocationRequest) (sim.EntityID, error)
	observationTimeout  time.Duration
	observationInterval time.Duration
}

var _ handoffalloc.GameServerResources = (*Adapter)(nil)

// NewAdapter validates the composition and refuses a keyring that cannot open
// the pool the allocation client selects, so the adapter never allocates a
// GameServer whose envelope it could not resolve.
func NewAdapter(
	allocator *agonesalloc.Client,
	resources *gameserverapi.Client,
	keyring *admissionref.Keyring,
	cfg Config,
) (*Adapter, error) {
	if allocator == nil {
		return nil, errors.New("agones resources: allocation client is required")
	}
	if resources == nil {
		return nil, errors.New("agones resources: GameServer resource client is required")
	}
	if keyring == nil {
		return nil, errors.New("agones resources: admission keyring is required")
	}
	if !keyring.Holds(allocator.WrappingKeyFingerprint()) {
		return nil, errors.New("agones resources: keyring does not hold the current wrapping key")
	}
	// The two clients are configured independently, and a disagreement between
	// them is invisible at runtime except as a GameServer leaked per attempt:
	// allocation succeeds against one pool while the resource reads look in
	// another, find nothing, and leave the allocated object with no owner.
	if allocator.Namespace() != resources.Namespace() ||
		allocator.Fleet() != resources.Fleet() ||
		allocator.TLSPortName() != resources.TLSPortName() {
		return nil, errors.New(
			"agones resources: allocation and resource clients name different pools",
		)
	}
	zoneDomain := strings.ToLower(strings.TrimSuffix(cfg.ZoneDomain, "."))
	if !validZoneDomain(zoneDomain) {
		return nil, errors.New("agones resources: zone domain is invalid")
	}
	if cfg.Observer == nil {
		return nil, errors.New("agones resources: observer binding is required")
	}
	observationTimeout := cfg.ObservationTimeout
	if observationTimeout == 0 {
		observationTimeout = DefaultObservationTimeout
	}
	if observationTimeout < time.Millisecond || observationTimeout > MaxObservationTimeout {
		return nil, errors.New(
			"agones resources: observation timeout must be between one millisecond and one minute",
		)
	}
	observationInterval := cfg.ObservationInterval
	if observationInterval == 0 {
		observationInterval = DefaultObservationInterval
	}
	if observationInterval < time.Millisecond || observationInterval > observationTimeout {
		return nil, errors.New(
			"agones resources: observation interval must be between one millisecond and the timeout",
		)
	}
	return &Adapter{
		allocator:           allocator,
		resources:           resources,
		keyring:             keyring,
		zoneDomain:          zoneDomain,
		observer:            cfg.Observer,
		observationTimeout:  observationTimeout,
		observationInterval: observationInterval,
	}, nil
}

// Provision performs the one allocation dispatch permitted for an attempt. It
// first adopts any Allocated GameServer already carrying the exact attempt
// label, dispatches exactly one allocation otherwise, then waits within the
// observation budget for exactly one attempt-labelled object named by the
// response, pins it by UID and validates it against the response before
// opening its envelope. Duplicates are released and fail closed; an object
// that never becomes observable leaves the dispatch ambiguous.
func (a *Adapter) Provision(
	ctx context.Context,
	request handoff.AllocationRequest,
	expiresAt time.Time,
) (handoffalloc.Provisioned, error) {
	return a.observe(ctx, request, expiresAt, true)
}

// Reconcile observes an already-dispatched attempt and never allocates. Zero
// matches is the ambiguous outcome the coordinator quarantines, one match is
// adopted through the same pinned validation as a fresh allocation, and more
// than one match is released by each object's own UID and fails closed.
func (a *Adapter) Reconcile(
	ctx context.Context,
	request handoff.AllocationRequest,
	expiresAt time.Time,
) (handoffalloc.Provisioned, error) {
	return a.observe(ctx, request, expiresAt, false)
}

// observe is the one reconciliation both entry points share: exactly one
// attempt-labelled Allocated GameServer is adopted, duplicates are released and
// fail closed, and zero matches either dispatches the single permitted
// allocation — when the caller holds the coordinator's dispatch barrier — or
// reports the ambiguous outcome.
func (a *Adapter) observe(
	ctx context.Context,
	request handoff.AllocationRequest,
	expiresAt time.Time,
	dispatch bool,
) (handoffalloc.Provisioned, error) {
	observer, err := a.observerFor(request)
	if err != nil {
		return handoffalloc.Provisioned{}, err
	}
	observed, err := a.allocatedForAttempt(ctx, request.AttemptID)
	if err != nil {
		return handoffalloc.Provisioned{}, err
	}
	switch len(observed) {
	case 1:
		return a.adopt(ctx, request, observed[0].Identity, nil, observer, expiresAt)
	case 0:
		if !dispatch {
			return handoffalloc.Provisioned{}, ErrAmbiguousDispatch
		}
	default:
		return handoffalloc.Provisioned{}, a.releaseDuplicates(ctx, observed)
	}
	reserved, err := a.allocator.Reserve(ctx, agonesalloc.Request{
		ReservationID: request.ReservationID,
		AttemptID:     request.AttemptID,
		LeaseObjectID: nakamalease.ReservationKey(request.UserID, request.ReservationID),
	})
	if err != nil {
		return handoffalloc.Provisioned{}, err
	}
	identity, err := a.observeDispatched(ctx, request.AttemptID, reserved.Name)
	if err != nil {
		return handoffalloc.Provisioned{}, err
	}
	return a.adopt(ctx, request, identity, &reserved, observer, expiresAt)
}

// allocatedForAttempt lists every object carrying the exact attempt label and
// keeps only those Agones still has Allocated. The filter is deliberate: an
// attempt's GameServer that has gone Unhealthy or Shutdown keeps its labels
// until the object is collected, and refusing the whole listing over one such
// leftover would make a live attempt permanently unadoptable and its cleanup
// permanently stuck.
func (a *Adapter) allocatedForAttempt(
	ctx context.Context,
	attemptID string,
) ([]gameserverapi.GameServer, error) {
	observed, err := a.resources.ListAttempt(ctx, attemptID)
	if err != nil {
		return nil, classifyResourceError(err)
	}
	allocated := observed[:0]
	for _, gameServer := range observed {
		if gameServer.State == agonesv1.GameServerStateAllocated {
			allocated = append(allocated, gameServer)
		}
	}
	return allocated, nil
}

// Resolve reads the exact GameServer a durable lease names and recomputes
// every reference component before returning its admission secret. A changed
// UID, envelope, key, label, port or state is an invalid resource, never an
// opportunity to repair in place.
func (a *Adapter) Resolve(
	ctx context.Context,
	lease nakamalease.Lease,
) (handoff.Allocation, error) {
	if lease.AllocationID == "" || lease.SecretRef == "" {
		return handoff.Allocation{}, ErrInvalidResource
	}
	gameServer, err := a.resources.GetAllocatedByName(ctx, lease.AllocationID, lease.AttemptID)
	if err != nil {
		return handoff.Allocation{}, classifyResourceError(err)
	}
	material, err := material(gameServer)
	if err != nil {
		return handoff.Allocation{}, err
	}
	opened, err := a.keyring.Resolve(lease.SecretRef, material)
	if err != nil {
		return handoff.Allocation{}, ErrInvalidResource
	}
	return a.allocation(gameServer, lease.Observer, opened.Secret(), lease.ExpiresAt), nil
}

// Release deletes the exact GameServer a lease owns with that object's UID as
// a precondition. A lease that names its allocation is proven against the
// attempt label and the UID digest its reference pins, so a stale release never
// deletes a newer attempt's object or a recreated incarnation; the object's
// state, port, node and sealed material are deliberately NOT required, because
// an object Agones has already moved on from must still be deletable and the
// zone controls its own annotations. A staging lease that carries only an
// attempt ID is discovered by the attempt label alone. Absence and a changed
// UID are success, because the object this lease owned is gone.
func (a *Adapter) Release(ctx context.Context, lease nakamalease.Lease) error {
	if lease.AllocationID != "" {
		// A lease that names an allocation but pins no reference cannot prove
		// which object it owned, so it fails closed rather than deleting on an
		// unpinned read. The lease store never writes that shape.
		if lease.SecretRef == "" {
			return ErrInvalidResource
		}
		located, err := a.resources.Locate(ctx, lease.AllocationID, lease.AttemptID)
		switch {
		case errors.Is(err, gameserverapi.ErrNotFound),
			errors.Is(err, gameserverapi.ErrNotOwned):
			return nil
		case err != nil:
			return classifyResourceError(err)
		}
		if !admissionref.ReferenceBinds(lease.SecretRef, string(located.Identity.UID)) {
			return nil
		}
		return a.delete(ctx, located.Identity)
	}
	observed, err := a.resources.ListAttempt(ctx, lease.AttemptID)
	if err != nil {
		return classifyResourceError(err)
	}
	var first error
	for _, gameServer := range observed {
		if err := a.delete(ctx, gameServer.Identity); err != nil && first == nil {
			first = err
		}
	}
	return first
}

// observerFor applies the injected binding policy and refuses a missing entity
// before the adapter can dispatch or adopt a GameServer.
func (a *Adapter) observerFor(request handoff.AllocationRequest) (sim.EntityID, error) {
	observer, err := a.observer(request)
	if err != nil {
		return 0, fmt.Errorf("agones resources: bind observer: %w", err)
	}
	if observer == 0 {
		return 0, errors.New("agones resources: observer binding is missing")
	}
	return observer, nil
}

// observeDispatched waits, within the observation budget, for exactly one
// attempt-labelled Allocated GameServer carrying the name the allocation
// response returned. The caller's own cancellation is reported as such; the
// adapter's bound elapsing is the ambiguous outcome. A read that fails for a
// reason that will not resolve by waiting — an RBAC denial, a refused
// contract — is returned as itself rather than retried into an ambiguous
// dispatch, because that outcome quarantines the attempt permanently and
// "not yet observable" would name the wrong cause.
func (a *Adapter) observeDispatched(
	ctx context.Context,
	attemptID string,
	name string,
) (gameserverapi.Identity, error) {
	observeCtx, cancel := context.WithTimeout(ctx, a.observationTimeout)
	defer cancel()
	for {
		observed, err := a.allocatedForAttempt(observeCtx, attemptID)
		switch {
		case err == nil:
			switch len(observed) {
			case 0:
			case 1:
				if observed[0].Identity.Name == name {
					return observed[0].Identity, nil
				}
			default:
				return gameserverapi.Identity{}, a.releaseDuplicates(ctx, observed)
			}
		case errors.Is(err, errAPIUnavailable):
			// The object's state is unknown, which is what waiting is for.
		case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
			// Resolved below against the caller's own context.
		default:
			return gameserverapi.Identity{}, err
		}
		if err := wait(observeCtx, a.observationInterval); err != nil {
			if ctxErr := ctx.Err(); ctxErr != nil {
				return gameserverapi.Identity{}, ctxErr
			}
			return gameserverapi.Identity{}, ErrAmbiguousDispatch
		}
	}
}

// adopt rereads the pinned identity, checks any allocation response against the
// observed material, and opens the envelope before returning connection data.
func (a *Adapter) adopt(
	ctx context.Context,
	request handoff.AllocationRequest,
	identity gameserverapi.Identity,
	reserved *agonesalloc.GameServer,
	observer sim.EntityID,
	expiresAt time.Time,
) (handoffalloc.Provisioned, error) {
	pinned, err := a.resources.GetAllocated(ctx, identity, request.AttemptID)
	if err != nil {
		return handoffalloc.Provisioned{}, classifyResourceError(err)
	}
	material, err := material(pinned)
	if err != nil {
		return handoffalloc.Provisioned{}, err
	}
	if reserved != nil &&
		(material.WrappingKeyFingerprint != reserved.WrappingKeyFingerprint ||
			material.TLSPort != reserved.Port ||
			material.AdmissionEnvelope != reserved.AdmissionEnvelope) {
		return handoffalloc.Provisioned{}, ErrInvalidResource
	}
	opened, err := a.keyring.Open(material)
	if err != nil {
		return handoffalloc.Provisioned{}, ErrInvalidResource
	}
	return handoffalloc.Provisioned{
		Allocation: a.allocation(pinned, observer, opened.Secret(), expiresAt),
		SecretRef:  opened.SecretRef(),
	}, nil
}

// material rebuilds the exact sealed-admission material from one observed
// GameServer, refusing any object whose ready label, key fingerprint, envelope,
// node name or TLS port is missing or inconsistent. The fingerprint is the
// object's own, not the current pool's: a lease sealed under a retained
// previous key must keep resolving across a rotation, and the keyring decides
// whether it still holds that key.
func material(gameServer gameserverapi.GameServer) (admissionref.Material, error) {
	fingerprint := gameServer.Annotations[agones.AdmissionKeyAnnotation]
	envelope := gameServer.Annotations[agones.AdmissionEnvelopeAnnotation]
	if fingerprint == "" ||
		gameServer.Labels[agones.AdmissionReadyLabel] != agones.AdmissionReadyValue(fingerprint) ||
		envelope == "" ||
		gameServer.TLSPort == 0 ||
		len(validation.IsDNS1123Subdomain(gameServer.NodeName)) != 0 {
		return admissionref.Material{}, ErrInvalidResource
	}
	return admissionref.Material{
		Namespace:              gameServer.Identity.Namespace,
		GameServerName:         gameServer.Identity.Name,
		GameServerUID:          string(gameServer.Identity.UID),
		WrappingKeyFingerprint: fingerprint,
		AdmissionEnvelope:      envelope,
		TLSPort:                gameServer.TLSPort,
	}, nil
}

// allocation combines validated GameServer material with the bound observer and
// lease expiry, advertising the node's name under the configured zone domain.
func (a *Adapter) allocation(
	gameServer gameserverapi.GameServer,
	observer sim.EntityID,
	secret []byte,
	expiresAt time.Time,
) handoff.Allocation {
	return handoff.Allocation{
		ID:              gameServer.Identity.Name,
		ServerName:      gameServer.NodeName + "." + a.zoneDomain,
		Port:            gameServer.TLSPort,
		Observer:        observer,
		AdmissionSecret: secret,
		LeaseExpiresAt:  expiresAt,
	}
}

// releaseDuplicates moves every duplicate match through release with its own
// UID precondition on the coordinator's staged-cleanup budget, which survives
// the caller's cancellation, then fails closed. A delete that did not succeed
// is reported through a distinct outcome rather than swallowed: a surviving
// duplicate is a leaked GameServer, and nothing else in this composition is
// looking for it.
func (a *Adapter) releaseDuplicates(
	ctx context.Context,
	observed []gameserverapi.GameServer,
) error {
	cleanupCtx, cancel := context.WithTimeout(
		context.WithoutCancel(ctx),
		handoffalloc.StagedCleanupTimeout,
	)
	defer cancel()
	retained := false
	for _, gameServer := range observed {
		if err := a.delete(cleanupCtx, gameServer.Identity); err != nil {
			retained = true
		}
	}
	if retained {
		return ErrDuplicateAttemptRetained
	}
	return ErrDuplicateAttempt
}

// delete removes one exact identity. Absence means the object is already
// gone; a precondition conflict means a different UID now owns the name and is
// deliberately left untouched.
func (a *Adapter) delete(ctx context.Context, identity gameserverapi.Identity) error {
	err := a.resources.Delete(ctx, identity)
	switch {
	case err == nil,
		errors.Is(err, gameserverapi.ErrNotFound),
		apierrors.IsConflict(err):
		return nil
	default:
		return classifyResourceError(err)
	}
}

// classifyResourceError maps a resource-boundary failure to the outcome class
// a caller may act on without carrying any Kubernetes detail forward. The
// boundary itself decides which failures left this object's state merely
// unknown, so a transport failure or a transient server response stays
// retryable here instead of being reported as a permanent contract refusal.
func classifyResourceError(err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, context.DeadlineExceeded):
		return context.DeadlineExceeded
	case errors.Is(err, gameserverapi.ErrNotFound):
		return ErrNotFound
	case errors.Is(err, gameserverapi.ErrUnavailable):
		return errAPIUnavailable
	default:
		return ErrInvalidResource
	}
}

// wait paces observation retries and returns promptly when their context ends.
func wait(ctx context.Context, interval time.Duration) error {
	timer := time.NewTimer(interval)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// validZoneDomain accepts a nonempty DNS subdomain and excludes IP literals,
// since the advertised endpoint must carry a DNS certificate name.
func validZoneDomain(value string) bool {
	return value != "" &&
		net.ParseIP(value) == nil &&
		len(validation.IsDNS1123Subdomain(value)) == 0
}
