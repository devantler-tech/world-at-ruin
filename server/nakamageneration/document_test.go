package nakamageneration

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

const goldenDigest = "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d"

func goldenDocument(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("testdata/golden_allocator_generation_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// TestEveryShippedGenerationSchemaStaysReadable binds historical raw bytes to
// complete, independently specified fields through both decoder and store.
func TestEveryShippedGenerationSchemaStaysReadable(t *testing.T) {
	t.Parallel()
	ledger, err := os.ReadFile("testdata/shipped_allocator_generation_versions.txt")
	if err != nil {
		t.Fatal(err)
	}
	versions := strings.Fields(string(ledger))
	want := []document{{
		Schema: 1, GenerationID: "generation-1", MemberPodUIDs: []string{"pod-a", "pod-b"},
		MemberSetDigest: goldenDigest, State: "open",
	}}
	if len(versions) != len(want) {
		t.Fatalf("historical expectations cover %d versions, ledger has %d", len(want), len(versions))
	}
	fixtures, err := os.OpenRoot("testdata")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = fixtures.Close() })
	for index, version := range versions {
		if version != strconv.Itoa(index+1) {
			t.Fatalf("noncontiguous ledger: %q", versions)
		}
		raw, readErr := fixtures.ReadFile("golden_allocator_generation_v" + version + ".json")
		if readErr != nil {
			t.Fatal(readErr)
		}
		got, decodeErr := decodeDocument(string(raw))
		if decodeErr != nil || !reflect.DeepEqual(got, want[index]) {
			t.Fatalf("schema %s lost historical fields: %+v, %v", version, got, decodeErr)
		}
		storage := nakamastoragetest.New()
		storage.Seed(nakamastoragetest.Object{Collection: Collection, Key: "generation-1", Value: string(raw), Version: "historical-version"})
		loaded, loadErr := newTestStore(t, storage).Load(t.Context(), "generation-1")
		wantRecord := Record{GenerationID: "generation-1", MemberPodUIDs: []string{"pod-a", "pod-b"}, MemberSetDigest: goldenDigest, State: "open", Version: "historical-version"}
		if loadErr != nil || !reflect.DeepEqual(loaded, wantRecord) || len(storage.WriteCalls) != 0 {
			t.Fatalf("schema %s store did not preserve history: %+v, %v", version, loaded, loadErr)
		}
	}
}

func TestMembershipDigestBindsCanonicalSetAndStringBoundaries(t *testing.T) {
	t.Parallel()
	for _, members := range [][]string{{"pod-a", "pod-b"}, {"pod-b", "pod-a"}} {
		got, err := openDocument("generation-1", members)
		if err != nil || got.MemberSetDigest != goldenDigest {
			t.Fatalf("membership digest drifted: %+v, %v", got, err)
		}
	}
	sets := [][]string{{"a", "bc"}, {"ab", "c"}, {"a,b", "c"}, {"a", "b,c"}, {`a\"`, "b"}, {`a`, `\"b`}}
	seen := make(map[string]bool)
	for _, set := range sets {
		got, err := openDocument("opaque:generation", set)
		if err != nil {
			t.Fatal(err)
		}
		if seen[got.MemberSetDigest] {
			t.Fatalf("ambiguous digest for %q", set)
		}
		seen[got.MemberSetDigest] = true
	}
	other, err := openDocument("generation-2", []string{"pod-a", "pod-b"})
	if err != nil || other.MemberSetDigest != goldenDigest {
		t.Fatal("membership identity improperly includes generation identity")
	}
}

func TestCreateOpenValidatesBoundsBeforeStorage(t *testing.T) {
	t.Parallel()
	oversizedSet := make([]string, 257)
	for index := range oversizedSet {
		oversizedSet[index] = fmt.Sprintf("pod-%d", index)
	}
	cases := []struct {
		name, id string
		members  []string
	}{
		{"empty-id", "", []string{"pod-a"}},
		{"long-id", strings.Repeat("g", 129), []string{"pod-a"}},
		{"space-id", "generation 1", []string{"pod-a"}},
		{"control-id", "generation\x00", []string{"pod-a"}},
		{"invalid-utf8-id", "generation\xff", []string{"pod-a"}},
		{"nil-set", "g", nil}, {"empty-set", "g", []string{}}, {"large-set", "g", oversizedSet},
		{"empty-member", "g", []string{""}}, {"long-member", "g", []string{strings.Repeat("p", 129)}},
		{"space-member", "g", []string{"pod\u2003a"}}, {"control-member", "g", []string{"pod\n"}},
		{"invalid-utf8-member", "g", []string{"pod\xff"}}, {"duplicate", "g", []string{"pod-a", "pod-a"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			storage := nakamastoragetest.New()
			_, err := newTestStore(t, storage).CreateOpen(t.Context(), tc.id, tc.members)
			if !errors.Is(err, ErrInvalidArgument) || storage.ReadCalls != 0 || len(storage.WriteCalls) != 0 {
				t.Fatalf("invalid input reached storage: %v", err)
			}
		})
	}
	storage := nakamastoragetest.New()
	_, err := newTestStore(t, storage).CreateOpen(t.Context(), strings.Repeat("g", 128), oversizedSet[:256])
	if err != nil {
		t.Fatalf("maximum valid bounds refused: %v", err)
	}
}

