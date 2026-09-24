package claimrpc

import (
	"encoding/hex"
	"encoding/json"
	"io"
	"strings"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/sim"
)

type claimRequest struct {
	Namespace     string       `json:"namespace"`
	AllocationID  string       `json:"allocation_id"`
	GameServerUID string       `json:"gameserver_uid"`
	LeaseObjectID string       `json:"lease_object_id"`
	AttemptDigest string       `json:"attempt_digest"`
	Token         string       `json:"token"`
	Observer      sim.EntityID `json:"observer"`
}

// decodeRequest accepts one bounded object with exact field spellings; aliases,
// duplicate keys and trailing values cannot alter the identity being verified.
func decodeRequest(reader io.Reader) (claimRequest, error) {
	var request claimRequest
	decoder := json.NewDecoder(reader)
	start, err := decoder.Token()
	if err != nil || start != json.Delim('{') {
		return request, ErrRefused
	}
	fields := map[string]any{
		"namespace":       &request.Namespace,
		"allocation_id":   &request.AllocationID,
		"gameserver_uid":  &request.GameServerUID,
		"lease_object_id": &request.LeaseObjectID,
		"attempt_digest":  &request.AttemptDigest,
		"token":           &request.Token,
		"observer":        &request.Observer,
	}
	for decoder.More() {
		token, err := decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok {
			return request, ErrRefused
		}
		target, ok := fields[key]
		if !ok || decoder.Decode(target) != nil {
			return request, ErrRefused
		}
		delete(fields, key)
	}
	end, err := decoder.Token()
	if err != nil || end != json.Delim('}') || len(fields) != 0 {
		return request, ErrRefused
	}
	if _, err := decoder.Token(); err != io.EOF || !validRequest(request) {
		return request, ErrRefused
	}
	return request, nil
}

// validRequest rejects malformed routing and identity material before resource
// lookup; valid syntax never establishes authority to claim an allocation.
func validRequest(request claimRequest) bool {
	key, err := hex.DecodeString(request.LeaseObjectID)
	return err == nil && len(key) == 32 && strings.ToLower(request.LeaseObjectID) == request.LeaseObjectID &&
		handoffidentity.DNSLabel(request.Namespace) && handoffidentity.CorrelationID(request.AllocationID) &&
		handoffidentity.GameServerUID(request.GameServerUID) && request.GameServerUID != "." && request.GameServerUID != ".." &&
		handoffidentity.Fingerprint(request.AttemptDigest) && request.Observer != 0 && len(request.Token) > 0 && len(request.Token) <= 256
}
