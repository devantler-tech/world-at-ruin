package gameservercommit

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"reflect"
	"slices"
	"sync/atomic"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
)

// Recovery exposes only a barrier attempt; it cannot prepare or allocate targets.
// Its sole inventory input is a live owner's opaque acknowledged reservation.
type Recovery struct{ state *recoveryState }
type recoveryState struct {
	client      *Client
	reservation allocatoradmission.RecoveryReservation
	accepted    atomic.Pointer[RecoveryObservation]
}

// RecoveryResult is complete, process-local authority. Diagnostics cannot
// reconstruct it, and no durable publication or quarantine release is provided.
type RecoveryResult struct {
	state       *recoveryState
	observation *RecoveryObservation
}
type RecoveryObservation struct {
	Owner  allocatoradmission.RecoveryOwnerObservation
	Grants []GenerationGrantObservation
}

func NewRecovery(cfg Config, reservation allocatoradmission.RecoveryReservation) (*Recovery, error) {
	c, err := New(cfg)
	if err != nil {
		return nil, err
	}
	return &Recovery{state: &recoveryState{client: c, reservation: reservation}}, nil
}
func (r *Recovery) Fence(ctx context.Context) (RecoveryResult, error) {
	if r == nil || r.state == nil {
		return RecoveryResult{}, ErrClosed
	}
	owner, err := r.state.reservation.Consume()
	if err != nil {
		return RecoveryResult{}, ErrClosed
	}
	ctx, cancel := context.WithTimeout(ctx, requestLimit)
	defer cancel()
	c := r.state.client
	b := owner.Handoff.Journal.Binding
	if ctx.Err() != nil || b.Namespace != c.namespace || b.Fleet != c.fleet {
		return RecoveryResult{}, ErrUnknown
	}
	got := RecoveryObservation{Owner: owner, Grants: make([]GenerationGrantObservation, 0, len(owner.Handoff.Journal.Grants))}
	for _, original := range owner.Handoff.Journal.Grants {
		observation, e := c.fenceRecovered(ctx, original)
		if e != nil {
			return RecoveryResult{}, ErrUnknown
		}
		got.Grants = append(got.Grants, GenerationGrantObservation{ActorUID: original.ActorUID, AttemptID: original.AttemptID, Observation: observation})
	}
	if ctx.Err() != nil {
		return RecoveryResult{}, ErrUnknown
	}
	r.state.accepted.Store(&got)
	return RecoveryResult{state: r.state, observation: &got}, nil
}

func (r *Recovery) Accept(result RecoveryResult) (RecoveryObservation, error) {
	if r == nil || r.state == nil || result.state != r.state || result.observation == nil || r.state.accepted.Load() != result.observation {
		return RecoveryObservation{}, ErrClosed
	}
	got := *result.observation
	got.Owner.Handoff.Journal.Binding.MemberPodUIDs = slices.Clone(got.Owner.Handoff.Journal.Binding.MemberPodUIDs)
	got.Owner.Handoff.Journal.Grants = slices.Clone(got.Owner.Handoff.Journal.Grants)
	got.Grants = slices.Clone(got.Grants)
	return got, nil
}

func (c *Client) fenceRecovered(ctx context.Context, original allocatorjournal.JournalGrant) (Observation, error) {
	attempt, err := agones.CorrelationLabel(original.AttemptID)
	if err != nil {
		return Observation{}, ErrUnknown
	}
	current, err := c.get(ctx, original.Name)
	identity := func(g *agonesv1.GameServer) bool {
		return g != nil && g.Namespace == c.namespace && g.Name == original.Name && string(g.UID) == original.UID && g.Labels[agonesv1.FleetNameLabel] == c.fleet && g.ResourceVersion != "" && g.DeletionTimestamp == nil
	}
	if err != nil || ctx.Err() != nil || !identity(current) || current.Annotations[BarrierAnnotation] != "" {
		return Observation{}, ErrUnknown
	}
	outcome := Uncommitted
	isAllocated := func(g *agonesv1.GameServer) bool {
		return g.Status.State == agonesv1.GameServerStateAllocated && g.Labels[agones.AttemptLabel] == attempt
	}
	switch {
	case current.ResourceVersion == original.SourceVersion && current.Status.State == agonesv1.GameServerStateReady && current.Labels[agones.AttemptLabel] == "":
	case current.ResourceVersion != original.SourceVersion && isAllocated(current):
		outcome = Allocated
	default:
		return Observation{}, ErrUnknown
	}
	var random [32]byte
	if _, err = rand.Read(random[:]); err != nil {
		return Observation{}, ErrUnknown
	}
	nonce := hex.EncodeToString(random[:])
	barrier := current.DeepCopy()
	if barrier.Annotations == nil {
		barrier.Annotations = make(map[string]string)
	}
	barrier.Annotations[BarrierAnnotation] = nonce
	matches := func(g *agonesv1.GameServer) bool {
		return identity(g) && g.Annotations[BarrierAnnotation] == nonce && reflect.DeepEqual(g.Spec, current.Spec) && reflect.DeepEqual(g.Status, current.Status) && reflect.DeepEqual(g.Labels, barrier.Labels) && reflect.DeepEqual(g.Annotations, barrier.Annotations)
	}
	ack, err := c.put(ctx, barrier)
	if err != nil || ctx.Err() != nil || !matches(ack) || ack.ResourceVersion == current.ResourceVersion || ack.ResourceVersion == original.SourceVersion {
		return Observation{}, ErrUnknown
	}
	readback, err := c.get(ctx, original.Name)
	if err != nil || ctx.Err() != nil || !matches(readback) || readback.ResourceVersion != ack.ResourceVersion {
		return Observation{}, ErrUnknown
	}
	return Observation{Namespace: c.namespace, Name: original.Name, UID: original.UID, SourceVersion: original.SourceVersion, BarrierVersion: ack.ResourceVersion, Outcome: outcome}, nil
}
