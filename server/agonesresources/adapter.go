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

	// duplicateCleanupTimeout bounds the release of duplicate matches so it
	// survives the caller's cancellation, mirroring the coordinator's own
	// staged-cleanup budget.
	duplicateCleanupTimeout = 5 * time.Second
	admissionReadyPrefix    = "v1-"
	fingerprintLength       = 52
)

// Sentinel outcomes carry the gRPC code the coordinator sanitizes them to, so
// a caller learns whether to retry without receiving any resource detail.
var (
	// ErrAmbiguousDispatch means an allocation may have committed but no exact
	// attempt-labelled GameServer is observable yet. The attempt stays
	// quarantined; the adapter never dispatches it again.
	ErrAmbiguousDispatch = &codedError{
		code:    codes.Unavailable,
		message: "agones resources: allocation outcome is not yet observable",
	}
	// ErrDuplicateAttempt means more than one GameServer carried the exact
	// attempt label. Every match was released by its own UID precondition and
	// the attempt fails closed.
	ErrDuplicateAttempt = &codedError{
		code:    codes.Aborted,
		message: "agones resources: attempt matched more than one GameServer",
	}
	// ErrInvalidResource means the exact GameServer exists but its identity,
	// state, label, port, key or envelope no longer matches what the attempt or
	// lease pinned. It is never repaired in place.
	ErrInvalidResource = &codedError{
		code:    codes.FailedPrecondition,
		message: "agones resources: GameServer does not match the durable attempt",
	}
	// ErrNotFound means the exact GameServer a lease names no longer exists.
	ErrNotFound = &codedError{
		code:    codes.NotFound,
		message: "agones resources: GameServer not found",
	}
)

type codedError struct {
	code    codes.Code
	message string
}

func (e *codedError) Error() string {
	return e.message
}

// GRPCStatus lets status.Code report the outcome class through the
// coordinator's sanitized error path.
func (e *codedError) GRPCStatus() *status.Status {
	return status.New(e.code, e.message)
}

// Config binds the adapter to one namespace, one current wrapping key, the
// managed zone domain and the observer-binding policy.
type Config struct {
	// Namespace is the GameServer namespace both boundaries operate in.
	Namespace string
	// WrappingKeyFingerprint selects the current envelope-ready pool and must
	// name a key the keyring holds.
	WrappingKeyFingerprint string
	// ZoneDomain is the managed zone-edge domain; a handoff advertises
	// <node name>.<ZoneDomain> because certificates bind node names, never a
	// GameServer's address.
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
	namespace           string
	fingerprint         string
	zoneDomain          string
	observer            func(handoff.AllocationRequest) (sim.EntityID, error)
	observationTimeout  time.Duration
	observationInterval time.Duration
}

var _ handoffalloc.GameServerResources = (*Adapter)(nil)

