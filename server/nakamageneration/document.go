package nakamageneration

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"slices"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
)

const (
	maxIdentityBytes = 128
	maxMembers       = 256
	maxDocumentBytes = 65536
	membershipDomain = "world-at-ruin/allocator-generation-members/v1\n"
)

type document struct {
	Schema          int      `json:"schema"`
	GenerationID    string   `json:"generation_id"`
	MemberPodUIDs   []string `json:"member_pod_uids"`
	MemberSetDigest string   `json:"member_set_digest"`
	State           string   `json:"state"`
}

// openDocument canonicalizes a bounded set without modifying the caller's slice.
func openDocument(generationID string, members []string) (document, error) {
	if !validIdentity(generationID, maxIdentityBytes) || len(members) == 0 || len(members) > maxMembers {
		return document{}, ErrInvalidArgument
	}
	canonical := slices.Clone(members)
	slices.Sort(canonical)
	for index, member := range canonical {
		if !validIdentity(member, maxIdentityBytes) || (index > 0 && member == canonical[index-1]) {
			return document{}, ErrInvalidArgument
		}
	}
	// JSON encodes length and string boundaries unambiguously, including opaque
	// punctuation. The domain pins this digest's meaning independently of keys.
	encoded, err := json.Marshal(canonical)
	if err != nil {
		return document{}, ErrInvalidArgument
	}
	digest := sha256.Sum256(append([]byte(membershipDomain), encoded...))
	return document{
		Schema: 1, GenerationID: generationID, MemberPodUIDs: canonical,
		MemberSetDigest: hex.EncodeToString(digest[:]), State: "open",
	}, nil
}

// validIdentity preserves opaque UTF-8 spelling within the documented bounds.
func validIdentity(value string, maxBytes int) bool {
	return handoffidentity.OpaqueUTF8(value, maxBytes)
}

// decodeDocument accepts every readable schema and refuses ambiguous JSON.
// Persisted membership must already be canonical and match its recorded digest.
func decodeDocument(value string) (document, error) {
	if len(value) > maxDocumentBytes || !nakamastorage.ValidJSONUnicode(value) {
		return document{}, ErrStorage
	}
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return document{}, ErrStorage
	}
	var got document
	seen := make(map[string]bool)
	for decoder.More() {
		name, tokenErr := decoder.Token()
		if tokenErr != nil {
			return document{}, ErrStorage
		}
		field, ok := name.(string)
		if !ok || seen[field] {
			return document{}, ErrStorage
		}
		seen[field] = true
		var target any
		switch field {
		case "schema":
			target = &got.Schema
		case "generation_id":
			target = &got.GenerationID
		case "member_pod_uids":
			target = &got.MemberPodUIDs
		case "member_set_digest":
			target = &got.MemberSetDigest
		case "state":
			target = &got.State
		default:
			return document{}, ErrStorage
		}
		if err := decoder.Decode(target); err != nil {
			return document{}, ErrStorage
		}
	}
	if nakamastorage.EndObject(decoder) != nil || len(seen) != 5 ||
		(got.Schema != 1 && got.Schema != 2) ||
		(got.State != "open" && (got.Schema != 2 || got.State != "draining")) {
		return document{}, ErrStorage
	}
	want, err := openDocument(got.GenerationID, got.MemberPodUIDs)
	if err != nil || !slices.Equal(want.MemberPodUIDs, got.MemberPodUIDs) || got.MemberSetDigest != want.MemberSetDigest {
		return document{}, ErrStorage
	}
	return got, nil
}

// record returns the exact storage version with an independently owned member set.
func (d document) record(version string) Record {
	return Record{
		GenerationID: d.GenerationID, MemberPodUIDs: slices.Clone(d.MemberPodUIDs),
		MemberSetDigest: d.MemberSetDigest, State: d.State, Version: version,
		readerOnly: d.Schema != 1,
	}
}
