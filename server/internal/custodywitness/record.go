// Package custodywitness defines the forward-only record an independent
// custody witness keeps for each original zone lifetime (#1341, #1442).
//
// This package holds only the persisted record contract: its strict schema-1
// reader, its encoder and the forward-only transition rule. It performs no I/O,
// creates no client and grants no launch, claim or completion authority. Nothing
// in the zone command or the serving plugin imports it.
package custodywitness

import (
	"encoding/json"
	"errors"
	"unicode/utf8"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
)

// ErrUnknown reports a record that cannot be read as exactly one complete,
// valid schema-1 witness record. It never means "no record exists".
var ErrUnknown = errors.New("custody witness: record unavailable")

// Stage is the furthest custody step the witness has acknowledged.
type Stage string

// The three stages, in the only order a record may move through them.
const (
	StageEnrolled  Stage = "enrolled"
	StageCustody   Stage = "custody"
	StageTombstone Stage = "tombstone"
)

// rank orders the stages; an unknown stage has no rank.
func (s Stage) rank() int {
	switch s {
	case StageEnrolled:
		return 1
	case StageCustody:
		return 2
	case StageTombstone:
		return 3
	default:
		return 0
	}
}

// Record is one lifetime's witness state. LifetimeKey is the unchanged ADR 0044
// lifetime key. Each pin is the digest of that stage's originating
// acknowledgement pins; a pin is present exactly when its stage has been
// reached, so an enrolled record carries no custody or tombstone pin.
type Record struct {
	LifetimeKey   string
	Stage         Stage
	EnrollmentPin string
	CustodyPin    string
	TombstonePin  string
}

// Valid reports whether every field matches its grammar and exactly the pins
// of the reached stages are present.
func (r Record) Valid() bool {
	rank := r.Stage.rank()
	if rank == 0 || !handoffidentity.SHA256Hex(r.LifetimeKey) || !handoffidentity.SHA256Hex(r.EnrollmentPin) {
		return false
	}
	return pinMatchesStage(r.CustodyPin, rank >= 2) && pinMatchesStage(r.TombstonePin, rank >= 3)
}

// pinMatchesStage requires a well-formed pin when reached and none otherwise.
func pinMatchesStage(pin string, reached bool) bool {
	if reached {
		return handoffidentity.SHA256Hex(pin)
	}
	return pin == ""
}

// Follows reports whether r is the single forward step after previous: the
// same lifetime, exactly the next stage and every earlier pin unchanged. No
// operation moves a record backwards, skips a stage, repeats one or rewrites
// an earlier pin.
func (r Record) Follows(previous Record) bool {
	if !r.Valid() || !previous.Valid() || r.LifetimeKey != previous.LifetimeKey || r.Stage.rank() != previous.Stage.rank()+1 || r.EnrollmentPin != previous.EnrollmentPin {
		return false
	}
	return r.Stage != StageTombstone || r.CustodyPin == previous.CustodyPin
}

// EncodeRecord emits the one canonical schema-1 document for a valid record.
func EncodeRecord(r Record) (string, error) {
	if !r.Valid() {
		return "", ErrUnknown
	}
	// Each later stage's document extends the previous one, so the members of
	// a reached stage always appear in the same order.
	enrolled := enrolledDocument{1, r.LifetimeKey, r.Stage, r.EnrollmentPin}
	custody := custodyDocument{enrolled, r.CustodyPin}
	var document any = enrolled
	if rank := r.Stage.rank(); rank == 3 {
		document = tombstoneDocument{custody, r.TombstonePin}
	} else if rank == 2 {
		document = custody
	}
	raw, err := json.Marshal(document)
	if err != nil {
		return "", ErrUnknown
	}
	return string(raw), nil
}

type enrolledDocument struct {
	Schema        int    `json:"schema"`
	LifetimeKey   string `json:"lifetime_key"`
	Stage         Stage  `json:"stage"`
	EnrollmentPin string `json:"enrollment_pin"`
}

type custodyDocument struct {
	enrolledDocument
	CustodyPin string `json:"custody_pin"`
}

type tombstoneDocument struct {
	custodyDocument
	TombstonePin string `json:"tombstone_pin"`
}

// maximumDocumentBytes bounds a read well above the largest valid document.
const maximumDocumentBytes = 1024

// DecodeRecord is the permanent strict schema-1 reader. A document must carry
// exactly the fields of its own stage: missing, duplicate, null, unknown and
// trailing content, a pin for an unreached stage and a stage that disagrees
// with its fields are all refused.
func DecodeRecord(value string) (Record, error) {
	if len(value) > maximumDocumentBytes || !utf8.ValidString(value) {
		return Record{}, ErrUnknown
	}
	for _, want := range []Stage{StageEnrolled, StageCustody, StageTombstone} {
		var schema int
		var got Record
		fields := map[string]any{"schema": &schema, "lifetime_key": &got.LifetimeKey, "stage": &got.Stage, "enrollment_pin": &got.EnrollmentPin}
		if want.rank() >= 2 {
			fields["custody_pin"] = &got.CustodyPin
		}
		if want.rank() >= 3 {
			fields["tombstone_pin"] = &got.TombstonePin
		}
		if nakamastorage.DecodeRequiredObject(value, fields) != nil {
			continue
		}
		if schema != 1 || got.Stage != want || !got.Valid() {
			return Record{}, ErrUnknown
		}
		return got, nil
	}
	return Record{}, ErrUnknown
}
