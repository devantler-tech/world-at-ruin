package nakamalease

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/heroiclabs/nakama-common/api"
)

// expandedLeaseFixtures preserves each complete object's raw JSON for the reader.
func expandedLeaseFixtures(t *testing.T) []json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile("testdata/golden_lease_v4.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []json.RawMessage
	if err := json.Unmarshal(raw, &fixtures); err != nil {
		t.Fatal(err)
	}
	if len(fixtures) != 7 {
		t.Fatalf("expanded lifecycle coverage has %d shapes", len(fixtures))
	}
	return fixtures
}

// legacyExpandedObservation models a caller rebuilding a record without schema
// provenance. Its exact durable version still cannot authorize a downgrade.
func legacyExpandedObservation(t *testing.T, raw string) Lease {
	t.Helper()
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &fields); err != nil {
		t.Fatal(err)
	}
	fields["schema"] = json.RawMessage("3")
	for _, key := range []string{"allocator_generation_id", "allocator_member_set_digest", "allocator_pod_uid"} {
		delete(fields, key)
	}
	encoded, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	lease, err := leaseFrom(string(encoded), testUserID, testReservationID)
	if err != nil {
		t.Fatal(err)
	}
	return lease
}

// Every mutation rechecks durable schema even when caller provenance was discarded.
func TestExpandedLeaseCannotBeDowngradedOrRetiredByLegacyMutations(t *testing.T) {
	operations := map[string]func(*Store, Record, string) error{
		"create": func(s *Store, r Record, _ string) error { _, err := s.Create(t.Context(), r.Lease); return err },
		"dispatch": func(s *Store, r Record, _ string) error {
			_, _, err := s.BeginDispatch(t.Context(), r, r.Lease.AttemptID)
			return err
		},
		"finalize": func(s *Store, r Record, _ string) error {
			_, err := s.Finalize(t.Context(), r, validLease())
			return err
		},
		"replace": func(s *Store, r Record, _ string) error {
			next := validLease()
			next.AttemptID = "attempt-next"
			_, err := s.Replace(t.Context(), r, next)
			return err
		},
		"release-barrier": func(s *Store, r Record, _ string) error {
			_, err := s.BeginRelease(t.Context(), r, r.Lease.AttemptID)
			return err
		},
		"claim": func(s *Store, r Record, _ string) error {
			_, err := s.Claim(t.Context(), r, r.Lease.AttemptID, time.Unix(1_999_999_998, 0))
			return err
		},
		"release": func(s *Store, r Record, _ string) error {
			return s.Release(t.Context(), testUserID, testReservationID, r.Lease.AttemptID)
		},
		"claim-key": func(s *Store, r Record, key string) error {
			r.Lease.UserID, r.Lease.ReservationID = "", ""
			_, err := s.ClaimByKey(t.Context(), key, r, time.Unix(1_999_999_998, 0))
			return err
		},
		"barrier-delete": func(s *Store, r Record, key string) error { return s.deleteEndedSession(t.Context(), key, r) },
		"write-key": func(s *Store, r Record, key string) error {
			_, err := s.writeKey(t.Context(), key, r.Lease, r.Version)
			return err
		},
		"expiry": func(s *Store, _ Record, _ string) error {
			return s.ReclaimExpired(t.Context(), time.Unix(2_000_000_001, 0), func(context.Context, Lease) error { t.Error("expanded lease reached resource cleanup"); return nil })
		},
	}
	for shape, raw := range expandedLeaseFixtures(t) {
		for name, operation := range operations {
			for _, reconstructed := range []bool{false, true} {
				t.Run(fmt.Sprintf("%d/%s/reconstructed-%t", shape, name, reconstructed), func(t *testing.T) {
					storage, store, key := seedExpandedLease(t, string(raw))
					before := cloneStorageObject(storage.objects[storageID(testSystemUserID, Collection, key)])
					record, err := store.Load(t.Context(), testUserID, testReservationID)
					if err != nil {
						t.Fatal(err)
					}
					if reconstructed {
						record.Lease = legacyExpandedObservation(t, string(raw))
					}
					if err := operation(store, record, key); err == nil {
						t.Fatal("expanded schema accepted as writer authority")
					}
					if !reflect.DeepEqual(before, storage.objects[storageID(testSystemUserID, Collection, key)]) || len(storage.writes) != 0 || len(storage.deletes) != 0 {
						t.Fatal("expanded state was mutated")
					}
				})
			}
		}
	}
}

