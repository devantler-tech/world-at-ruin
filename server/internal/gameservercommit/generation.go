package gameservercommit

import (
	"context"
	"slices"
	"sync"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
)

// GenerationConfig pins an observed open generation, not authenticated allocator
// membership. Explicit enablement creates a private experimental commit client;
// Commit.Enabled is superseded by Enabled. No durable state is written.
type GenerationConfig struct {
	Enabled bool
	Commit  Config
	Record  nakamageneration.Record
}

// Generation owns every capability it exports in one process incarnation.
// Copies share admission, the immutable issued set and receipt provenance.
type Generation struct{ state *generationState }
type generationState struct {
	mu      sync.Mutex
	client  *Client
	record  nakamageneration.Record
	closed  bool
	grants  []*generationGrantState
	receipt *generationReceiptState
}

// NewGeneration requires a bounded, canonical writable-schema open observation.
// Its private client and raw grants are never returned to callers.
func NewGeneration(cfg GenerationConfig) (*Generation, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	if !validGenerationRecord(cfg.Record) {
		return nil, ErrInvalid
	}
	cfg.Commit.Enabled = true
	client, err := New(cfg.Commit)
	if err != nil {
		return nil, err
	}
	record := cfg.Record
	record.MemberPodUIDs = slices.Clone(record.MemberPodUIDs)
	return &Generation{state: &generationState{client: client, record: record}}, nil
}

// validGenerationRecord checks writable-schema identity, canonical bounded
// membership and its digest; it does not authenticate production writers.
func validGenerationRecord(r nakamageneration.Record) bool {
	return !r.ReaderOnly() && r.State == "open" && allocatorjournal.ValidGenerationBinding(r.GenerationID, r.Version, r.MemberPodUIDs, r.MemberSetDigest)
}

// GenerationGrant cannot be detached from its generation's admission gate.
// ActorUID is caller attribution checked against membership, not RPC identity.
type GenerationGrant struct{ state *generationGrantState }
type generationGrantState struct {
	owner   *generationState
	grant   Grant
	actor   string
	attempt string
}

// Prepare exports a capability only after registering it under open admission.
// A GET returning after closure leaves its private raw capability unexported;
// it cannot submit and is not part of the frozen issued set.
func (g *Generation) Prepare(ctx context.Context, actorUID, name, attemptID string) (GenerationGrant, error) {
	if g == nil || g.state == nil {
		return GenerationGrant{}, ErrInvalid
	}
	s := g.state
	s.mu.Lock()
	if s.closed || len(s.grants) >= maxGrants {
		s.mu.Unlock()
		return GenerationGrant{}, ErrClosed
	}
	if !slices.Contains(s.record.MemberPodUIDs, actorUID) {
		s.mu.Unlock()
		return GenerationGrant{}, ErrInvalid
	}
	s.mu.Unlock()
	grant, err := s.client.Prepare(ctx, name, attemptID)
	if err != nil {
		return GenerationGrant{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return GenerationGrant{}, ErrClosed
	}
	issued := &generationGrantState{owner: s, grant: grant, actor: actorUID, attempt: attemptID}
	s.grants = append(s.grants, issued)
	return GenerationGrant{state: issued}, nil
}

// Commit serializes local admission against generation closure, then submits
// the frozen PUT outside that lock so Fence can invalidate an outstanding write.
func (g GenerationGrant) Commit(ctx context.Context) error {
	if g.state == nil {
		return ErrInvalid
	}
	s := g.state
	s.owner.mu.Lock()
	if s.owner.closed {
		s.owner.mu.Unlock()
		return ErrClosed
	}
	obj, err := s.grant.admit()
	s.owner.mu.Unlock()
	if err != nil {
		return err
	}
	return s.grant.submit(ctx, obj)
}

// GenerationGrantObservation retains the exact issued capability's attribution
// and storage outcome. Allocated is never reinterpreted as uncommitted.
type GenerationGrantObservation struct {
	ActorUID, AttemptID string
	Observation
}

// GenerationObservation describes this complete process-local issued set only.
// It cannot establish exclusive production writers or release quarantine.
type GenerationObservation struct {
	GenerationID, SourceVersion, MemberSetDigest string
	MemberPodUIDs                                []string
	Grants                                       []GenerationGrantObservation
}

// GenerationReceipt is opaque and cannot be reconstructed across incarnations.
type GenerationReceipt struct{ state *generationReceiptState }
type generationReceiptState struct {
	origin      *generationState
	observation GenerationObservation
}

// Fence irreversibly closes the entire issued set before networking. Every
// grant needs an acknowledged exact barrier. One unknown outcome prevents any
// complete receipt; partial barriers are never replayed or admission reopened.
func (g *Generation) Fence(ctx context.Context) (GenerationReceipt, error) {
	if g == nil || g.state == nil {
		return GenerationReceipt{}, ErrInvalid
	}
	s := g.state
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return GenerationReceipt{}, ErrClosed
	}
	s.closed = true
	issued := slices.Clone(s.grants)
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, requestLimit)
	defer cancel()
	got := GenerationObservation{GenerationID: s.record.GenerationID, SourceVersion: s.record.Version,
		MemberSetDigest: s.record.MemberSetDigest, MemberPodUIDs: slices.Clone(s.record.MemberPodUIDs),
		Grants: make([]GenerationGrantObservation, 0, len(issued))}
	for _, grant := range issued {
		r, err := grant.grant.Fence(ctx)
		if err != nil {
			return GenerationReceipt{}, unknown(ctx)
		}
		observed, err := grant.grant.Accept(r)
		if err != nil {
			return GenerationReceipt{}, unknown(ctx)
		}
		got.Grants = append(got.Grants, GenerationGrantObservation{ActorUID: grant.actor, AttemptID: grant.attempt, Observation: observed})
	}
	if ctx.Err() != nil {
		return GenerationReceipt{}, unknown(ctx)
	}
	r := &generationReceiptState{origin: s, observation: got}
	s.mu.Lock()
	s.receipt = r
	s.mu.Unlock()
	return GenerationReceipt{state: r}, nil
}

// Accept proves the receipt's private origin and returns only detached data.
// An empty issued set covers zero capabilities, never real allocator membership.
func (g *Generation) Accept(r GenerationReceipt) (GenerationObservation, error) {
	if g == nil || g.state == nil || r.state == nil {
		return GenerationObservation{}, ErrInvalid
	}
	s := g.state
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.closed || r.state != s.receipt || r.state.origin != s || len(r.state.observation.Grants) != len(s.grants) {
		return GenerationObservation{}, ErrInvalid
	}
	got := r.state.observation
	got.MemberPodUIDs = slices.Clone(got.MemberPodUIDs)
	got.Grants = slices.Clone(got.Grants)
	return got, nil
}