func TestRefusedDocumentsRemainByteIdenticalAndCannotBeRecreated(t *testing.T) {
	t.Parallel()
	raw := goldenDocument(t)
	cases := map[string]string{
		"empty": "", "null": "null", "array": "[" + raw + "]", "trailing": raw + "{}",
		"duplicate":         strings.Replace(raw, `"schema":1`, `"schema":1,"schema":1`, 1),
		"duplicate-escaped": strings.Replace(raw, `"schema":1`, `"schema":1,"\u0073chema":1`, 1),
		"unknown":           strings.Replace(raw, `"schema":1`, `"schema":1,"proof":{}`, 1),
		"wrong-case":        strings.Replace(raw, `"schema"`, `"Schema"`, 1),
		"decimal-schema":    strings.Replace(raw, `"schema":1`, `"schema":1.0`, 1),
		"large-document":    raw + strings.Repeat(" ", 65536),
	}
	for _, field := range []string{"schema", "generation_id", "member_pod_uids", "member_set_digest", "state"} {
		cases["missing-"+field] = changedDocument(t, raw, field, nil, true)
		cases["null-"+field] = changedDocument(t, raw, field, nil, false)
	}
	for name, change := range map[string]struct {
		field string
		value any
	}{
		"new-schema": {"schema", 2}, "string-schema": {"schema", "1"},
		"wrong-id": {"generation_id", "generation-2"}, "empty-id": {"generation_id", ""},
		"unsorted":      {"member_pod_uids", []string{"pod-b", "pod-a"}},
		"duplicates":    {"member_pod_uids", []string{"pod-a", "pod-a"}},
		"empty-members": {"member_pod_uids", []string{}}, "wrong-member-type": {"member_pod_uids", "pod-a"},
		"bad-digest":       {"member_set_digest", strings.Repeat("0", 64)},
		"uppercase-digest": {"member_set_digest", strings.ToUpper(goldenDigest)},
		"draining":         {"state", "draining"}, "fenced": {"state", "fenced"},
	} {
		cases[name] = changedDocument(t, raw, change.field, change.value, false)
	}
	for name, value := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			storage := nakamastoragetest.New()
			storage.Seed(nakamastoragetest.Object{Collection: Collection, Key: "generation-1", Value: value, Version: "opaque-version"})
			before := storage.Objects()
			store := newTestStore(t, storage)
			if _, err := store.Load(t.Context(), "generation-1"); !errors.Is(err, ErrStorage) {
				t.Fatalf("invalid record was readable: %v", err)
			}
			if _, err := store.CreateOpen(t.Context(), "generation-1", []string{"pod-a", "pod-b"}); !errors.Is(err, ErrStorage) {
				t.Fatalf("refusal became absence: %v", err)
			}
			if !reflect.DeepEqual(before, storage.Objects()) || len(storage.WriteCalls) != 0 {
				t.Fatal("refused record was mutated")
			}
		})
	}
}

func changedDocument(t *testing.T, raw, field string, value any, remove bool) string {
	t.Helper()
	var fields map[string]any
	if err := json.Unmarshal([]byte(raw), &fields); err != nil {
		t.Fatal(err)
	}
	if remove {
		delete(fields, field)
	} else {
		fields[field] = value
	}
	changed, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	return string(changed)
}

func TestMalformedUnicodeCannotAliasDurableMembership(t *testing.T) {
	t.Parallel()
	doc, err := openDocument("generation-1", []string{"pod-�"})
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	for name, spelling := range map[string]string{
		"invalid-utf8": "pod-\xff", "high-surrogate": `pod-\ud800`,
		"low-surrogate": `pod-\udc00`, "high-then-character": `pod-\ud800x`,
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			corrupt := strings.Replace(string(encoded), "pod-�", spelling, 1)
			storage := nakamastoragetest.New()
			storage.Seed(nakamastoragetest.Object{Collection: Collection, Key: "generation-1", Value: corrupt, Version: "v1"})
			before := storage.Objects()
			store := newTestStore(t, storage)
			if _, err := store.Load(t.Context(), "generation-1"); !errors.Is(err, ErrStorage) {
				t.Fatalf("malformed Unicode aliased membership: %v", err)
			}
			if _, err := store.CreateOpen(t.Context(), "generation-1", []string{"pod-�"}); !errors.Is(err, ErrStorage) {
				t.Fatalf("corruption adopted as replay: %v", err)
			}
			if !reflect.DeepEqual(before, storage.Objects()) || len(storage.WriteCalls) != 0 {
				t.Fatal("corrupt Unicode was rewritten")
			}
		})
	}
}

func TestValidUnicodeAndEscapedBackslashesPreserveOpaqueIdentity(t *testing.T) {
	t.Parallel()
	for _, member := range []string{"pod-�", "pod-😀", "pod-ø", `pod-\ud800`} {
		doc, err := openDocument("generation-1", []string{member})
		if err != nil {
			t.Fatal(err)
		}
		encoded, err := json.Marshal(doc)
		if err != nil {
			t.Fatal(err)
		}
		raw := strings.ReplaceAll(string(encoded), "😀", `\ud83d\ude00`)
		got, err := decodeDocument(raw)
		if err != nil || !reflect.DeepEqual(got, doc) {
			t.Fatalf("valid opaque member %q changed: %+v, %v", member, got, err)
		}
	}
}
