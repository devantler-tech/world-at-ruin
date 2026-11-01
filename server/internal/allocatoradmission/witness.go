package allocatoradmission

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
)

// The generation witness stages written so far. They are the custody witness
// generation family's stage names (#1444); later stages belong to later slices.
const (
	WitnessRegistered = "registered"
	WitnessDrained    = "drained"
	WitnessHandoff    = "handoff"
	WitnessOwner      = "owner"
)

// WitnessRecord is one allocator generation's witness record, field for field
// the custody witness generation record up to the stages written so far. It is
// declared here so admission and the commit authority, which the native trial
// command composes, never import the witness client: that composition is a
// separate delivery, and the normal and trial artifacts are guarded against
// composing the witness.
type WitnessRecord struct {
	GenerationKey   string
	Stage           string
	GrantCount      int
	IssuedDigest    string
	RegistrationPin string
	DrainPin        string
	HandoffPin      string
	OwnerPin        string
}

// GenerationWitness moves the witness record from previous to next in one
// conditional write. It returns nil only when this call's own write is known
// to be stored; a lost reply is settled by one strongly consistent exact
// re-read (custody witness WriteGeneration), so any error means the stage is
// not witnessed.
type GenerationWitness interface {
	WriteGeneration(ctx context.Context, previous, next WitnessRecord) error
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

// WitnessStagePin is the pin of a registration or drain: the digest of the
// journal acknowledgement that carries the binding.
func WitnessStagePin(stage string, binding allocatorjournal.JournalBinding) (string, error) {
	return witnessPin(stage, Collection, Key(binding.GenerationID), binding.Version, binding.IssuedCount, binding.IssuedDigest)
}

// WitnessHandoffPin is the pin of a recovery handoff: the digest of the handoff
// create's acknowledgement, which is the document's key, the drained binding it
// carries and the version Nakama acknowledged.
func WitnessHandoffPin(binding allocatorjournal.JournalBinding, version string) (string, error) {
	return witnessPin(WitnessHandoff, HandoffCollection, HandoffKey(binding.GenerationID),
		binding.Version, binding.IssuedCount, binding.IssuedDigest, version)
}

// witnessOwnerPin is the pin of a recovery owner: the digest of the owner
// create's acknowledgement, which is the row's key, the owner and handoff the
// row holds, and the version Nakama acknowledged.
func witnessOwnerPin(cfg RecoveryOwnerConfig, version string) (string, error) {
	b := cfg.Binding
	return witnessPin(WitnessOwner, RecoveryOwnerCollection, RecoveryOwnerKey(b.GenerationID), cfg.OwnerID,
		b.Version, b.IssuedCount, b.IssuedDigest, cfg.HandoffVersion, version)
}

// RecoveryOwnerWitnessConfig opts a recoverer into persist-before-ACK
// witnessing of its owner row. Handoff is the independently retained witnessed
// `handoff` record, kept next to the handoff pins and advanced conditionally.
// Its zero value composes no witness; anything else must be complete.
//
// Recoverers need distinct owner IDs. Two sharing one write the same owner
// record, so a lost reply's exact re-read cannot tell the two writes apart.
type RecoveryOwnerWitnessConfig struct {
	Enabled bool
	Witness GenerationWitness
	Handoff WitnessRecord
}

// valid reports a zero value, or a witness with the exact witnessed handoff of
// this binding and handoff version. The drain and handoff pins bind the journal
// and handoff acknowledgements, so only those exact acknowledgements re-derive
// them; the registration pin's binding is no longer known here.
func (c RecoveryOwnerWitnessConfig) valid(binding allocatorjournal.JournalBinding, version string) bool {
	if !c.Enabled {
		return isNil(c.Witness) && c.Handoff == (WitnessRecord{})
	}
	h := c.Handoff
	if isNil(c.Witness) || h.Stage != WitnessHandoff || h.OwnerPin != "" || h.RegistrationPin == "" ||
		h.GenerationKey != Key(binding.GenerationID) || h.GrantCount != binding.IssuedCount || h.IssuedDigest != binding.IssuedDigest {
		return false
	}
	drain, err := WitnessStagePin(WitnessDrained, binding)
	if err != nil || drain != h.DrainPin {
		return false
	}
	handoff, err := WitnessHandoffPin(binding, version)
	return err == nil && handoff == h.HandoffPin
}
