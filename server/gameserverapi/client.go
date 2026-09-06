// Package gameserverapi owns the narrow Agones GameServer resource boundary
// used by durable handoff reconciliation.
package gameserverapi

import (
	"context"
	"errors"
	"fmt"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/validation"
)

var (
	// ErrNotFound means no GameServer carries the requested name.
	ErrNotFound = errors.New("gameserverapi: GameServer not found")
	// ErrNotOwned means the named GameServer exists but belongs to a different
	// Fleet or attempt, so a caller must leave it untouched.
	ErrNotOwned = errors.New("gameserverapi: GameServer belongs to a different Fleet or attempt")
	// ErrUnavailable means the API could not answer for this object, so its
	// state is unknown rather than refused and the call may be retried.
	ErrUnavailable = errors.New("gameserverapi: GameServer API is unavailable")
)

// ResourceAPI is the complete Kubernetes capability granted to this boundary.
// It deliberately excludes create, update, patch, watch, and every non-
// GameServer resource.
type ResourceAPI interface {
	Get(context.Context, string, metav1.GetOptions) (*agonesv1.GameServer, error)
	List(context.Context, metav1.ListOptions) (*agonesv1.GameServerList, error)
	Delete(context.Context, string, metav1.DeleteOptions) error
}

// Config identifies the one namespace, Fleet, and player-facing TLS port this
// resource boundary may reconcile.
type Config struct {
	Namespace   string
	Fleet       string
	TLSPortName string
}

// Identity is the immutable Kubernetes identity of one observed GameServer.
type Identity struct {
	Namespace string
	Name      string
	UID       types.UID
}

// GameServer is a detached snapshot of the allocated resource material the
// durable handoff coordinator is allowed to consume.
type GameServer struct {
	Identity Identity
	State    agonesv1.GameServerState
	// NodeName is the Kubernetes node hosting the GameServer, which carries the
	// stable DNS identity a handoff advertises under the zone domain.
	NodeName    string
	TLSPort     uint16
	Labels      map[string]string
	Annotations map[string]string
}

// Client reads and deletes allocated GameServers through ResourceAPI.
type Client struct {
	api         ResourceAPI
	namespace   string
	fleet       string
	tlsPortName string
}

// NewClient builds a least-privilege GameServer resource boundary.
func NewClient(api ResourceAPI, cfg Config) (*Client, error) {
	if api == nil {
		return nil, errors.New("gameserverapi: resource API is required")
	}
	if len(validation.IsDNS1123Label(cfg.Namespace)) != 0 {
		return nil, errors.New("gameserverapi: namespace is invalid")
	}
	if len(cfg.Fleet) > 63 ||
		len(validation.IsDNS1123Subdomain(cfg.Fleet)) != 0 {
		return nil, errors.New("gameserverapi: Fleet is invalid")
	}
	if len(validation.IsDNS1123Label(cfg.TLSPortName)) != 0 {
		return nil, errors.New("gameserverapi: TLS port name is invalid")
	}
	return &Client{
		api:         api,
		namespace:   cfg.Namespace,
		fleet:       cfg.Fleet,
		tlsPortName: cfg.TLSPortName,
	}, nil
}

// GetAllocated reads one exact GameServer and refuses any changed identity,
// allocation correlation, Fleet membership, state, or TLS port.
func (c *Client) GetAllocated(
	ctx context.Context,
	expected Identity,
	attemptID string,
) (GameServer, error) {
	if err := c.validateIdentity(expected); err != nil {
		return GameServer{}, err
	}
	return c.read(ctx, expected.Name, &expected, attemptID, true)
}

