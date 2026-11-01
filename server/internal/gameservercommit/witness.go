package gameservercommit

import (
	"context"
	"reflect"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
)

// The generation witness stages this package writes, by the names and in the
// record the admission package declares.
const (
	WitnessRegistered = allocatoradmission.WitnessRegistered
	WitnessDrained    = allocatoradmission.WitnessDrained
	WitnessHandoff    = allocatoradmission.WitnessHandoff
	WitnessRecovered  = allocatoradmission.WitnessRecovered
	WitnessPublished  = allocatoradmission.WitnessPublished
)

// WitnessRecord is one allocator generation's witness record.
type WitnessRecord = allocatoradmission.WitnessRecord

// GenerationWitness moves the witness record in one conditional write; see the
// admission package's declaration.
type GenerationWitness = allocatoradmission.GenerationWitness

// GenerationWitnessConfig opts the durable generation into persist-before-ACK
// witnessing of its root registration, every grant registration, its drain
// and its recovery handoff. Its zero value composes no witness; a
// half-configured value (enabled without a witness, or a witness without
// enablement) is refused.
type GenerationWitnessConfig struct {
	Enabled bool
	Witness GenerationWitness
}

// compose returns the opted-in witness, nil for the zero value, and false for
// a half-configured value.
func (c GenerationWitnessConfig) compose() (GenerationWitness, bool) {
	// A typed nil is as missing as an untyped one.
	missing := c.Witness == nil
	if v := reflect.ValueOf(c.Witness); !missing && nilable[v.Kind()] {
		missing = v.IsNil()
	}
	if c.Enabled == missing {
		return nil, false
	}
	if !c.Enabled {
		return nil, true
	}
	return c.Witness, true
}

// nilable lists the kinds whose values can be a typed nil.
var nilable = map[reflect.Kind]bool{
	reflect.Chan: true, reflect.Func: true, reflect.Interface: true,
	reflect.Map: true, reflect.Pointer: true, reflect.Slice: true,
}

// generationWitness holds the last record the witness acknowledged for one
// generation. It is protected by the durable gate.
type generationWitness struct {
	writer GenerationWitness
	key    string
	acked  WitnessRecord
}

// advance witnesses stage for the acknowledged Nakama snapshot, conditional on
// the previously witnessed record. A registration replaces the registration
// fields with the snapshot's complete issued set; a drain keeps them and adds
// its pin. Each pin is the digest of the stage's originating Nakama
// acknowledgement. Only an acknowledged write moves the retained record.
func (w *generationWitness) advance(ctx context.Context, stage string, snapshot *allocatoradmission.Snapshot) error {
	binding := snapshot.Observation().Journal.Binding
	pin, err := allocatoradmission.WitnessStagePin(stage, binding)
	if err != nil {
		return ErrUnknown
	}
	next := w.acked
	switch stage {
	case WitnessRegistered:
		next = WitnessRecord{
			GenerationKey: w.key, Stage: stage, GrantCount: binding.IssuedCount,
			IssuedDigest: binding.IssuedDigest, RegistrationPin: pin,
		}
	case WitnessDrained:
		next.Stage, next.DrainPin = stage, pin
	default:
		return ErrInvalid
	}
	return w.write(ctx, next)
}

// handoff witnesses the acknowledged private recovery handoff, conditional on
// the exact witnessed `drained` record. Its pin is the digest of the handoff
// create's acknowledgement: the handoff document's key, the drained binding it
// carries and the version Nakama acknowledged.
func (w *generationWitness) handoff(ctx context.Context, binding allocatorjournal.JournalBinding, version string) error {
	// The handoff must carry exactly the witnessed drained generation and
	// issued set; any other binding would pin a handoff of a different one.
	if w.acked.Stage != WitnessDrained || allocatoradmission.Key(binding.GenerationID) != w.key ||
		binding.IssuedCount != w.acked.GrantCount || binding.IssuedDigest != w.acked.IssuedDigest {
		return ErrInvalid
	}
	// The drain pin also binds the journal version, so only the exact drained
	// binding re-derives it.
	drainPin, err := allocatoradmission.WitnessStagePin(WitnessDrained, binding)
	if err != nil || drainPin != w.acked.DrainPin {
		return ErrInvalid
	}
	pin, err := allocatoradmission.WitnessHandoffPin(binding, version)
	if err != nil {
		return ErrUnknown
	}
	next := w.acked
	next.Stage, next.HandoffPin = WitnessHandoff, pin
	return w.write(ctx, next)
}

// write moves the retained record to next only when the witness acknowledges it.
func (w *generationWitness) write(ctx context.Context, next WitnessRecord) error {
	if err := w.writer.WriteGeneration(ctx, w.acked, next); err != nil {
		return unknown(ctx)
	}
	w.acked = next
	return nil
}

// witnessRecoveredPin digests every barrier's acknowledgement in the owner's
// inventory order, under the owner row that authorized them.
func witnessRecoveredPin(got RecoveryObservation) (string, error) {
	generationID := got.Owner.Handoff.Journal.Binding.GenerationID
	grants := make([]recoveryProofGrant, len(got.Grants))
	for i, g := range got.Grants {
		grants[i] = recoveryProofGrant{g.ActorUID, g.AttemptID, g.Namespace, g.Name, g.UID, g.SourceVersion, g.BarrierVersion, g.Outcome}
	}
	pin, err := allocatoradmission.WitnessPin(WitnessRecovered, allocatoradmission.RecoveryOwnerKey(generationID), got.Owner.Version, grants)
	if err != nil {
		return "", ErrUnknown
	}
	return pin, nil
}

// witnessPublishedPin digests the private proof create's acknowledgement.
func witnessPublishedPin(generationID, version string) (string, error) {
	pin, err := allocatoradmission.WitnessPin(WitnessPublished, RecoveryProofCollection, RecoveryProofKey(generationID), version)
	if err != nil {
		return "", ErrUnknown
	}
	return pin, nil
}
