package custodywitness

import (
	"encoding/json"
	"unicode/utf8"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
)

// GenerationStage is the furthest allocator-generation step the witness has
// acknowledged (#1444). The generation family is separate from the zone
// lifetime family: it has its own key namespace, ledger and goldens.
type GenerationStage string

// The six stages, in the only order a generation record may move through them.
const (
	GenerationRegistered GenerationStage = "registered"
	GenerationDrained    GenerationStage = "drained"
	GenerationHandoff    GenerationStage = "handoff"
	GenerationOwner      GenerationStage = "owner"
	GenerationRecovered  GenerationStage = "recovered"
	GenerationPublished  GenerationStage = "published"
)

// MaximumGrantCount matches the admission journal's bound on issued grants.
const MaximumGrantCount = 256

// rank orders the stages; an unknown stage has no rank.
func (s GenerationStage) rank() int {
	switch s {
	case GenerationRegistered:
		return 1
	case GenerationDrained:
		return 2
	case GenerationHandoff:
		return 3
	case GenerationOwner:
		return 4
	case GenerationRecovered:
		return 5
	case GenerationPublished:
		return 6
	default:
		return 0
	}
}

// GenerationRecord is one allocator generation's witness state.
// GrantCount and IssuedDigest are the admission journal's issued-grant count
// and complete issued-grant set digest at the latest registration.
// RegistrationPin is the digest of that registration's originating
// acknowledgement pins. Each later pin is the digest of its stage's
// originating acknowledgement pins, present exactly when the stage is reached.
type GenerationRecord struct {
	GenerationKey   string
	Stage           GenerationStage
	GrantCount      int
	IssuedDigest    string
	RegistrationPin string
	DrainPin        string
	HandoffPin      string
	OwnerPin        string
	RecoveredPin    string
	PublishedPin    string
}

// laterPins lists the stage pins after registration, in stage order.
func (r GenerationRecord) laterPins() []string {
	return []string{r.DrainPin, r.HandoffPin, r.OwnerPin, r.RecoveredPin, r.PublishedPin}
}

// Valid reports whether every field matches its grammar and exactly the pins
// of the reached stages are present.
func (r GenerationRecord) Valid() bool {
	rank := r.Stage.rank()
	if rank == 0 || r.GrantCount < 0 || r.GrantCount > MaximumGrantCount ||
		!handoffidentity.SHA256Hex(r.GenerationKey) || !handoffidentity.SHA256Hex(r.IssuedDigest) ||
		!handoffidentity.SHA256Hex(r.RegistrationPin) {
		return false
	}
	for index, pin := range r.laterPins() {
		if !pinMatchesStage(pin, rank >= index+2) {
			return false
		}
	}
	return true
}

// Opens reports whether r is a valid first record: the generation root
// registered before any grant was issued.
func (r GenerationRecord) Opens() bool {
	return r.Valid() && r.Stage == GenerationRegistered && r.GrantCount == 0
}

// Follows reports whether r is the single forward step after previous. A
// registered record follows another only by registering exactly one more
// grant with a new registration pin and issued-grant set digest. Every other
// step moves exactly one stage forward and keeps the count, the set digest and
// every earlier pin unchanged. No operation moves a record backwards, skips a
// stage, repeats one or rewrites an earlier pin.
func (r GenerationRecord) Follows(previous GenerationRecord) bool {
	if !r.Valid() || !previous.Valid() || r.GenerationKey != previous.GenerationKey {
		return false
	}
	if r.Stage == GenerationRegistered && previous.Stage == GenerationRegistered {
		return r.GrantCount == previous.GrantCount+1 && r.IssuedDigest != previous.IssuedDigest &&
			r.RegistrationPin != previous.RegistrationPin
	}
	if r.Stage.rank() != previous.Stage.rank()+1 || r.GrantCount != previous.GrantCount ||
		r.IssuedDigest != previous.IssuedDigest || r.RegistrationPin != previous.RegistrationPin {
		return false
	}
	// The new stage's pin is checked by Valid; every earlier pin must match.
	earlier, kept := previous.laterPins(), r.laterPins()
	for index := 0; index < previous.Stage.rank()-1; index++ {
		if kept[index] != earlier[index] {
			return false
		}
	}
	return true
}

// generationMembers names the document members of each stage, in canonical
// order; each stage extends the previous one by its own pin.
var generationMembers = []string{
	"schema", "generation_key", "stage", "grant_count", "issued_digest", "registration_pin",
	"drain_pin", "handoff_pin", "owner_pin", "recovered_pin", "published_pin",
}

// registeredMemberCount is the number of members a registered document holds.
const registeredMemberCount = 6

// generationDocument is the canonical member order. A valid record carries
// exactly the pins of its reached stages, so omitting empty pins emits exactly
// the members of its own stage; the grant count is always present.
type generationDocument struct {
	Schema          int             `json:"schema"`
	GenerationKey   string          `json:"generation_key"`
	Stage           GenerationStage `json:"stage"`
	GrantCount      int             `json:"grant_count"`
	IssuedDigest    string          `json:"issued_digest"`
	RegistrationPin string          `json:"registration_pin"`
	DrainPin        string          `json:"drain_pin,omitempty"`
	HandoffPin      string          `json:"handoff_pin,omitempty"`
	OwnerPin        string          `json:"owner_pin,omitempty"`
	RecoveredPin    string          `json:"recovered_pin,omitempty"`
	PublishedPin    string          `json:"published_pin,omitempty"`
}

// EncodeGenerationRecord emits the one canonical schema-1 document for a valid
// generation record.
func EncodeGenerationRecord(r GenerationRecord) (string, error) {
	if !r.Valid() {
		return "", ErrUnknown
	}
	raw, err := json.Marshal(generationDocument{
		1, r.GenerationKey, r.Stage, r.GrantCount, r.IssuedDigest, r.RegistrationPin,
		r.DrainPin, r.HandoffPin, r.OwnerPin, r.RecoveredPin, r.PublishedPin,
	})
	if err != nil {
		return "", ErrUnknown
	}
	return string(raw), nil
}

// DecodeGenerationRecord is the permanent strict schema-1 reader for the
// generation family. A document must carry exactly the fields of its own
// stage: missing, duplicate, null, unknown and trailing content, a pin for an
// unreached stage, a stage that disagrees with its fields and a grant count
// outside the journal's bound are all refused.
func DecodeGenerationRecord(value string) (GenerationRecord, error) {
	if len(value) > maximumDocumentBytes || !utf8.ValidString(value) {
		return GenerationRecord{}, ErrUnknown
	}
	for _, want := range []GenerationStage{
		GenerationRegistered, GenerationDrained, GenerationHandoff,
		GenerationOwner, GenerationRecovered, GenerationPublished,
	} {
		var schema int
		var got GenerationRecord
		targets := []any{
			&schema, &got.GenerationKey, &got.Stage, &got.GrantCount, &got.IssuedDigest, &got.RegistrationPin,
			&got.DrainPin, &got.HandoffPin, &got.OwnerPin, &got.RecoveredPin, &got.PublishedPin,
		}
		fields := make(map[string]any)
		for index := 0; index < registeredMemberCount+want.rank()-1; index++ {
			fields[generationMembers[index]] = targets[index]
		}
		if nakamastorage.DecodeRequiredObject(value, fields) != nil {
			continue
		}
		if schema != 1 || got.Stage != want || !got.Valid() {
			return GenerationRecord{}, ErrUnknown
		}
		return got, nil
	}
	return GenerationRecord{}, ErrUnknown
}