// ListAttempt returns every GameServer carrying the exact Fleet and full
// attempt digest, in WHATEVER state Agones currently has it. It never chooses a
// winner when duplicates exist, and it never refuses the whole listing because
// one object has moved on: an attempt's GameServer that has gone Unhealthy or
// Shutdown still carries its labels, and cleanup must be able to see and delete
// it. A caller that needs an allocation rather than a cleanup target filters on
// State itself.
func (c *Client) ListAttempt(
	ctx context.Context,
	attemptID string,
) ([]GameServer, error) {
	attemptValue, err := agones.CorrelationLabel(attemptID)
	if err != nil {
		return nil, errors.New("gameserverapi: attempt ID is invalid")
	}
	selector := labels.Set{
		agones.FleetLabel:   c.fleet,
		agones.AttemptLabel: attemptValue,
	}.String()
	list, err := c.api.List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return nil, apiError("list", err)
	}
	gameServers := make([]GameServer, len(list.Items))
	for i := range list.Items {
		gameServers[i], err = c.snapshot(&list.Items[i], nil, attemptValue, false)
		if err != nil {
			return nil, err
		}
	}
	return gameServers, nil
}

// GetAllocatedByName reads the one GameServer with an exact name and refuses
// any changed Fleet membership, allocation correlation, state, or TLS port.
// The observed UID is reported rather than required, so a caller that pins
// identity through a durable digest can verify it downstream; an absent object
// is ErrNotFound.
func (c *Client) GetAllocatedByName(
	ctx context.Context,
	name string,
	attemptID string,
) (GameServer, error) {
	return c.read(ctx, name, nil, attemptID, true)
}

// Locate reads the one GameServer with an exact name for cleanup. Unlike the
// allocated reads it accepts any state and a missing TLS port, because a
// stale attempt must still be able to delete an object Agones has already
// moved on from. It still refuses to report an object that belongs to another
// Fleet or attempt (ErrNotOwned), and an absent object is ErrNotFound.
func (c *Client) Locate(
	ctx context.Context,
	name string,
	attemptID string,
) (GameServer, error) {
	return c.read(ctx, name, nil, attemptID, false)
}

// read is the one name-keyed get behind every exact read: it validates the
// inputs before touching the API, classifies the API failure, and hands the
// object to snapshot with the caller's state requirement.
func (c *Client) read(
	ctx context.Context,
	name string,
	expected *Identity,
	attemptID string,
	allocatedOnly bool,
) (GameServer, error) {
	if len(validation.IsDNS1123Subdomain(name)) != 0 {
		return GameServer{}, errors.New("gameserverapi: GameServer name is invalid")
	}
	attemptValue, err := agones.CorrelationLabel(attemptID)
	if err != nil {
		return GameServer{}, errors.New("gameserverapi: attempt ID is invalid")
	}
	gameServer, err := c.api.Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return GameServer{}, apiError("get", err)
	}
	observed, err := c.snapshot(gameServer, expected, attemptValue, allocatedOnly)
	if err != nil {
		return GameServer{}, err
	}
	if observed.Identity.Name != name {
		return GameServer{}, errors.New("gameserverapi: GameServer identity changed")
	}
	return observed, nil
}

// apiError classifies one Kubernetes API failure at the boundary that owns
// those errors, so a caller never has to interpret them: an absent object
// carries ErrNotFound, and anything that says nothing about this object's
// contract — a transport, DNS or TLS failure with no server response at all,
// or a server response that is explicitly transient — carries ErrUnavailable
// so the caller can retry rather than treat it as a permanent refusal.
func apiError(operation string, err error) error {
	switch {
	case apierrors.IsNotFound(err):
		return fmt.Errorf("%w: %w", ErrNotFound, err)
	case transientAPIError(err):
		return fmt.Errorf("%w: %s GameServer: %w", ErrUnavailable, operation, err)
	default:
		return fmt.Errorf("gameserverapi: %s GameServer: %w", operation, err)
	}
}

// transientAPIError reports whether a failure leaves this object's state
// unknown rather than refused. An error carrying no APIStatus never reached a
// server verdict at all — connection refused, EOF, TLS or DNS — which is the
// case the reason-based predicates below silently miss, because every one of
// them resolves through an APIStatus and returns false without one.
func transientAPIError(err error) bool {
	var status apierrors.APIStatus
	if !errors.As(err, &status) {
		return true
	}
	return apierrors.IsServerTimeout(err) ||
		apierrors.IsTimeout(err) ||
		apierrors.IsServiceUnavailable(err) ||
		apierrors.IsTooManyRequests(err) ||
		apierrors.IsInternalError(err) ||
		apierrors.IsUnexpectedServerError(err)
}

