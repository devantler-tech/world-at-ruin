package gameservercommit

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
)

// DurableGenerationConfig supplies operator-owned dependencies for the inactive
// composition. Journal contents and originating snapshots remain private.
type DurableGenerationConfig struct {
	Enabled       bool
	Commit        Config
	Record        nakamageneration.Record
	IncarnationID string
	Storage       allocatoradmission.Storage
}

// NewDurableGeneration requires explicit enablement before touching storage.
// It never restores an existing generation from diagnostic readback.
func NewDurableGeneration(ctx context.Context, cfg DurableGenerationConfig) (*Generation, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	if ctx == nil || !handoffidentity.OpaqueUTF8(cfg.IncarnationID, 128) {
		return nil, ErrInvalid
	}
	g, err := NewGeneration(GenerationConfig{Enabled: true, Commit: cfg.Commit, Record: cfg.Record})
	if err != nil {
		return nil, err
	}
	// Validate original identities before JSON can replace malformed UTF-8.
	r := g.state.record
	digest := sha256.Sum256([]byte("world-at-ruin/allocator-issued-grants/v1\n[]"))
	value, err := json.Marshal(map[string]any{
		"schema": 1, "generation_id": r.GenerationID, "generation_source_version": r.Version,
		"member_pod_uids": r.MemberPodUIDs, "member_set_digest": r.MemberSetDigest,
		"authority_incarnation": cfg.IncarnationID, "namespace": cfg.Commit.Namespace, "fleet": cfg.Commit.Fleet,
		"grant_count": 0, "grant_set_digest": hex.EncodeToString(digest[:]), "grants": []allocatorjournal.JournalGrant{},
	})
	if err != nil {
		return nil, ErrInvalid
	}
	w, err := allocatoradmission.NewWriter(allocatoradmission.Config{Enabled: true, Storage: cfg.Storage, Journal: string(value)})
	if err != nil {
		return nil, ErrInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, requestLimit)
	defer cancel()
	head, err := w.Create(ctx)
	if err != nil {
		return nil, durableUnknown(ctx, err)
	}
	g.state.durable = &durableState{writer: w, head: head, gate: make(chan struct{}, 1)}
	return g, nil
}

// The network gate protects the latest acknowledged root and registration
// accounting. Local admission never waits for this gate while holding its mutex.
type durableState struct {
	writer *allocatoradmission.Writer
	head   *allocatoradmission.Snapshot
	gate   chan struct{}
}

func (d *durableState) lock(ctx context.Context) error {
	select {
	case d.gate <- struct{}{}:
		if ctx.Err() == nil {
			return nil
		}
		<-d.gate
	case <-ctx.Done():
	}
	return unknown(ctx)
}
func (d *durableState) unlock() { <-d.gate }

func (s *generationState) register(ctx context.Context, grant Grant, actor, attempt string) (GenerationGrant, error) {
	d := s.durable
	if err := d.lock(ctx); err != nil {
		return GenerationGrant{}, err
	}
	defer d.unlock()
	s.mu.Lock()
	closed := s.closed || len(s.grants) >= maxGrants
	s.mu.Unlock()
	if closed {
		return GenerationGrant{}, ErrClosed
	}
	frozen := grant.state.frozen
	next, err := d.writer.Register(ctx, d.head, allocatorjournal.JournalGrant{
		ActorUID: actor, AttemptID: attempt, Name: frozen.Name,
		UID: string(frozen.UID), SourceVersion: frozen.ResourceVersion,
	})
	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil {
		// An uncertain registered entry survives conservatively in storage. No
		// existing handle can submit after uncertainty, and no receipt can form.
		s.closed = true
		return GenerationGrant{}, durableUnknown(ctx, err)
	}
	d.head = next
	issued := &generationGrantState{owner: s, grant: grant, actor: actor, attempt: attempt}
	s.grants = append(s.grants, issued)
	if ctx.Err() != nil {
		s.closed = true
		return GenerationGrant{}, unknown(ctx)
	}
	if s.closed {
		return GenerationGrant{}, ErrClosed
	}
	return GenerationGrant{state: issued}, nil
}

func durableUnknown(ctx context.Context, err error) error {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return errors.Join(ErrUnknown, err)
	}
	return unknown(ctx)
}
