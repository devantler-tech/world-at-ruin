package zonecustody

import (
	"encoding/json"
	"unicode/utf8"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
)

// Lifetime is the complete original allocation route, independent of all
// supervisor and child correlations and process-local watch revisions.
type Lifetime struct {
	Namespace     string `json:"namespace"`
	LeaseObjectID string `json:"lease_object_id"`
	AttemptDigest string `json:"attempt_digest"`
	AllocationID  string `json:"allocation_id"`
	GameServerUID string `json:"game_server_uid"`
}

// Observation is diagnostic attribution, never an authenticated principal.
type Observation struct {
	Lifetime         Lifetime `json:"lifetime"`
	OwnerID          string   `json:"owner_id"`
	ChildIncarnation string   `json:"child_incarnation"`
}

// lifetime deliberately omits the unexported watch revision.
func lifetime(b agones.ClaimBinding) Lifetime {
	return Lifetime{b.Namespace, b.LeaseObjectID, b.AttemptDigest, b.AllocationID, b.GameServerUID}
}

// binding restores only a diagnostic route, never a current watch observation.
func (l Lifetime) binding() agones.ClaimBinding {
	return agones.ClaimBinding{Namespace: l.Namespace, LeaseObjectID: l.LeaseObjectID, AttemptDigest: l.AttemptDigest, AllocationID: l.AllocationID, GameServerUID: l.GameServerUID}
}

// observation freezes constructor correlations without authentication claims.
func observation(cfg Config) Observation {
	return Observation{lifetime(cfg.Binding), cfg.OwnerID, cfg.ChildIncarnation}
}

// validObservation uses the production identity grammars, retaining spelling.
func validObservation(o Observation) bool {
	l := o.Lifetime
	return handoffidentity.DNSLabel(l.Namespace) && handoffidentity.SHA256Hex(l.LeaseObjectID) && handoffidentity.Fingerprint(l.AttemptDigest) && handoffidentity.DNSSubdomain(l.AllocationID) && handoffidentity.GameServerUID(l.GameServerUID) && handoffidentity.OpaqueUTF8(o.OwnerID, 128) && handoffidentity.OpaqueUTF8(o.ChildIncarnation, 128)
}

// EncodeEnrollment emits one immutable schema-1 diagnostic document.
func EncodeEnrollment(o Observation) (string, error) {
	if !validObservation(o) {
		return "", ErrUnknown
	}
	raw, err := json.Marshal(struct {
		Schema int `json:"schema"`
		Observation
	}{1, o})
	return string(raw), err
}

// DecodeEnrollment is the permanent strict schema-1 enrollment reader.
func DecodeEnrollment(value string) (Observation, error) {
	var schema int
	var got Observation
	var route json.RawMessage
	if decodeObject(value, map[string]any{"schema": &schema, "lifetime": &route, "owner_id": &got.OwnerID, "child_incarnation": &got.ChildIncarnation}) != nil || schema != 1 || decodeLifetime(route, &got.Lifetime) != nil || !validObservation(got) {
		return Observation{}, ErrUnknown
	}
	return got, nil
}

// EncodeCustody serializes original enrollment pins and the complete receipt.
// Its own storage ACK version is not part of the persisted value.
func EncodeCustody(p Pins) (string, error) {
	if !validObservation(p.Enrollment) || !validVersion(p.EnrollmentVersion) || !p.Receipt.Matches(p.Enrollment.Lifetime.binding(), p.Receipt.Observer) {
		return "", ErrUnknown
	}
	e, err := EncodeEnrollment(p.Enrollment)
	if err != nil {
		return "", err
	}
	raw, err := json.Marshal(struct {
		Schema     int               `json:"schema"`
		Enrollment json.RawMessage   `json:"enrollment"`
		Version    string            `json:"enrollment_version"`
		Receipt    zoneclaim.Receipt `json:"receipt"`
	}{1, json.RawMessage(e), p.EnrollmentVersion, p.Receipt})
	return string(raw), err
}

// DecodeCustody is the permanent strict original-custody reader. It returns
// diagnostics only and cannot manufacture a live originating handle.
func DecodeCustody(value string) (Pins, error) {
	var schema int
	var got Pins
	var enrollment, receipt json.RawMessage
	if decodeObject(value, map[string]any{"schema": &schema, "enrollment": &enrollment, "enrollment_version": &got.EnrollmentVersion, "receipt": &receipt}) != nil || schema != 1 || !validVersion(got.EnrollmentVersion) {
		return Pins{}, ErrUnknown
	}
	var err error
	got.Enrollment, err = DecodeEnrollment(string(enrollment))
	if err != nil {
		return Pins{}, ErrUnknown
	}
	var fence json.RawMessage
	if decodeObject(string(receipt), map[string]any{"Namespace": &got.Receipt.Namespace, "Observer": &got.Receipt.Observer, "Fence": &fence}) != nil {
		return Pins{}, ErrUnknown
	}
	f := &got.Receipt.Fence
	if decodeObject(string(fence), map[string]any{"LeaseObjectID": &f.LeaseObjectID, "LeaseVersion": &f.LeaseVersion, "AttemptDigest": &f.AttemptDigest, "AllocationID": &f.AllocationID, "GameServerUID": &f.GameServerUID, "Generation": &f.Generation}) != nil || !got.Receipt.Matches(got.Enrollment.Lifetime.binding(), got.Receipt.Observer) {
		return Pins{}, ErrUnknown
	}
	return got, nil
}

// decodeLifetime rejects missing, duplicate, null and foreign route fields.
func decodeLifetime(raw json.RawMessage, l *Lifetime) error {
	return decodeObject(string(raw), map[string]any{"namespace": &l.Namespace, "lease_object_id": &l.LeaseObjectID, "attempt_digest": &l.AttemptDigest, "allocation_id": &l.AllocationID, "game_server_uid": &l.GameServerUID})
}

// decodeObject bounds and completely consumes one strict required-field object.
func decodeObject(value string, fields map[string]any) error {
	if len(value) > 16384 || !utf8.ValidString(value) {
		return ErrUnknown
	}
	if nakamastorage.DecodeRequiredObject(value, fields) != nil {
		return ErrUnknown
	}
	return nil
}