// NewAdapter validates the composition and refuses a current fingerprint the
// keyring cannot open, so the adapter never allocates a GameServer whose
// envelope it could not resolve.
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
	if len(validation.IsDNS1123Label(cfg.Namespace)) != 0 {
		return nil, errors.New("agones resources: namespace is invalid")
	}
	if !validFingerprint(cfg.WrappingKeyFingerprint) {
		return nil, errors.New("agones resources: wrapping-key fingerprint is invalid")
	}
	if !keyring.Holds(cfg.WrappingKeyFingerprint) {
		return nil, errors.New("agones resources: keyring does not hold the current wrapping key")
	}
	zoneDomain := strings.TrimSuffix(cfg.ZoneDomain, ".")
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
		namespace:           cfg.Namespace,
		fingerprint:         cfg.WrappingKeyFingerprint,
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
	observer, err := a.observerFor(request)
	if err != nil {
		return handoffalloc.Provisioned{}, err
	}
	observed, err := a.resources.ListAllocated(ctx, request.AttemptID)
	if err != nil {
		return handoffalloc.Provisioned{}, classifyResourceError(err)
	}
	switch len(observed) {
	case 0:
	case 1:
		return a.adopt(ctx, request, observed[0].Identity, nil, observer, expiresAt)
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
	if reserved.WrappingKeyFingerprint != a.fingerprint {
		return handoffalloc.Provisioned{}, ErrInvalidResource
	}
	identity, err := a.observeDispatched(ctx, request.AttemptID, reserved.Name)
	if err != nil {
		return handoffalloc.Provisioned{}, err
	}
	return a.adopt(ctx, request, identity, &reserved, observer, expiresAt)
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
	observer, err := a.observerFor(request)
	if err != nil {
		return handoffalloc.Provisioned{}, err
	}
	observed, err := a.resources.ListAllocated(ctx, request.AttemptID)
	if err != nil {
		return handoffalloc.Provisioned{}, classifyResourceError(err)
	}
	switch len(observed) {
	case 0:
		return handoffalloc.Provisioned{}, ErrAmbiguousDispatch
	case 1:
		return a.adopt(ctx, request, observed[0].Identity, nil, observer, expiresAt)
	default:
		return handoffalloc.Provisioned{}, a.releaseDuplicates(ctx, observed)
	}
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
	material, err := a.material(gameServer)
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
// a precondition. A lease that names its allocation is verified against the
// attempt label, the UID digest and the envelope digest first, so a stale
// release never deletes a newer attempt's object; a staging lease that carries
// only an attempt ID is discovered by the attempt label alone. Absence and a
// changed UID are success, because the object this lease owned is gone.
func (a *Adapter) Release(ctx context.Context, lease nakamalease.Lease) error {
	if lease.AllocationID != "" {
		located, err := a.resources.Locate(ctx, lease.AllocationID, lease.AttemptID)
		switch {
		case errors.Is(err, gameserverapi.ErrNotFound),
			errors.Is(err, gameserverapi.ErrNotOwned):
			return nil
		case err != nil:
			return classifyResourceError(err)
		}
		if lease.SecretRef != "" && !a.referenceMatches(located, lease.SecretRef) {
			return nil
		}
		return a.delete(ctx, located.Identity)
	}
	observed, err := a.resources.ListAllocated(ctx, lease.AttemptID)
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
// adapter's bound elapsing is the ambiguous outcome.
func (a *Adapter) observeDispatched(
	ctx context.Context,
	attemptID string,
	name string,
) (gameserverapi.Identity, error) {
	observeCtx, cancel := context.WithTimeout(ctx, a.observationTimeout)
	defer cancel()
	for {
		observed, err := a.resources.ListAllocated(observeCtx, attemptID)
		if err == nil {
			switch len(observed) {
			case 0:
			case 1:
				if observed[0].Identity.Name == name {
					return observed[0].Identity, nil
				}
			default:
				return gameserverapi.Identity{}, a.releaseDuplicates(ctx, observed)
			}
		}
		if err := wait(observeCtx, a.observationInterval); err != nil {
			if ctxErr := ctx.Err(); ctxErr != nil {
				return gameserverapi.Identity{}, ctxErr
			}
			return gameserverapi.Identity{}, ErrAmbiguousDispatch
		}
	}
}

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
	material, err := a.material(pinned)
	if err != nil {
		return handoffalloc.Provisioned{}, err
	}
	if reserved != nil &&
		(pinned.Identity.Name != reserved.Name ||
			material.WrappingKeyFingerprint != reserved.WrappingKeyFingerprint ||
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
// node name or TLS port is malformed or inconsistent. The fingerprint is the
// object's own, not the current pool's: a lease sealed under a retained
// previous key must keep resolving and releasing across a rotation, and the
// keyring decides whether it still holds that key.
func (a *Adapter) material(gameServer gameserverapi.GameServer) (admissionref.Material, error) {
	fingerprint := gameServer.Annotations[agones.AdmissionKeyAnnotation]
	envelope := gameServer.Annotations[agones.AdmissionEnvelopeAnnotation]
	if !validFingerprint(fingerprint) ||
		gameServer.Labels[agones.AdmissionReadyLabel] != admissionReadyPrefix+fingerprint ||
		envelope == "" ||
		gameServer.TLSPort == 0 ||
		len(validation.IsDNS1123Subdomain(gameServer.NodeName)) != 0 {
		return admissionref.Material{}, ErrInvalidResource
	}
	return admissionref.Material{
		Namespace:              a.namespace,
		GameServerName:         gameServer.Identity.Name,
		GameServerUID:          string(gameServer.Identity.UID),
		WrappingKeyFingerprint: fingerprint,
		AdmissionEnvelope:      envelope,
		TLSPort:                gameServer.TLSPort,
	}, nil
}

func (a *Adapter) referenceMatches(gameServer gameserverapi.GameServer, secretRef string) bool {
	material, err := a.material(gameServer)
	if err != nil {
		return false
	}
	reference, err := admissionref.Reference(material)
	return err == nil && reference == secretRef
}

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
// UID precondition on a bounded context that survives caller cancellation,
// then fails closed whatever the individual outcomes were.
func (a *Adapter) releaseDuplicates(
	ctx context.Context,
	observed []gameserverapi.GameServer,
) error {
	cleanupCtx, cancel := context.WithTimeout(
		context.WithoutCancel(ctx),
		duplicateCleanupTimeout,
	)
	defer cancel()
	for _, gameServer := range observed {
		_ = a.delete(cleanupCtx, gameServer.Identity)
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
		apierrors.IsNotFound(err),
		apierrors.IsConflict(err):
		return nil
	default:
		return classifyResourceError(err)
	}
}

// classifyResourceError maps a resource-boundary failure to the outcome class
// a caller may act on without carrying any Kubernetes detail forward: an
// absent object is NotFound, a transient API failure stays retryable, and every
// contract refusal is an invalid resource.
func classifyResourceError(err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, context.DeadlineExceeded):
		return context.DeadlineExceeded
	case errors.Is(err, gameserverapi.ErrNotFound), apierrors.IsNotFound(err):
		return ErrNotFound
	case apierrors.IsServerTimeout(err),
		apierrors.IsTimeout(err),
		apierrors.IsServiceUnavailable(err),
		apierrors.IsTooManyRequests(err),
		apierrors.IsInternalError(err),
		apierrors.IsUnexpectedServerError(err):
		return status.Error(codes.Unavailable, "agones resources: GameServer API is unavailable")
	default:
		return ErrInvalidResource
	}
}

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

func validFingerprint(value string) bool {
	if len(value) != fingerprintLength {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') && (char < '2' || char > '7') {
			return false
		}
	}
	return true
}

func validZoneDomain(value string) bool {
	return value != "" &&
		net.ParseIP(value) == nil &&
		strings.ToLower(value) == value &&
		len(validation.IsDNS1123Subdomain(value)) == 0
}
