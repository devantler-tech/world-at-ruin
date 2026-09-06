package nakamageneration

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"slices"
	"strconv"
	"unicode"
	"unicode/utf8"

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
	if len(value) == 0 || len(value) > maxBytes || !utf8.ValidString(value) {
		return false
	}
	for _, char := range value {
		if unicode.IsControl(char) || unicode.IsSpace(char) {
			return false
		}
	}
	return true
}

// decodeDocument accepts exactly the shipped schema and refuses ambiguous JSON.
// Persisted membership must already be canonical and match its recorded digest.
func decodeDocument(value string) (document, error) {
	if len(value) > maxDocumentBytes || !validJSONUnicode(value) {
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
	if nakamastorage.EndObject(decoder) != nil || len(seen) != 5 || got.Schema != 1 || got.State != "open" {
		return document{}, ErrStorage
	}
	want, err := openDocument(got.GenerationID, got.MemberPodUIDs)
	if err != nil || !slices.Equal(want.MemberPodUIDs, got.MemberPodUIDs) || got.MemberSetDigest != want.MemberSetDigest {
		return document{}, ErrStorage
	}
	return got, nil
}

// validJSONUnicode rejects the lossy replacements encoding/json otherwise makes
// for malformed UTF-8 and unpaired UTF-16 escapes. The decoder checks JSON syntax.
func validJSONUnicode(value string) bool {
	if !utf8.ValidString(value) {
		return false
	}
	for index := 0; index < len(value); index++ {
		if value[index] != '\\' {
			continue
		}
		index++
		if index >= len(value) {
			return false
		}
		if value[index] != 'u' {
			continue // An escaped backslash cannot introduce a Unicode escape.
		}
		if index+5 > len(value) {
			return false
		}
		unit, err := strconv.ParseUint(value[index+1:index+5], 16, 16)
		if err != nil {
			return false
		}
		index += 4
		switch {
		case unit >= 0xdc00 && unit <= 0xdfff:
			return false
		case unit >= 0xd800 && unit <= 0xdbff:
			if index+7 > len(value) || value[index+1:index+3] != `\u` {
				return false
			}
			low, err := strconv.ParseUint(value[index+3:index+7], 16, 16)
			if err != nil || low < 0xdc00 || low > 0xdfff {
				return false
			}
			index += 6
		}
	}
	return true
}

// record returns the exact storage version with an independently owned member set.
func (d document) record(version string) Record {
	return Record{
		GenerationID: d.GenerationID, MemberPodUIDs: slices.Clone(d.MemberPodUIDs),
		MemberSetDigest: d.MemberSetDigest, State: d.State, Version: version,
	}
}