func TestExpandedSessionCannotReachTrustedEndCleanup(t *testing.T) {
	t.Parallel()
	store, fake, _, fence := sessionFixture(t)
	object, ok := fake.Get(Collection, fence.LeaseObjectID, "")
	if !ok {
		t.Fatal("missing claimed session")
	}
	var members map[string]any
	if err := json.Unmarshal([]byte(object.Value), &members); err != nil {
		t.Fatal(err)
	}
	members["schema"] = 4
	members["allocator_generation_id"] = "generation:1"
	members["allocator_member_set_digest"] = "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d"
	members["allocator_pod_uid"] = "pod-allocator-1"
	raw, err := json.Marshal(members)
	if err != nil {
		t.Fatal(err)
	}
	object.Value = string(raw)
	fake.Seed(object)
	before := fake.Objects()
	writes := len(fake.WriteCalls)
	calls := 0
	err = store.EndSession(t.Context(), fence, func(context.Context, Lease) error { calls++; return nil })
	if err == nil || calls != 0 || len(fake.WriteCalls) != writes || !reflect.DeepEqual(before, fake.Objects()) {
		t.Fatalf("expanded session reached mutation or cleanup: %v, cleanup=%d", err, calls)
	}
}

// seedExpandedLease uses the real store over a controlled external storage boundary.
func seedExpandedLease(t *testing.T, raw string) (*memoryStorage, *Store, string) {
	t.Helper()
	storage, store := newLeaseStoreFixture(t)
	key := ReservationKey(testUserID, testReservationID)
	storage.objects[storageID(testSystemUserID, Collection, key)] = &api.StorageObject{
		Collection: Collection, Key: key, UserId: testSystemUserID, Value: raw, Version: "expanded-version",
	}
	return storage, store, key
}

// Expanded lifecycle observations remain complete and protected without read-side writes.
func TestExpandedLeaseShapesRemainProtectedThroughEveryReadPath(t *testing.T) {
	t.Parallel()
	for shape, fixture := range expandedLeaseFixtures(t) {
		t.Run(string(rune('a'+shape)), func(t *testing.T) {
			t.Parallel()
			storage, store, key := seedExpandedLease(t, string(fixture))
			before := cloneStorageObject(storage.objects[storageID(testSystemUserID, Collection, key)])
			loaded, err := store.Load(t.Context(), testUserID, testReservationID)
			if err != nil || loaded.Version != "expanded-version" || loaded.Lease.AttemptID != "attempt-7" {
				t.Fatalf("expanded shape was lost by direct read: %+v, %v", loaded, err)
			}
			wantBinding := AllocatorBinding{}
			if shape != 0 && shape != 5 {
				wantBinding = AllocatorBinding{GenerationID: "generation:1", MemberSetDigest: "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d", PodUID: "pod-allocator-1"}
			}
			if !loaded.Lease.ReaderOnly() || loaded.Lease.AllocatorBinding != wantBinding {
				t.Fatalf("binding or schema provenance lost: %+v", loaded)
			}
			byKey, err := store.LoadForClaim(t.Context(), key)
			listed := loaded
			listed.Lease.UserID, listed.Lease.ReservationID = "", ""
			if err != nil || byKey != listed {
				t.Fatalf("claim read lost state: %+v, %v", byKey, err)
			}
			protected, err := store.ProtectedAttempts(t.Context(), 1)
			digest, digestErr := agones.CorrelationLabel("attempt-7")
			_, included := protected[digest]
			if err != nil || digestErr != nil || len(protected) != 1 || !included {
				t.Fatalf("expanded attempt lost protection: %v, %v", protected, err)
			}
			if !reflect.DeepEqual(before, storage.objects[storageID(testSystemUserID, Collection, key)]) ||
				len(storage.writes) != 0 || len(storage.deletes) != 0 {
				t.Fatal("read paths mutated expanded state")
			}
		})
	}
}

