package nakamastorage

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func TestValidSubjectID(t *testing.T) {
	t.Parallel()
	cases := map[string]struct {
		subjectID string
		valid     bool
	}{
		"lower-case uuid":     {"11111111-1111-4111-8111-111111111111", true},
		"upper-case uuid":     {"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", true},
		"system owner":        {SystemOwnerID, false},
		"too short":           {"11111111-1111-4111-8111-11111111111", false},
		"too long":            {"11111111-1111-4111-8111-1111111111111", false},
		"hyphen out of place": {"111111111-111-4111-8111-111111111111", false},
		"non-hex character":   {"11111111-1111-4111-8111-11111111111g", false},
		"blank":               {"", false},
		"unhyphenated 36 hex": {"111111111111411181111111111111111111", false},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := ValidSubjectID(tc.subjectID); got != tc.valid {
				t.Fatalf("ValidSubjectID(%q) = %v, want %v", tc.subjectID, got, tc.valid)
			}
		})
	}
}

func TestInvalidIdentityPart(t *testing.T) {
	t.Parallel()
	cases := map[string]struct {
		value   string
		invalid bool
	}{
		"plain":       {"character", false},
		"inner space": {"save character", false},
		"blank":       {"", true},
		"whitespace":  {" \t\n", true},
		"nul byte":    {"save\x00character", true},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := InvalidIdentityPart(tc.value); got != tc.invalid {
				t.Fatalf("InvalidIdentityPart(%q) = %v, want %v", tc.value, got, tc.invalid)
			}
		})
	}
}

func TestCanonicalObjectSortsKeysAndKeepsNumbersAsWritten(t *testing.T) {
	t.Parallel()
	got, err := CanonicalObject(json.RawMessage(` { "z" : 1.50 , "a" : {"y":true,"b":[1,2]} } `))
	if err != nil {
		t.Fatalf("CanonicalObject: %v", err)
	}
	want := `{"a":{"b":[1,2],"y":true},"z":1.50}`
	if string(got) != want {
		t.Fatalf("CanonicalObject = %s, want %s", got, want)
	}
}

func TestCanonicalObjectRefusesAnythingButOneObject(t *testing.T) {
	t.Parallel()
	for name, raw := range map[string]string{
		"array":            `[1,2]`,
		"scalar":           `"object"`,
		"null":             `null`,
		"trailing content": `{"a":1} {"b":2}`,
		"trailing scalar":  `{"a":1} 2`,
		"truncated":        `{"a":`,
		"empty":            ``,
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, err := CanonicalObject(json.RawMessage(raw)); err == nil {
				t.Fatalf("CanonicalObject(%q) accepted a non-object", raw)
			}
		})
	}
}

func TestSanitizeErrorPrefersTheCallersOwnCancellation(t *testing.T) {
	t.Parallel()
	fallback := errors.New("store failed")
	live := context.Background()
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	expired, expire := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	t.Cleanup(expire)

	cases := map[string]struct {
		ctx  context.Context
		err  error
		want error
	}{
		"wrapped cancellation":       {live, errors.Join(errors.New("rpc"), context.Canceled), context.Canceled},
		"wrapped deadline":           {live, errors.Join(errors.New("rpc"), context.DeadlineExceeded), context.DeadlineExceeded},
		"context cancelled":          {cancelled, errors.New("rpc"), context.Canceled},
		"context deadline":           {expired, errors.New("rpc"), context.DeadlineExceeded},
		"storage failure stays away": {live, errors.New("nakama: table missing"), fallback},
		"nil error, live context":    {live, nil, fallback},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got := SanitizeError(tc.ctx, tc.err, fallback)
			if !errors.Is(got, tc.want) {
				t.Fatalf("SanitizeError = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestContextErrorIsNilForAnOrdinaryFailure(t *testing.T) {
	t.Parallel()
	if got := ContextError(context.Background(), errors.New("rpc")); got != nil {
		t.Fatalf("ContextError = %v, want nil", got)
	}
}

func TestBeginAndEndObjectWalkExactlyOneObject(t *testing.T) {
	t.Parallel()
	decoder, err := BeginObject(`{"schema": 1, "amount": 2.0}`)
	if err != nil {
		t.Fatalf("BeginObject: %v", err)
	}
	members := map[string]json.Number{}
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			t.Fatalf("member name: %v", err)
		}
		name, ok := token.(string)
		if !ok {
			t.Fatalf("member name %v is not a string", token)
		}
		var value json.Number
		if err := decoder.Decode(&value); err != nil {
			t.Fatalf("member value: %v", err)
		}
		members[name] = value
	}
	if err := EndObject(decoder); err != nil {
		t.Fatalf("EndObject: %v", err)
	}
	if members["schema"] != "1" || members["amount"] != "2.0" {
		t.Fatalf("members = %v, want numbers kept as written", members)
	}
}

func TestBeginObjectRefusesANonObject(t *testing.T) {
	t.Parallel()
	for name, value := range map[string]string{
		"array":  `[]`,
		"scalar": `1`,
		"empty":  ``,
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, err := BeginObject(value); err == nil {
				t.Fatalf("BeginObject(%q) accepted a non-object", value)
			}
		})
	}
}

func TestEndObjectRefusesTrailingContent(t *testing.T) {
	t.Parallel()
	for name, value := range map[string]string{
		"second object": `{} {}`,
		"scalar after":  `{} 1`,
		"unterminated":  `{`,
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			decoder, err := BeginObject(value)
			if err != nil {
				t.Fatalf("BeginObject(%q): %v", value, err)
			}
			for decoder.More() {
				if _, err := decoder.Token(); err != nil {
					break
				}
			}
			if err := EndObject(decoder); err == nil {
				t.Fatalf("EndObject accepted %q", value)
			}
		})
	}
}
