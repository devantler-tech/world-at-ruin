// Package nakamastorage holds the primitives every Nakama-backed store in this
// server is built on: the slice of the runtime storage surface a store reads
// and writes through, the owner private records are stored under, canonical
// JSON encoding of documents, subject-identity validation, strict object
// decoding, and the sanitising of storage errors so a caller learns about its
// own cancellation and nothing about the store. Each store keeps its own
// schema and policy and calls through to here, so there is ONE implementation
// of each primitive to fix (#780).
package nakamastorage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// SystemOwnerID is the owner Nakama reports for a record written with an
// empty user id. Private, server-authoritative records live under it so a
// player cannot pre-create or overwrite them from the client-writable
// namespace.
const SystemOwnerID = "00000000-0000-0000-0000-000000000000"

// Client is the slice of Nakama's runtime storage surface a store depends on.
// Nakama's runtime module satisfies it, and so does a test fake.
type Client interface {
	StorageRead(
		context.Context,
		[]*runtime.StorageRead,
	) ([]*api.StorageObject, error)
	StorageWrite(
		context.Context,
		[]*runtime.StorageWrite,
	) ([]*api.StorageObjectAck, error)
}

// CanonicalObject re-encodes exactly one JSON object into Go's canonical form —
// sorted keys, no insignificant whitespace, numbers kept as written — so that
// byte equality means value equality. A scalar, an array, `null`, or trailing
// content after the object is refused.
func CanonicalObject(raw json.RawMessage) (json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var object map[string]any
	if err := decoder.Decode(&object); err != nil || object == nil {
		return nil, errors.New("invalid JSON object")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, errors.New("trailing JSON content")
	}
	encoded, err := json.Marshal(object)
	if err != nil {
		return nil, err
	}
	return encoded, nil
}

// ValidSubjectID reports whether subjectID is a hyphenated UUID, in either
// case, that is not the system owner.
func ValidSubjectID(subjectID string) bool {
	if len(subjectID) != 36 || subjectID == SystemOwnerID {
		return false
	}
	for index, char := range subjectID {
		switch index {
		case 8, 13, 18, 23:
			if char != '-' {
				return false
			}
		default:
			if !isHexDigit(char) {
				return false
			}
		}
	}
	return true
}

func isHexDigit(char rune) bool {
	return (char >= '0' && char <= '9') ||
		(char >= 'a' && char <= 'f') ||
		(char >= 'A' && char <= 'F')
}

// InvalidIdentityPart reports whether value cannot take part in a stored
// identity: blank once trimmed, or carrying a NUL byte.
func InvalidIdentityPart(value string) bool {
	return strings.TrimSpace(value) == "" || strings.ContainsRune(value, '\x00')
}

// ContextError returns the caller's own cancellation or deadline when err or
// ctx carries one, and nil otherwise.
func ContextError(ctx context.Context, err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, context.DeadlineExceeded):
		return context.DeadlineExceeded
	case ctx.Err() != nil:
		return ctx.Err()
	default:
		return nil
	}
}

// SanitizeError returns the caller's own cancellation or deadline when there
// is one, and fallback otherwise, so a failed storage operation never carries
// the underlying Nakama error — or the durable state it describes — to a
// client.
func SanitizeError(ctx context.Context, err error, fallback error) error {
	if cancellation := ContextError(ctx, err); cancellation != nil {
		return cancellation
	}
	return fallback
}

// BeginObject returns a number-preserving decoder positioned just inside the
// opening brace of value, or an error when value does not begin an object. A
// store walks the members itself so it can refuse duplicates and unknown
// names, then closes with EndObject.
func BeginObject(value string) (*json.Decoder, error) {
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	start, err := decoder.Token()
	if err != nil || start != json.Delim('{') {
		return nil, errors.New("invalid JSON object")
	}
	return decoder, nil
}

// EndObject consumes the closing brace of the object BeginObject opened and
// refuses any content after it.
func EndObject(decoder *json.Decoder) error {
	end, err := decoder.Token()
	if err != nil || end != json.Delim('}') {
		return errors.New("invalid JSON object")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("trailing JSON content")
	}
	return nil
}
