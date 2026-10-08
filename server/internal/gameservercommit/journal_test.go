package gameservercommit

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const journalFixtureKey = "c3be3a401178b7bbc9e7df4140309335b7d5f06188f18c7c8dadcd2378e466e8"

// journalBinding supplies independently calculated fixture identities rather
// than deriving expected data from the reader or its digest implementation.
func journalBinding() JournalBinding {
	return JournalBinding{GenerationID: "generation-1", GenerationVersion: "source-version-1",
		MemberPodUIDs: []string{"pod-a", "pod-b"}, MemberSetDigest: "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d",
		IncarnationID: "incarnation-1", Namespace: "trial", Fleet: "fleet", IssuedCount: 2,
		IssuedDigest: "4febaec6be92e850b2d08dd58cf55bb7e368994f597c35915286be3278f79226", Version: "journal-version-1"}
}

// journalJSON preserves fixture bytes through the production decoder so the
// historical reader probes can detect ignored or lossy fixture results.
func journalJSON(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("testdata/golden_allocator_grant_journal_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

type journalReply struct {
	rows  []*api.StorageObject
	err   error
	after func()
	reads []*runtime.StorageRead
}

// StorageRead is the sole storage capability the reader can receive. Its
// exact requested address and detached response semantics are observable.
func (s *journalReply) StorageRead(_ context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	s.reads = reads
	if s.after != nil {
		s.after()
	}
	return s.rows, s.err
}

// journalRow retains all private Nakama object metadata for boundary controls.
func journalRow(t *testing.T) *api.StorageObject {
	t.Helper()
	return &api.StorageObject{Collection: JournalCollection, Key: journalFixtureKey, UserId: nakamastorage.SystemOwnerID,
		Version: "journal-version-1", Value: journalJSON(t)}
}

// TestJournalLoadKeepsEveryShippedSchemaReadable fails if any persisted binding
// or grant field is dropped, rewritten, or replaced by decoder zero values.
func TestJournalLoadKeepsEveryShippedSchemaReadable(t *testing.T) {
	storage := &journalReply{rows: []*api.StorageObject{journalRow(t)}}
	binding := journalBinding()
	reader, err := NewJournalReader(JournalReaderConfig{Enabled: true, Storage: storage, Binding: binding})
	if err != nil {
		t.Fatal(err)
	}
	binding.MemberPodUIDs[0] = "caller-changed"
	got, err := reader.Load(context.Background())
	want := JournalObservation{Binding: journalBinding(), Grants: []JournalGrant{
		{ActorUID: "pod-a", AttemptID: "attempt-a", Name: "zone-a", UID: "uid-a", SourceVersion: "resource-a"},
		{ActorUID: "pod-b", AttemptID: "attempt-b", Name: "zone-b", UID: "uid-b", SourceVersion: "resource-b"},
	}}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("lossy journal: %#v %v", got, err)
	}
	if len(storage.reads) != 1 || storage.reads[0].Collection != JournalCollection || storage.reads[0].Key != journalFixtureKey || storage.reads[0].UserID != "" {
		t.Fatal("reader did not request the exact private system-owned key")
	}
	got.Binding.MemberPodUIDs[0], got.Grants[0].UID = "changed", "changed"
	again, err := reader.Load(context.Background())
	if err != nil || !reflect.DeepEqual(again, want) {
		t.Fatal("caller mutated reader expectations or later observation")
	}
}

// TestJournalDefaultOffNeverReads ensures no opt-in means no dependency access.
func TestJournalDefaultOffNeverReads(t *testing.T) {
	storage := &journalReply{}
	if _, err := NewJournalReader(JournalReaderConfig{Storage: storage, Binding: journalBinding()}); !errors.Is(err, ErrDisabled) {
		t.Fatal(err)
	}
	if storage.reads != nil {
		t.Fatal("disabled reader touched storage")
	}
}

// TestJournalRefusesUnboundConstruction prevents adopting missing, noncanonical
// or unbounded caller expectations as a recovery identity.
func TestJournalRefusesUnboundConstruction(t *testing.T) {
	for _, change := range []func(*JournalBinding){
		func(b *JournalBinding) { b.IncarnationID = "" }, func(b *JournalBinding) { b.GenerationID = "" },
		func(b *JournalBinding) { b.GenerationVersion = "*" }, func(b *JournalBinding) { b.Version = "*" },
		func(b *JournalBinding) { b.MemberPodUIDs[0] = "pod-b" }, func(b *JournalBinding) { b.MemberPodUIDs = nil },
		func(b *JournalBinding) { b.MemberSetDigest = strings.Repeat("0", 64) }, func(b *JournalBinding) { b.IssuedDigest = "UPPER" },
		func(b *JournalBinding) { b.IssuedCount = -1 }, func(b *JournalBinding) { b.IssuedCount = 257 },
		func(b *JournalBinding) { b.Namespace = "bad/namespace" }, func(b *JournalBinding) { b.Fleet = "" },
	} {
		binding := journalBinding()
		change(&binding)
		if _, err := NewJournalReader(JournalReaderConfig{Enabled: true, Storage: &journalReply{}, Binding: binding}); !errors.Is(err, ErrInvalid) {
			t.Fatalf("bad binding accepted: %#v %v", binding, err)
		}
	}
	if _, err := NewJournalReader(JournalReaderConfig{Enabled: true, Binding: journalBinding()}); !errors.Is(err, ErrInvalid) {
		t.Fatal("nil storage accepted")
	}
}

// TestJournalReadFailuresNeverReturnPartialObservation ensures plausible rows
// alongside failure, cancellation or foreign metadata cannot count as evidence.
func TestJournalReadFailuresNeverReturnPartialObservation(t *testing.T) {
	for _, fault := range []string{"missing", "duplicate-row", "nil-row", "collection", "key", "owner", "read-permission", "write-permission", "version", "error-with-row", "canceled-before", "canceled-after"} {
		t.Run(fault, func(t *testing.T) {
			row := journalRow(t)
			storage := &journalReply{rows: []*api.StorageObject{row}}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch fault {
			case "missing":
				storage.rows = nil
			case "duplicate-row":
				storage.rows = append(storage.rows, row)
			case "nil-row":
				storage.rows = []*api.StorageObject{nil}
			case "collection":
				row.Collection = "foreign"
			case "key":
				row.Key = "foreign"
			case "owner":
				row.UserId = "11111111-1111-4111-8111-111111111111"
			case "read-permission":
				row.PermissionRead = 1
			case "write-permission":
				row.PermissionWrite = 1
			case "version":
				row.Version = "another-journal-version"
			case "error-with-row":
				storage.err = errors.New("private backing-storage diagnostic")
			case "canceled-before":
				cancel()
			case "canceled-after":
				storage.after = cancel
			}
			reader, err := NewJournalReader(JournalReaderConfig{Enabled: true, Storage: storage, Binding: journalBinding()})
			if err != nil {
				t.Fatal(err)
			}
			got, err := reader.Load(ctx)
			if !errors.Is(err, ErrUnknown) || !reflect.DeepEqual(got, JournalObservation{}) || strings.Contains(err.Error(), "private") {
				t.Fatalf("partial data or leaked error: %#v %v", got, err)
			}
			if strings.HasPrefix(fault, "canceled") && !errors.Is(err, context.Canceled) {
				t.Fatal("cancellation identity lost")
			}
			if fault == "canceled-before" && storage.reads != nil {
				t.Fatal("canceled reader called storage")
			}
		})
	}
}

// TestJournalRejectsAmbiguousOrIncompleteDocuments catches malformed nested
// JSON, independent-binding mismatches, and canonical-set loss or substitution.
func TestJournalRejectsAmbiguousOrIncompleteDocuments(t *testing.T) {
	raw := journalJSON(t)
	cases := map[string]string{
		"outer-duplicate":  strings.Replace(raw, `"schema": 1`, `"schema": 1, "schema": 1`, 1),
		"outer-unknown":    strings.Replace(raw, `"schema": 1`, `"schema": 1, "receipt": true`, 1),
		"nested-duplicate": strings.Replace(raw, `"uid": "uid-a"`, `"uid": "uid-a", "uid": "uid-a"`, 1),
		"nested-unknown":   strings.Replace(raw, `"uid": "uid-a"`, `"uid": "uid-a", "authority": true`, 1),
		"nested-null":      strings.Replace(raw, `"uid": "uid-a"`, `"uid": null`, 1),
		"null-count":       strings.Replace(raw, `"grant_count": 2`, `"grant_count": null`, 1),
		"future":           strings.Replace(raw, `"schema": 1`, `"schema": 2`, 1),
		"fraction":         strings.Replace(raw, `"schema": 1`, `"schema": 1.0`, 1),
		"unicode":          strings.Replace(raw, `"uid-a"`, `"\ud800"`, 1),
		"lossy-utf8":       strings.Replace(raw, "uid-a", "uid-\xff", 1),
		"trailing":         raw + `{}`,
		"oversized":        raw + strings.Repeat(" ", 262145),
	}
	for _, field := range []string{"generation_id", "generation_source_version", "member_pod_uids", "member_set_digest", "authority_incarnation", "namespace", "fleet", "grant_count", "grant_set_digest", "grants"} {
		var doc map[string]any
		if err := json.Unmarshal([]byte(raw), &doc); err != nil {
			t.Fatal(err)
		}
		delete(doc, field)
		encoded, err := json.Marshal(doc)
		if err != nil {
			t.Fatal(err)
		}
		cases["missing-"+field] = string(encoded)
	}
	for _, change := range []struct {
		name   string
		mutate func(map[string]any)
	}{
		{"incarnation", func(d map[string]any) { d["authority_incarnation"] = "incarnation-2" }},
		{"generation", func(d map[string]any) { d["generation_id"] = "generation-2" }},
		{"generation-version", func(d map[string]any) { d["generation_source_version"] = "source-2" }},
		{"fleet", func(d map[string]any) { d["fleet"] = "another" }},
		{"namespace", func(d map[string]any) { d["namespace"] = "another" }},
		{"member-digest", func(d map[string]any) { d["member_set_digest"] = strings.Repeat("0", 64) }},
		{"members", func(d map[string]any) { d["member_pod_uids"] = []string{"pod-b", "pod-a"} }},
		{"null-grants", func(d map[string]any) { d["grants"] = nil }},
		{"omitted-grant", func(d map[string]any) { d["grants"] = journalArray(t, d["grants"])[:1]; d["grant_count"] = 1 }},
		{"reordered", func(d map[string]any) { g := journalArray(t, d["grants"]); g[0], g[1] = g[1], g[0] }},
		{"duplicate-uid", func(d map[string]any) { g := journalArray(t, d["grants"]); journalFields(t, g[1])["uid"] = "uid-a" }},
		{"duplicate-name", func(d map[string]any) { g := journalArray(t, d["grants"]); journalFields(t, g[1])["name"] = "zone-a" }},
		{"foreign-actor", func(d map[string]any) { journalFields(t, journalArray(t, d["grants"])[0])["actor_uid"] = "pod-foreign" }},
		{"changed-version", func(d map[string]any) {
			journalFields(t, journalArray(t, d["grants"])[0])["source_version"] = "different"
		}},
		{"changed-attempt", func(d map[string]any) { journalFields(t, journalArray(t, d["grants"])[0])["attempt_id"] = "different" }},
	} {
		var doc map[string]any
		if err := json.Unmarshal([]byte(raw), &doc); err != nil {
			t.Fatal(err)
		}
		change.mutate(doc)
		encoded, err := json.Marshal(doc)
		if err != nil {
			t.Fatal(err)
		}
		cases[change.name] = string(encoded)
	}
	for name, value := range cases {
		t.Run(name, func(t *testing.T) {
			row := journalRow(t)
			row.Value = value
			reader, err := NewJournalReader(JournalReaderConfig{Enabled: true, Storage: &journalReply{rows: []*api.StorageObject{row}}, Binding: journalBinding()})
			if err != nil {
				t.Fatal(err)
			}
			got, err := reader.Load(context.Background())
			if !errors.Is(err, ErrUnknown) || !reflect.DeepEqual(got, JournalObservation{}) {
				t.Fatalf("incomplete journal accepted: %#v %v", got, err)
			}
		})
	}
}

// TestJournalIndependentBindingRejectsSelfConsistentOmission catches a reader
// that substitutes the stored row's own count/digest for external expectations.
func TestJournalIndependentBindingRejectsSelfConsistentOmission(t *testing.T) {
	row := journalRow(t)
	var doc map[string]any
	if err := json.Unmarshal([]byte(row.GetValue()), &doc); err != nil {
		t.Fatal(err)
	}
	first := []JournalGrant{{ActorUID: "pod-a", AttemptID: "attempt-a", Name: "zone-a", UID: "uid-a", SourceVersion: "resource-a"}}
	raw, err := json.Marshal(first)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-issued-grants/v1\n"), raw...))
	doc["grants"], doc["grant_count"], doc["grant_set_digest"] = first, 1, hex.EncodeToString(digest[:])
	encoded, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	row.Value = string(encoded)
	reader, err := NewJournalReader(JournalReaderConfig{Enabled: true, Storage: &journalReply{rows: []*api.StorageObject{row}}, Binding: journalBinding()})
	if err != nil {
		t.Fatal(err)
	}
	if got, err := reader.Load(context.Background()); !errors.Is(err, ErrUnknown) || len(got.Grants) != 0 {
		t.Fatal("self-consistent omission replaced the independent complete set")
	}
}

// TestJournalBoundsAndUnicode preserves empty inventories and valid paired
// Unicode source versions, while refusing attempts the mutation cannot accept.
func TestJournalBoundsAndUnicode(t *testing.T) {
	for _, arm := range []string{"empty", "paired-unicode", "invalid-attempt"} {
		t.Run(arm, func(t *testing.T) {
			row := journalRow(t)
			binding := journalBinding()
			var doc map[string]any
			if err := json.Unmarshal([]byte(row.GetValue()), &doc); err != nil {
				t.Fatal(err)
			}
			grants := []JournalGrant{{ActorUID: "pod-a", AttemptID: "attempt-a", Name: "zone-a", UID: "uid-a", SourceVersion: "resource-a"}, {ActorUID: "pod-b", AttemptID: "attempt-b", Name: "zone-b", UID: "uid-b", SourceVersion: "resource-b"}}
			switch arm {
			case "empty":
				grants = []JournalGrant{}
			case "paired-unicode":
				grants[0].SourceVersion = "revision-😀"
			case "invalid-attempt":
				grants[0].AttemptID = "attempt.with.dot"
			}
			raw, err := json.Marshal(grants)
			if err != nil {
				t.Fatal(err)
			}
			digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-issued-grants/v1\n"), raw...))
			binding.IssuedCount, binding.IssuedDigest = len(grants), hex.EncodeToString(digest[:])
			doc["grants"], doc["grant_count"], doc["grant_set_digest"] = grants, binding.IssuedCount, binding.IssuedDigest
			encoded, err := json.Marshal(doc)
			if err != nil {
				t.Fatal(err)
			}
			row.Value = strings.ReplaceAll(string(encoded), "😀", `\ud83d\ude00`)
			reader, err := NewJournalReader(JournalReaderConfig{Enabled: true, Storage: &journalReply{rows: []*api.StorageObject{row}}, Binding: binding})
			if err != nil {
				t.Fatal(err)
			}
			got, err := reader.Load(context.Background())
			if arm == "invalid-attempt" {
				if !errors.Is(err, ErrUnknown) {
					t.Fatal("journal accepted an attempt that cannot prepare a mutation")
				}
				return
			}
			if err != nil || !reflect.DeepEqual(got.Grants, grants) {
				t.Fatalf("empty or Unicode inventory changed: %#v %v", got, err)
			}
		})
	}
}

// journalArray requires complete array-shaped fixture data before mutation.
func journalArray(t *testing.T, value any) []any {
	t.Helper()
	got, ok := value.([]any)
	if !ok {
		t.Fatal("fixture grants must be an array")
	}
	return got
}

// journalFields requires complete object-shaped fixture data before mutation.
func journalFields(t *testing.T, value any) map[string]any {
	t.Helper()
	got, ok := value.(map[string]any)
	if !ok {
		t.Fatal("fixture grant must be an object")
	}
	return got
}
