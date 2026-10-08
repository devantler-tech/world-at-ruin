package trial

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"slices"
	"testing"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/internal/gameservercommit"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

// storedJournal independently encodes exact native target metadata into the
// shared Nakama fake. It performs no production journal write or activation.
func storedJournal(t *testing.T, objects []*agonesv1.GameServer) (gameservercommit.JournalBinding, []gameservercommit.JournalGrant, *nakamastoragetest.Fake) {
	t.Helper()
	grants := make([]gameservercommit.JournalGrant, len(objects))
	for i, obj := range objects {
		grants[i] = gameservercommit.JournalGrant{ActorUID: []string{"pod-a", "pod-b"}[i], AttemptID: "attempt-" + obj.Name, Name: obj.Name, UID: string(obj.UID), SourceVersion: obj.ResourceVersion}
	}
	slices.SortFunc(grants, func(a, b gameservercommit.JournalGrant) int {
		if a.UID < b.UID {
			return -1
		}
		if a.UID > b.UID {
			return 1
		}
		return 0
	})
	raw, err := json.Marshal(grants)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-issued-grants/v1\n"), raw...))
	binding := gameservercommit.JournalBinding{GenerationID: "generation-1", GenerationVersion: "source-version-1",
		MemberPodUIDs: []string{"pod-a", "pod-b"}, MemberSetDigest: "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d",
		IncarnationID: "incarnation-1", Namespace: objects[0].Namespace, Fleet: "fleet", IssuedCount: 2, IssuedDigest: hex.EncodeToString(digest[:]), Version: "native-journal-version"}
	doc := map[string]any{"schema": 1, "generation_id": binding.GenerationID, "generation_source_version": binding.GenerationVersion,
		"member_pod_uids": binding.MemberPodUIDs, "member_set_digest": binding.MemberSetDigest, "authority_incarnation": binding.IncarnationID,
		"namespace": binding.Namespace, "fleet": binding.Fleet, "grant_count": binding.IssuedCount, "grant_set_digest": binding.IssuedDigest, "grants": grants}
	encoded, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	identity, err := json.Marshal([]string{binding.GenerationID, binding.IncarnationID})
	if err != nil {
		t.Fatal(err)
	}
	key := sha256.Sum256(append([]byte("world-at-ruin/allocator-grant-journal-key/v1\n"), identity...))
	storage := nakamastoragetest.New()
	storage.Seed(nakamastoragetest.Object{Collection: gameservercommit.JournalCollection, Key: hex.EncodeToString(key[:]), Version: binding.Version, Value: string(encoded)})
	return binding, grants, storage
}

// TestJournalReadbackCannotReplaceNativeFence distinguishes complete journal
// observation from actual storage barriers, including receipt provenance loss
// across a freshly constructed owner with identical generation metadata.
func TestJournalReadbackCannotReplaceNativeFence(t *testing.T) {
	for _, fenced := range []bool{false, true} {
		t.Run(fmt.Sprintf("fenced-%t", fenced), func(t *testing.T) {
			api, objects := resourcePair(t)
			cfg, held := proxyMany(t, "zone", "zone-two")
			owner := nativeGeneration(t, cfg, objects[0].Namespace)
			grants := pairGrants(t, owner, objects)
			done := make([]chan error, len(grants))
			for i, grant := range grants {
				done[i] = make(chan error, 1)
				go func() { done[i] <- grant.Commit(context.Background()) }()
				reached(t, held[objects[i].Name])
			}
			binding, want, storage := storedJournal(t, objects)
			reader, err := gameservercommit.NewJournalReader(gameservercommit.JournalReaderConfig{Enabled: true, Storage: storage, Binding: binding})
			if err != nil {
				t.Fatal(err)
			}
			observed, err := reader.Load(context.Background())
			if err != nil || !reflect.DeepEqual(observed.Binding, binding) || !reflect.DeepEqual(observed.Grants, want) {
				t.Fatalf("native inventory lost: %#v %v", observed, err)
			}
			if len(storage.WriteCalls) != 0 {
				t.Fatal("journal reader performed a storage write")
			}
			for _, fault := range []string{"incarnation", "stale-version", "omitted-expected-set"} {
				other := binding
				switch fault {
				case "incarnation":
					other.IncarnationID = "incarnation-2"
				case "stale-version":
					other.Version = "stale"
				case "omitted-expected-set":
					other.IssuedCount = 1
				}
				refused, err := gameservercommit.NewJournalReader(gameservercommit.JournalReaderConfig{Enabled: true, Storage: storage, Binding: other})
				if err != nil {
					t.Fatal(err)
				}
				if got, err := refused.Load(context.Background()); !errors.Is(err, gameservercommit.ErrUnknown) || len(got.Grants) != 0 {
					t.Fatalf("%s accepted incomplete native inventory: %#v %v", fault, got, err)
				}
			}
			if fenced {
				receipt, err := owner.Fence(context.Background())
				if err != nil {
					t.Fatal(err)
				}
				if _, err := owner.Accept(receipt); err != nil {
					t.Fatal(err)
				}
				restarted := nativeGeneration(t, control, objects[0].Namespace)
				if _, err := restarted.Accept(receipt); !errors.Is(err, gameservercommit.ErrInvalid) {
					t.Fatal("fresh owner recovered old receipt authority from identical metadata")
				}
			}
			for i, obj := range objects {
				h := held[obj.Name]
				h.unblock()
				wantStatus := 200
				if fenced {
					wantStatus = 409
				}
				storedStatus(t, h, wantStatus)
				err := <-done[i]
				if (fenced && !errors.Is(err, gameservercommit.ErrConflict)) || (!fenced && err != nil) {
					t.Fatal(err)
				}
				state := readNamed(t, api, obj.Name)
				if fenced {
					if state.Status.State != agonesv1.GameServerStateReady || state.Annotations[gameservercommit.BarrierAnnotation] == "" {
						t.Fatal("actual barrier did not preserve native Ready state")
					}
				} else if state.Status.State != agonesv1.GameServerStateAllocated {
					t.Fatal("journal readback silently fenced the unfenced positive control")
				}
			}
		})
	}
}
