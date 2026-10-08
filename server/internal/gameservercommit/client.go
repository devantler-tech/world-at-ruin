// Package gameservercommit implements an inactive exact-version Kubernetes
// mutation capability and a private owner of complete issued capability sets.
// Process-local receipts cannot close a durable allocator generation or release
// production quarantine.
package gameservercommit

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"
	"sync"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	typed "agones.dev/agones/pkg/client/clientset/versioned/typed/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/rest"
)

const (
	// BarrierAnnotation carries a unique acknowledged mutation, never a no-op.
	BarrierAnnotation = "world-at-ruin.dev/allocation-commit-barrier"
	maxGrants         = 256
	requestLimit      = 30 * time.Second
)

var (
	ErrDisabled = errors.New("gameservercommit: explicit enablement is required")
	ErrInvalid  = errors.New("gameservercommit: invalid preparation")
	ErrClosed   = errors.New("gameservercommit: capability is already submitted or drained")
	ErrConflict = errors.New("gameservercommit: frozen conditional write was refused")
	ErrUnknown  = errors.New("gameservercommit: outcome remains unknown")
)

// Config scopes this experimental client to one namespace and Fleet.
// REST credentials are operator-owned; no discovery or production switch exists.
type Config struct {
	Enabled   bool
	REST      *rest.Config
	Namespace string
	Fleet     string
}

// Client retains a bounded, closed set of process-local grants.
type Client struct {
	api       rest.Interface
	namespace string
	fleet     string
	mu        sync.Mutex
	admitted  map[string]bool
}

// New refuses default construction and copies the operator's REST configuration.
func New(cfg Config) (*Client, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	if cfg.REST == nil || len(validation.IsDNS1123Label(cfg.Namespace)) != 0 ||
		len(validation.IsDNS1123Subdomain(cfg.Fleet)) != 0 || len(cfg.Fleet) > 63 {
		return nil, ErrInvalid
	}
	copied := rest.CopyConfig(cfg.REST)
	if copied.Timeout < 0 || copied.Timeout > requestLimit {
		return nil, ErrInvalid
	}
	if copied.Timeout == 0 {
		copied.Timeout = requestLimit
	}
	if copied.UserAgent == "" {
		copied.UserAgent = rest.DefaultKubernetesUserAgent()
	}
	httpClient, err := rest.HTTPClientFor(copied)
	if err != nil {
		return nil, ErrInvalid
	}
	// MaxRetries(0) only disables client-go's retry loop. A 307/308 can
	// otherwise resubmit the frozen PUT through net/http's redirect policy.
	// Copy the client so the operator's transport and shared defaults stay intact.
	singleRequest := *httpClient
	singleRequest.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}
	transport := singleRequest.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	singleRequest.Transport = mutationTransport{base: transport}
	api, err := typed.NewForConfigAndClient(copied, &singleRequest)
	if err != nil {
		return nil, ErrInvalid
	}
	return &Client{api: api.RESTClient(), namespace: cfg.Namespace, fleet: cfg.Fleet, admitted: make(map[string]bool)}, nil
}

// The standard HTTP transports may replay a buffered body after an unprocessed
// HTTP/2 stream or a failed reused connection. Remove their replay capability
// from a private request copy; never modify the operator's underlying transport.
type mutationTransport struct{ base http.RoundTripper }

func (t mutationTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Method == http.MethodPut {
		single := req.Clone(req.Context())
		single.GetBody = nil
		return t.base.RoundTrip(single)
	}
	return t.base.RoundTrip(req)
}

// Grant is opaque. Copying it shares the same irreversible admission state.
type Grant struct{ state *grantState }
type grantState struct {
	mu        sync.Mutex
	client    *Client
	frozen    *agonesv1.GameServer
	attempt   string
	submitted bool
	draining  bool
	receipt   *receiptState
}

