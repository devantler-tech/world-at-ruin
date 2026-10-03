package nakamamastery

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
)

// ErrDisabled reports the default-off, uncomposed feature boundary.
var ErrDisabled = errors.New("mastery: experimental owner disabled")

// Config explicitly opts an internal caller into the inert owner. SourceUID
// and SourceIncarnation identify the ORIGINAL producing runtime, retained on
// every retry and restart. They do not authenticate an external event.
type Config struct {
	Enabled           bool
	SourceUID         string
	SourceIncarnation string
}

type authorityState struct {
	sourceUID   string
	incarnation string
}

// Authority seals process-local events. Copies retain the same private seal.
// No RPC, network listener, or production combat adapter exposes this handle.
type Authority struct{ state *authorityState }

// Event is an immutable, process-local handle, never decoded from a request.
type Event struct {
	owner    *authorityState
	subject  string
	identity string
	payload  eventPayload
	binding  json.RawMessage
}

// NewAuthority constructs a default-off internal boundary. Enabling it is
// not production event authentication or approval to compose a live writer.
func NewAuthority(config Config) (Authority, error) {
	if !config.Enabled {
		return Authority{}, nil
	}
	if !validID(config.SourceUID) || !validID(config.SourceIncarnation) {
		return Authority{}, ErrInvalid
	}
	return Authority{state: &authorityState{sourceUID: config.SourceUID, incarnation: config.SourceIncarnation}}, nil
}

// Award seals a positive exact integer award for a server-owned source event.
func (a Authority) Award(subject, eventID, weapon string, amount int64) (Event, error) {
	if !validID(weapon) || amount <= 0 || amount > maxExact {
		return Event{}, ErrInvalid
	}
	return a.seal(subject, eventID, eventPayload{Kind: "award", Weapon: weapon, Amount: amount})
}

// Death seals an explicitly supplied policy percentage, refusing invalid policy.
func (a Authority) Death(subject, eventID string, percent int) (Event, error) {
	if percent < 0 || percent > 100 {
		return Event{}, ErrInvalid
	}
	return a.seal(subject, eventID, eventPayload{Kind: "death", Percent: percent})
}

// Reclaim seals the exact standing stain identity observed by the caller.
func (a Authority) Reclaim(subject, eventID, stainID string) (Event, error) {
	if !validID(stainID) {
		return Event{}, ErrInvalid
	}
	return a.seal(subject, eventID, eventPayload{Kind: "reclaim", StainID: stainID})
}

func (a Authority) seal(subject, eventID string, payload eventPayload) (Event, error) {
	if a.state == nil {
		return Event{}, ErrDisabled
	}
	subject = strings.ToLower(subject)
	if !nakamastorage.ValidSubjectID(subject) || !validID(eventID) {
		return Event{}, ErrInvalid
	}
	// JSON length framing makes the original-source tuple unambiguous. Operation
	// and payload deliberately stay outside this key: changed reuse must conflict.
	original, _ := json.Marshal([]string{"war-mastery-event-v1", a.state.sourceUID, a.state.incarnation, eventID})
	hash := sha256.Sum256(original)
	binding, err := json.Marshal(struct {
		SourceUID         string       `json:"source_uid"`
		SourceIncarnation string       `json:"source_incarnation"`
		EventID           string       `json:"event_id"`
		Subject           string       `json:"subject"`
		Event             eventPayload `json:"event"`
	}{a.state.sourceUID, a.state.incarnation, eventID, subject, payload})
	if err != nil {
		return Event{}, ErrInvalid
	}
	return Event{owner: a.state, subject: subject, identity: hex.EncodeToString(hash[:]), payload: payload, binding: binding}, nil
}
