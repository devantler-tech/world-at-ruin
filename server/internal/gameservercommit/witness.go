package gameservercommit

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"reflect"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
)

// The generation witness stages this package writes. They are the custody
// witness generation family's stage names (#1444); later stages belong to
// later slices.
const (
	WitnessRegistered = "registered"
	WitnessDrained    = "drained"
	WitnessHandoff    = "handoff"
)

// WitnessRecord is one allocator generation's witness record, field for field
// the custody witness generation record. It is declared here so the commit
// authority, which the native trial command composes, never imports the
// witness client: that composition is a separate delivery, and the normal and
// trial artifacts are guarded against composing the witness.
type WitnessRecord struct {
	GenerationKey   string
	Stage           string
	GrantCount      int
	IssuedDigest    string
	RegistrationPin string
	DrainPin        string
	HandoffPin      string
}

// GenerationWitness moves the witness record from previous to next in one
// conditional write. It returns nil only when this call's own write is known
// to be stored; a lost reply is settled by one strongly consistent exact
// re-read (custody witness WriteGeneration), so any error means the stage is
// not witnessed.
type GenerationWitness interface {
	WriteGeneration(ctx context.Context, previous, next WitnessRecord) error
}

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

// witnessPinDomain separates generation witness pins from every other digest.
const witnessPinDomain = "world-at-ruin/allocator-generation-witness-pin/v1\n"

// witnessPin digests one stage's originating Nakama acknowledgement.
func witnessPin(parts ...any) (string, error) {
	encoded, err := json.Marshal(parts)
	if err != nil {
		return "", ErrUnknown
	}
	digest := sha256.Sum256(append([]byte(witnessPinDomain), encoded...))
	return hex.EncodeToString(digest[:]), nil
}

// advance witnesses stage for the acknowledged Nakama snapshot, conditional on
// the previously witnessed record. A registration replaces the registration
// fields with the snapshot's complete issued set; a drain keeps them and adds
// its pin. Each pin is the digest of the stage's originating Nakama
// acknowledgement. Only an acknowledged write moves the retained record.
func (w *generationWitness) advance(ctx context.Context, stage string, snapshot *allocatoradmission.Snapshot) error {
	binding := snapshot.Observation().Journal.Binding
	pin, err := witnessPin(stage, allocatoradmission.Collection, w.key, binding.Version, binding.IssuedCount, binding.IssuedDigest)
	if err != nil {
		return err
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
	pin, err := witnessPin(WitnessHandoff, allocatoradmission.HandoffCollection, allocatoradmission.HandoffKey(binding.GenerationID),
		binding.Version, binding.IssuedCount, binding.IssuedDigest, version)
	if err != nil {
		return err
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