// Delete removes one exact GameServer with its observed UID as a Kubernetes
// precondition, so a recreated object can never be deleted by stale cleanup.
// An already-absent object carries ErrNotFound.
func (c *Client) Delete(ctx context.Context, identity Identity) error {
	if err := c.validateIdentity(identity); err != nil {
		return err
	}
	uid := identity.UID
	if err := c.api.Delete(ctx, identity.Name, metav1.DeleteOptions{
		Preconditions: &metav1.Preconditions{UID: &uid},
	}); err != nil {
		return apiError("delete", err)
	}
	return nil
}

// Namespace, Fleet and TLSPortName report the pool this boundary is bound to,
// so a composition can prove its other clients name the same one instead of
// discovering a mismatch as a leaked GameServer per attempt.
func (c *Client) Namespace() string { return c.namespace }

// Fleet reports the configured Fleet this boundary reconciles.
func (c *Client) Fleet() string { return c.fleet }

// TLSPortName reports the configured player-facing TLS port name.
func (c *Client) TLSPortName() string { return c.tlsPortName }

func (c *Client) validateIdentity(identity Identity) error {
	if identity.Namespace != c.namespace {
		return errors.New("gameserverapi: GameServer namespace does not match")
	}
	if len(validation.IsDNS1123Subdomain(identity.Name)) != 0 {
		return errors.New("gameserverapi: GameServer name is invalid")
	}
	if identity.UID == "" {
		return errors.New("gameserverapi: GameServer UID is required")
	}
	return nil
}

// snapshot validates the observed object and any pinned identity, refuses an
// object that belongs to another Fleet or attempt with ErrNotOwned, and — when
// the caller needs an allocation rather than a cleanup target — requires the
// Allocated state and exactly one valid TLS port. Returned metadata maps are
// detached copies.
func (c *Client) snapshot(
	gameServer *agonesv1.GameServer,
	expected *Identity,
	attemptValue string,
	allocatedOnly bool,
) (GameServer, error) {
	if gameServer == nil {
		return GameServer{}, errors.New("gameserverapi: GameServer response is missing")
	}
	identity := Identity{
		Namespace: gameServer.Namespace,
		Name:      gameServer.Name,
		UID:       gameServer.UID,
	}
	if err := c.validateIdentity(identity); err != nil {
		return GameServer{}, err
	}
	if expected != nil && identity != *expected {
		return GameServer{}, errors.New("gameserverapi: GameServer identity changed")
	}
	if gameServer.Labels[agones.FleetLabel] != c.fleet ||
		gameServer.Labels[agones.AttemptLabel] != attemptValue {
		return GameServer{}, ErrNotOwned
	}
	tlsPort, err := c.tlsPort(gameServer.Status.Ports)
	if allocatedOnly {
		if gameServer.Status.State != agonesv1.GameServerStateAllocated {
			return GameServer{}, errors.New("gameserverapi: GameServer is not Allocated")
		}
		if err != nil {
			return GameServer{}, err
		}
	}
	return GameServer{
		Identity:    identity,
		State:       gameServer.Status.State,
		NodeName:    gameServer.Status.NodeName,
		TLSPort:     tlsPort,
		Labels:      copyStringMap(gameServer.Labels),
		Annotations: copyStringMap(gameServer.Annotations),
	}, nil
}

func (c *Client) tlsPort(ports []agonesv1.GameServerStatusPort) (uint16, error) {
	var value int32
	matches := 0
	for _, port := range ports {
		if port.Name == c.tlsPortName {
			matches++
			value = port.Port
		}
	}
	if matches != 1 || value < 1 || value > 65535 {
		return 0, errors.New("gameserverapi: GameServer TLS port is invalid")
	}
	return uint16(value), nil
}

func copyStringMap(source map[string]string) map[string]string {
	if source == nil {
		return nil
	}
	copied := make(map[string]string, len(source))
	for key, value := range source {
		copied[key] = value
	}
	return copied
}
