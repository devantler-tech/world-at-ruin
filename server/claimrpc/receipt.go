package claimrpc

import (
	"encoding/json"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
	"io"
	"strconv"
	"time"
)

// Generation is a canonical decimal string so intermediaries cannot round an
// exact nanosecond fence through floating-point JSON numbers.
type receiptJSON struct {
	Schema        int          `json:"schema"`
	Namespace     string       `json:"namespace"`
	LeaseObjectID string       `json:"lease_object_id"`
	LeaseVersion  string       `json:"lease_version"`
	AttemptDigest string       `json:"attempt_digest"`
	AllocationID  string       `json:"allocation_id"`
	GameServerUID string       `json:"gameserver_uid"`
	Observer      sim.EntityID `json:"observer"`
	Generation    string       `json:"generation_nanos"`
}

// decodeReceipt accepts exactly one complete receipt; partial results never
// escape a refusal, and all identity fields must match the original request.
func decodeReceipt(reader io.Reader) (zoneclaim.Receipt, error) {
	var document receiptJSON
	fields := map[string]any{"schema": &document.Schema, "namespace": &document.Namespace, "lease_object_id": &document.LeaseObjectID, "lease_version": &document.LeaseVersion, "attempt_digest": &document.AttemptDigest, "allocation_id": &document.AllocationID, "gameserver_uid": &document.GameServerUID, "observer": &document.Observer, "generation_nanos": &document.Generation}
	decoder := json.NewDecoder(reader)
	start, err := decoder.Token()
	if err != nil || start != json.Delim('{') {
		return zoneclaim.Receipt{}, ErrRefused
	}
	for decoder.More() {
		token, err := decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok {
			return zoneclaim.Receipt{}, ErrRefused
		}
		target, ok := fields[key]
		var raw json.RawMessage
		if !ok || decoder.Decode(&raw) != nil || string(raw) == "null" || json.Unmarshal(raw, target) != nil {
			return zoneclaim.Receipt{}, ErrRefused
		}
		delete(fields, key)
	}
	end, err := decoder.Token()
	if err != nil || end != json.Delim('}') || len(fields) != 0 {
		return zoneclaim.Receipt{}, ErrRefused
	}
	if _, err := decoder.Token(); err != io.EOF {
		return zoneclaim.Receipt{}, ErrRefused
	}
	nanos, err := strconv.ParseInt(document.Generation, 10, 64)
	if err != nil || nanos <= 0 || strconv.FormatInt(nanos, 10) != document.Generation || document.Schema != 1 {
		return zoneclaim.Receipt{}, ErrRefused
	}
	r := zoneclaim.Receipt{Namespace: document.Namespace, Observer: document.Observer, Fence: nakamalease.SessionFence{LeaseObjectID: document.LeaseObjectID, LeaseVersion: document.LeaseVersion, AttemptDigest: document.AttemptDigest, AllocationID: document.AllocationID, GameServerUID: document.GameServerUID, Generation: time.Unix(0, nanos).UTC()}}
	b := agones.ClaimBinding{Namespace: r.Namespace, LeaseObjectID: r.Fence.LeaseObjectID, AttemptDigest: r.Fence.AttemptDigest, AllocationID: r.Fence.AllocationID, GameServerUID: r.Fence.GameServerUID}
	if !validRequest(claimRequest{Namespace: b.Namespace, LeaseObjectID: b.LeaseObjectID, AttemptDigest: b.AttemptDigest, AllocationID: b.AllocationID, GameServerUID: b.GameServerUID, Observer: r.Observer, Token: "receipt-shape"}) || !r.Matches(b, r.Observer) {
		return zoneclaim.Receipt{}, ErrRefused
	}
	return r, nil
}

// receiptDocument projects the original fence into the non-secret wire shape
// without refreshing ownership or losing generation precision.
func receiptDocument(r zoneclaim.Receipt) receiptJSON {
	return receiptJSON{Schema: 1, Namespace: r.Namespace, LeaseObjectID: r.Fence.LeaseObjectID, LeaseVersion: r.Fence.LeaseVersion, AttemptDigest: r.Fence.AttemptDigest, AllocationID: r.Fence.AllocationID, GameServerUID: r.Fence.GameServerUID, Observer: r.Observer, Generation: strconv.FormatInt(r.Fence.Generation.UnixNano(), 10)}
}
