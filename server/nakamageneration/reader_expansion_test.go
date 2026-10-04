package nakamageneration

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

const expandedGenerationOpen = `{"schema":2,"generation_id":"generation-1","member_pod_uids":["pod-a","pod-b"],"member_set_digest":"5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d","state":"open"}`

// Expanded generation states preserve immutable identity and cannot be adopted by creation.
func TestExpandedGenerationReadsRemainLosslessAndCreationIneligible(t *testing.T) {
	t.Parallel()
	for _, state := range []string{"open", "draining"} {
		t.Run(state, func(t *testing.T) {
			t.Parallel()
			raw := strings.Replace(expandedGenerationOpen, `"state":"open"`, `"state":"`+state+`"`, 1)
			storage := nakamastoragetest.New()
			storage.Seed(nakamastoragetest.Object{Collection: Collection, Key: "generation-1", Value: raw, Version: "expanded-version"})
			before := storage.Objects()
			store := newTestStore(t, storage)
			got, err := store.Load(t.Context(), "generation-1")
			if err != nil || got.GenerationID != "generation-1" || got.State != state ||
				got.MemberSetDigest != goldenDigest || got.Version != "expanded-version" ||
				!reflect.DeepEqual(got.MemberPodUIDs, []string{"pod-a", "pod-b"}) {
				t.Fatalf("expanded generation lost fields: %+v, %v", got, err)
			}
			got.MemberPodUIDs[0] = "caller-mutated"
			reloaded, err := store.Load(t.Context(), "generation-1")
			if err != nil || !reflect.DeepEqual(reloaded.MemberPodUIDs, []string{"pod-a", "pod-b"}) {
				t.Fatalf("caller mutation changed membership: %+v, %v", reloaded, err)
			}
			if _, err := store.CreateOpen(t.Context(), "generation-1", []string{"pod-a", "pod-b"}); !errors.Is(err, ErrConflict) {
				t.Fatalf("legacy create adopted expanded state: %v", err)
			}
			if !reflect.DeepEqual(before, storage.Objects()) || len(storage.WriteCalls) != 0 {
				t.Fatal("read or legacy create rewrote expanded state")
			}
		})
	}
}

// Corrupt expanded rows refuse both reads and create replay without replacing bytes.
func TestExpandedGenerationCorruptionCannotBecomeAbsence(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		"unsupported-schema": strings.Replace(expandedGenerationOpen, `"schema":2`, `"schema":3`, 1),
		"fenced":             strings.Replace(expandedGenerationOpen, `"state":"open"`, `"state":"fenced"`, 1),
		"proof":              strings.Replace(expandedGenerationOpen, `"schema":2`, `"schema":2,"proof":null`, 1),
		"duplicate-schema":   strings.Replace(expandedGenerationOpen, `"schema":2`, `"schema":2,"\u0073chema":1`, 1),
		"substituted-member": strings.Replace(expandedGenerationOpen, "pod-b", "pod-c", 1),
		"reordered-members":  strings.Replace(expandedGenerationOpen, `["pod-a","pod-b"]`, `["pod-b","pod-a"]`, 1),
		"duplicate-member":   strings.Replace(expandedGenerationOpen, "pod-b", "pod-a", 1),
		"unicode-alias":      strings.Replace(expandedGenerationOpen, "pod-b", `pod-\ud800`, 1),
		"trailing":           expandedGenerationOpen + "{}",
	}
	for _, field := range []string{"schema", "generation_id", "member_pod_uids", "member_set_digest", "state"} {
		cases["omitted-"+field] = changedDocument(t, expandedGenerationOpen, field, nil, true)
		cases["null-"+field] = changedDocument(t, expandedGenerationOpen, field, nil, false)
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			storage := nakamastoragetest.New()
			storage.Seed(nakamastoragetest.Object{Collection: Collection, Key: "generation-1", Value: raw, Version: "expanded-version"})
			before := storage.Objects()
			store := newTestStore(t, storage)
			if _, err := store.Load(t.Context(), "generation-1"); !errors.Is(err, ErrStorage) {
				t.Fatalf("corruption was readable: %v", err)
			}
			if _, err := store.CreateOpen(t.Context(), "generation-1", []string{"pod-a", "pod-b"}); !errors.Is(err, ErrStorage) {
				t.Fatalf("corruption became absence: %v", err)
			}
			if !reflect.DeepEqual(before, storage.Objects()) || len(storage.WriteCalls) != 0 {
				t.Fatal("corrupt record was rewritten")
			}
		})
	}
}