// Prepare freezes one Ready object, its UID/version and the entire update.
// Preparation never writes, discovers another resource, or refreshes a grant.
func (c *Client) Prepare(ctx context.Context, name, attemptID string) (Grant, error) {
	if c == nil || c.api == nil || len(validation.IsDNS1123Subdomain(name)) != 0 {
		return Grant{}, ErrInvalid
	}
	digest, err := agones.CorrelationLabel(attemptID)
	if err != nil {
		return Grant{}, ErrInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, requestLimit)
	defer cancel()
	obj, err := c.get(ctx, name)
	if err != nil {
		return Grant{}, unknown(ctx)
	}
	if obj.Namespace != c.namespace || obj.Name != name || obj.UID == "" || obj.ResourceVersion == "" ||
		obj.Labels[agones.FleetLabel] != c.fleet || obj.Labels[agones.AttemptLabel] != "" ||
		obj.Annotations[BarrierAnnotation] != "" || obj.Status.State != agonesv1.GameServerStateReady {
		return Grant{}, ErrInvalid
	}
	frozen := obj.DeepCopy()
	frozen.Status.State = agonesv1.GameServerStateAllocated
	if frozen.Labels == nil {
		frozen.Labels = make(map[string]string)
	}
	frozen.Labels[agones.AttemptLabel] = digest
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.admitted) >= maxGrants || c.admitted[string(frozen.UID)] {
		return Grant{}, ErrClosed
	}
	c.admitted[string(frozen.UID)] = true
	return Grant{state: &grantState{client: c, frozen: frozen, attempt: digest}}, nil
}

// Commit sends the frozen conditional mutation at most once. A lost reply
// remains unknown; neither Retry-After nor a redirect can resubmit the mutation.
func (g Grant) Commit(ctx context.Context) error {
	obj, err := g.admit()
	if err != nil {
		return err
	}
	return g.submit(ctx, obj)
}

// admit closes submission locally before networking. A generation owner holds
// its admission lock across this step, never across the outstanding HTTP call.
func (g Grant) admit() (*agonesv1.GameServer, error) {
	if g.state == nil {
		return nil, ErrInvalid
	}
	s := g.state
	s.mu.Lock()
	if s.submitted || s.draining {
		s.mu.Unlock()
		return nil, ErrClosed
	}
	s.submitted = true
	obj := s.frozen.DeepCopy()
	s.mu.Unlock()
	return obj, nil
}

func (g Grant) submit(ctx context.Context, obj *agonesv1.GameServer) error {
	s := g.state
	ctx, cancel := context.WithTimeout(ctx, requestLimit)
	defer cancel()
	ack, err := s.client.put(ctx, obj)
	if apierrors.IsConflict(err) {
		return ErrConflict
	}
	if err != nil || !s.sameIdentity(ack) || ack.ResourceVersion == "" ||
		ack.ResourceVersion == obj.ResourceVersion || !s.allocated(ack) {
		return unknown(ctx)
	}
	return nil
}

// Outcome describes the terminal observation for this one frozen capability.
type Outcome string

const (
	Uncommitted Outcome = "uncommitted"
	Allocated   Outcome = "allocated-before-barrier"
)

// Observation is detached diagnostic data, never a release authorization.
type Observation struct {
	Namespace      string
	Name           string
	UID            string
	SourceVersion  string
	BarrierVersion string
	Outcome        Outcome
}

// Receipt is bound to this handle and process incarnation. Public fields cannot
// reconstruct it; serialization, restart and another handle discard authority.
type Receipt struct{ state *receiptState }
type receiptState struct {
	origin      *grantState
	nonce       string
	observation Observation
}