// Ambiguous or incomplete rows cannot become direct state, partial protection or absence.
func TestExpandedLeaseCorruptionFailsCompleteObservation(t *testing.T) {
	t.Parallel()
	raw := string(expandedLeaseFixtures(t)[1])
	cases := map[string]string{
		"duplicate-schema":     strings.Replace(raw, "\"schema\":4", "\"schema\":4,\"schema\":3", 1),
		"escaped-schema":       strings.Replace(raw, "\"schema\":4", "\"schema\":4,\"\\u0073chema\":3", 1),
		"unicode-schema-alias": strings.Replace(raw, "\"schema\":4", "\"schema\":4,\"ſchema\":3", 1),
		"trailing":             raw + "{}", "unknown-proof": strings.Replace(raw, "\"schema\":4", "\"schema\":4,\"proof\":null", 1),
		"surrogate-pod": strings.Replace(raw, "pod-allocator-1", "pod-\\ud800", 1),
		"invalid-utf8":  strings.Replace(raw, "pod-allocator-1", "pod-\xff", 1),
	}
	var members map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &members); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"schema", "allocator_generation_id", "allocator_member_set_digest", "allocator_pod_uid", "attempt_id", "allocation_id", "observer", "secret_ref", "expires_at_nanos", "claimed_at_nanos"} {
		for _, null := range []bool{false, true} {
			if field == "claimed_at_nanos" && null {
				continue
			} // null is the explicit unclaimed shape.
			changed := make(map[string]json.RawMessage)
			for k, v := range members {
				changed[k] = v
			}
			name := "omitted-"
			if null {
				changed[field] = json.RawMessage("null")
				name = "null-"
			} else {
				delete(changed, field)
			}
			encoded, err := json.Marshal(changed)
			if err != nil {
				t.Fatal(err)
			}
			cases[name+field] = string(encoded)
		}
	}
	for name, change := range map[string]map[string]json.RawMessage{
		"partial-binding":             {"allocator_pod_uid": json.RawMessage(`""`)},
		"empty-dispatch-binding":      {"allocator_generation_id": json.RawMessage(`""`), "allocator_member_set_digest": json.RawMessage(`""`), "allocator_pod_uid": json.RawMessage(`""`)},
		"uppercase-digest":            {"allocator_member_set_digest": json.RawMessage(`"` + strings.Repeat("A", 64) + `"`)},
		"generation-whitespace":       {"allocator_generation_id": json.RawMessage(`"generation 1"`)},
		"oversized-pod":               {"allocator_pod_uid": json.RawMessage(`"` + strings.Repeat("p", 129) + `"`)},
		"bound-undispatched-staging":  {"dispatched": json.RawMessage("false"), "dispatch_id": json.RawMessage(`""`)},
		"dispatched-final-allocation": {"staging": json.RawMessage("false")},
		"null-staging":                {"staging": json.RawMessage("null")},
	} {
		changed := make(map[string]json.RawMessage)
		for k, v := range members {
			changed[k] = v
		}
		for k, v := range change {
			changed[k] = v
		}
		encoded, err := json.Marshal(changed)
		if err != nil {
			t.Fatal(err)
		}
		cases[name] = string(encoded)
	}
	for name, value := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			storage, store, key := seedExpandedLease(t, value)
			before := cloneStorageObject(storage.objects[storageID(testSystemUserID, Collection, key)])
			if _, err := store.Load(t.Context(), testUserID, testReservationID); err == nil {
				t.Fatal("corruption became direct state")
			}
			if _, err := store.LoadForClaim(t.Context(), key); err == nil {
				t.Fatal("corruption became claim state")
			}
			if got, err := store.ProtectedAttempts(t.Context(), 1); err == nil || got != nil {
				t.Fatal("partial protection result escaped")
			}
			if _, err := store.Create(t.Context(), validLease()); err == nil {
				t.Fatal("corruption became absence")
			}
			if !reflect.DeepEqual(before, storage.objects[storageID(testSystemUserID, Collection, key)]) || len(storage.writes) != 0 || len(storage.deletes) != 0 {
				t.Fatal("corruption was rewritten")
			}
		})
	}
}

// Legacy schemas refuse newer binding members even when their values are empty or null.
func TestLegacyLeasesRefuseExpandedBindingByPresence(t *testing.T) {
	for _, schema := range []string{"1", "2", "3"} {
		for _, field := range bindingKeys {
			for _, value := range []string{`""`, "null", `"generation:1"`} {
				t.Run(schema+"/"+field+"/"+value, func(t *testing.T) {
					legacy := `{"schema":` + schema + `,"attempt_id":"attempt-7","allocation_id":"gameserver-17","observer":42,"secret_ref":"zone-admission-gameserver-17","expires_at_nanos":2000000000123456789,"claimed_at_nanos":null,"` + field + `":` + value + `}`
					_, store, key := seedExpandedLease(t, legacy)
					if _, err := store.Load(t.Context(), testUserID, testReservationID); err == nil {
						t.Fatal("legacy reader accepted a newer binding member")
					}
					if _, err := store.LoadForClaim(t.Context(), key); err == nil {
						t.Fatal("claim reader accepted a newer binding member")
					}
					if got, err := store.ProtectedAttempts(t.Context(), 1); err == nil || got != nil {
						t.Fatal("legacy binding escaped complete observation")
					}
				})
			}
		}
	}
}
