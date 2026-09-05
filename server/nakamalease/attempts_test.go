package nakamalease

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/heroiclabs/nakama-common/api"
)

type attemptPages struct {
	*memoryStorage
	pages map[string][]*api.StorageObject
	next  map[string]string
	errAt string
	calls int
}

func (s *attemptPages) StorageList(ctx context.Context, caller, owner, collection string, limit int, cursor string) ([]*api.StorageObject, string, error) {
	s.calls++
	if err := ctx.Err(); err != nil {
		return nil, "", err
	}
	if caller != "" || owner != systemOwnerID || collection != Collection || limit != 100 {
		return nil, "", errors.New("wrong private collection scope")
	}
	if cursor == s.errAt {
		return nil, "", errors.New("private-token-and-identifiers")
	}
	return s.pages[cursor], s.next[cursor], nil
}

func attemptObject(t *testing.T, attempt string, change func(*Lease)) *api.StorageObject {
	t.Helper()
	lease := Lease{UserID: testUserID, ReservationID: attempt, AttemptID: attempt, Staging: true, ExpiresAt: time.Unix(2, 0)}
	change(&lease)
	if _, err := normalizeLease(lease); err != nil {
		t.Fatal(err)
	}
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	// Seeding exercises the production writer but allows every stored lifecycle.
	if _, err = store.write(context.Background(), lease, "*"); err != nil {
		t.Fatal(err)
	}
	for _, object := range storage.objects {
		return cloneStorageObject(object)
	}
	t.Fatal("missing seeded lease")
	return nil
}

func TestProtectedAttemptsIncludesEveryLeaseStateAcrossPages(t *testing.T) {
	changes := []func(*Lease){
		func(*Lease) {},
		func(l *Lease) { l.Dispatched = true; l.DispatchID = "dispatch-1" },
		func(l *Lease) { l.Releasing = true },
		func(l *Lease) {
			l.Staging = false
			l.AllocationID = testAllocationID
			l.Observer = 1
			l.SecretRef = testSecretRef
		},
		func(l *Lease) {
			l.Staging = false
			l.AllocationID = testAllocationID
			l.Observer = 1
			l.SecretRef = testSecretRef
			l.ClaimedAt = time.Unix(1, 0)
		},
	}
	storage := &attemptPages{memoryStorage: newMemoryStorage(), pages: map[string][]*api.StorageObject{}, next: map[string]string{"": "second"}, errAt: "never"}
	want := map[string]struct{}{}
	for i, change := range changes {
		attempt := "attempt-" + strings.Repeat("x", i+1)
		page := ""
		if i > 1 {
			page = "second"
		}
		storage.pages[page] = append(storage.pages[page], attemptObject(t, attempt, change))
		digest, err := agones.CorrelationLabel(attempt)
		if err != nil {
			t.Fatal(err)
		}
		want[digest] = struct{}{}
	}
	store, err := NewStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	got, err := store.ProtectedAttempts(context.Background(), 3)
	if err != nil || len(got) != len(want) {
		t.Fatalf("protected attempts = %v, %v; want all %d lifecycle records", got, err, len(want))
	}
	for digest := range want {
		if _, ok := got[digest]; !ok {
			t.Error("a stored lease lost protection")
		}
	}
	if storage.calls != 2 || len(storage.writes) != 0 || len(storage.deletes) != 0 {
		t.Fatal("scan must exhaust pages without writes")
	}
}

func TestProtectedAttemptsRefusesIncompleteOrInvalidEvidence(t *testing.T) {
	valid := attemptObject(t, "attempt-1", func(*Lease) {})
	for _, scenario := range []string{"late error", "cursor cycle", "page limit", "public", "foreign owner", "unknown schema", "duplicate key", "oversized page", "canceled", "invalid limit", "oversized value", "oversized cursor", "wildcard version", "duplicate member"} {
		t.Run(scenario, func(t *testing.T) {
			storage := &attemptPages{memoryStorage: newMemoryStorage(), pages: map[string][]*api.StorageObject{"": {cloneStorageObject(valid)}, "next": {}}, next: map[string]string{"": "next"}, errAt: "never"}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			limit := 3
			switch scenario {
			case "late error":
				storage.errAt = "next"
			case "cursor cycle":
				storage.next["next"] = "next"
			case "page limit":
				limit = 1
			case "public":
				storage.pages[""][0].PermissionRead = 2
			case "foreign owner":
				storage.pages[""][0].UserId = testUserID
			case "unknown schema":
				storage.pages[""][0].Value = `{"schema":999}`
			case "duplicate key":
				storage.pages["next"] = []*api.StorageObject{cloneStorageObject(valid)}
			case "oversized page":
				for range 100 {
					storage.pages[""] = append(storage.pages[""], valid)
				}
			case "canceled":
				cancel()
			case "invalid limit":
				limit = 0
			case "oversized value":
				storage.pages[""][0].Value += strings.Repeat(" ", 65536)
			case "oversized cursor":
				storage.next[""] = strings.Repeat("c", 16385)
			case "wildcard version":
				storage.pages[""][0].Version = "*"
			case "duplicate member":
				storage.pages[""][0].Value = strings.Replace(storage.pages[""][0].GetValue(), `"attempt_id":`, `"ATTEMPT_ID":"hidden-attempt","attempt_id":`, 1)
			}
			store, err := NewStore(storage)
			if err != nil {
				t.Fatal(err)
			}
			got, err := store.ProtectedAttempts(ctx, limit)
			if err == nil || got != nil {
				t.Fatalf("partial/invalid evidence accepted: %v, %v", got, err)
			}
			if strings.Contains(err.Error(), "private-token") {
				t.Fatal("storage detail escaped")
			}
		})
	}
}