// Fence closes local admission before contacting Kubernetes. Its independent
// exact-UID metadata CAS invalidates the frozen version. A receipt requires both
// an acknowledged mutation and an exact readback. Failed fences never reopen.
func (g Grant) Fence(ctx context.Context) (Receipt, error) {
	if g.state == nil {
		return Receipt{}, ErrInvalid
	}
	s := g.state
	s.mu.Lock()
	if s.draining {
		s.mu.Unlock()
		return Receipt{}, ErrClosed
	}
	s.draining = true
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, requestLimit)
	defer cancel()
	current, err := s.client.get(ctx, s.frozen.Name)
	if err != nil || !s.sameIdentity(current) || current.ResourceVersion == "" {
		return Receipt{}, unknown(ctx)
	}
	var outcome Outcome
	switch {
	case current.ResourceVersion == s.frozen.ResourceVersion &&
		current.Status.State == agonesv1.GameServerStateReady &&
		current.Labels[agones.AttemptLabel] == "":
		outcome = Uncommitted
	case s.allocated(current) && current.ResourceVersion != s.frozen.ResourceVersion:
		outcome = Allocated
	default:
		return Receipt{}, ErrUnknown
	}
	nonceBytes := make([]byte, 32)
	if _, err = rand.Read(nonceBytes); err != nil {
		return Receipt{}, ErrUnknown
	}
	nonce := hex.EncodeToString(nonceBytes)
	barrier := current.DeepCopy()
	if barrier.Annotations == nil {
		barrier.Annotations = make(map[string]string)
	}
	barrier.Annotations[BarrierAnnotation] = nonce
	ack, err := s.client.put(ctx, barrier)
	if err != nil || !s.sameIdentity(ack) || ack.ResourceVersion == "" ||
		ack.ResourceVersion == current.ResourceVersion || ack.ResourceVersion == s.frozen.ResourceVersion ||
		ack.Annotations[BarrierAnnotation] != nonce || !s.matchesOutcome(ack, outcome) {
		return Receipt{}, unknown(ctx)
	}
	readback, err := s.client.get(ctx, s.frozen.Name)
	if err != nil || !s.sameIdentity(readback) || readback.ResourceVersion != ack.ResourceVersion ||
		readback.Annotations[BarrierAnnotation] != nonce || !s.matchesOutcome(readback, outcome) {
		return Receipt{}, unknown(ctx)
	}
	receipt := &receiptState{origin: s, nonce: nonce, observation: Observation{
		Namespace: s.frozen.Namespace, Name: s.frozen.Name, UID: string(s.frozen.UID),
		SourceVersion: s.frozen.ResourceVersion, BarrierVersion: ack.ResourceVersion, Outcome: outcome,
	}}
	s.mu.Lock()
	s.receipt = receipt
	s.mu.Unlock()
	return Receipt{state: receipt}, nil
}

// Accept validates provenance without contacting or mutating Kubernetes.
func (g Grant) Accept(receipt Receipt) (Observation, error) {
	if g.state == nil || receipt.state == nil {
		return Observation{}, ErrInvalid
	}
	s := g.state
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.draining || receipt.state != s.receipt || receipt.state.origin != s ||
		receipt.state.nonce == "" {
		return Observation{}, ErrInvalid
	}
	return receipt.state.observation, nil
}

func (s *grantState) sameIdentity(obj *agonesv1.GameServer) bool {
	return obj != nil && obj.Namespace == s.frozen.Namespace && obj.Name == s.frozen.Name &&
		obj.UID == s.frozen.UID && obj.Labels[agones.FleetLabel] == s.client.fleet
}
func (s *grantState) allocated(obj *agonesv1.GameServer) bool {
	return obj.Status.State == agonesv1.GameServerStateAllocated && obj.Labels[agones.AttemptLabel] == s.attempt
}
func (s *grantState) matchesOutcome(obj *agonesv1.GameServer, outcome Outcome) bool {
	if outcome == Allocated {
		return s.allocated(obj)
	}
	return obj.Status.State == agonesv1.GameServerStateReady && obj.Labels[agones.AttemptLabel] == ""
}
func (c *Client) get(ctx context.Context, name string) (*agonesv1.GameServer, error) {
	obj := &agonesv1.GameServer{}
	err := c.api.Get().Namespace(c.namespace).Resource("gameservers").Name(name).
		MaxRetries(0).Do(ctx).Into(obj)
	return obj, err
}
func (c *Client) put(ctx context.Context, obj *agonesv1.GameServer) (*agonesv1.GameServer, error) {
	ack := &agonesv1.GameServer{}
	err := c.api.Put().Namespace(c.namespace).Resource("gameservers").Name(obj.Name).
		Body(obj.DeepCopy()).MaxRetries(0).Do(ctx).Into(ack)
	return ack, err
}
func unknown(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return errors.Join(ErrUnknown, err)
	}
	return ErrUnknown
}
