package nakamajournalprobe

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// journalObjectID pins the public deterministic storage address of this fixture.
const journalObjectID = "c3be3a401178b7bbc9e7df4140309335b7d5f06188f18c7c8dadcd2378e466e8"

type failingStorage struct{ reads int }

func (s *failingStorage) StorageRead(context.Context, []*runtime.StorageRead) ([]*api.StorageObject, error) {
	s.reads++
	return nil, errors.New("private-provider-diagnostic")
}

func TestDefaultProbeNeverReadsOrReports(t *testing.T) {
	t.Setenv("WAR_ALLOCATOR_JOURNAL_PROBE_ENABLED", "true")
	for _, value := range []string{"", "false"} {
		ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_ENV, map[string]string{
			"WAR_ALLOCATOR_JOURNAL_PROBE_ENABLED": value,
			"WAR_ALLOCATOR_JOURNAL_PROBE_BINDING": "malformed",
		})
		storage := &failingStorage{}
		if err := Run(ctx, storage, func(Report) { t.Fatal("disabled probe reported") }); err != nil || storage.reads != 0 {
			t.Fatal("disabled probe inspected dependencies")
		}
	}
}

type replyStorage struct {
	row   *api.StorageObject
	err   error
	reads int
	after func()
}

func (s *replyStorage) StorageRead(_ context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	s.reads++
	if len(reads) != 1 || reads[0].Collection != allocatorjournal.JournalCollection || reads[0].Key != journalObjectID || reads[0].UserID != "" {
		panic("unexpected journal read")
	}
	if s.after != nil {
		s.after()
	}
	return []*api.StorageObject{s.row}, s.err
}

// TestCompleteProbeAndUnknownControls requires a full observation fingerprint,
// while plausible rows beside failure or cancellation never produce a report.
func TestCompleteProbeAndUnknownControls(t *testing.T) {
	raw, err := os.ReadFile("../allocatorjournal/testdata/golden_allocator_grant_journal_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	binding := allocatorjournal.JournalBinding{GenerationID: "generation-1", GenerationVersion: "source-version-1", MemberPodUIDs: []string{"pod-a", "pod-b"}, MemberSetDigest: "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d", IncarnationID: "incarnation-1", Namespace: "trial", Fleet: "fleet", IssuedCount: 2, IssuedDigest: "4febaec6be92e850b2d08dd58cf55bb7e368994f597c35915286be3278f79226", Version: "journal-version-1"}
	expected := allocatorjournal.JournalObservation{Binding: binding, Grants: []allocatorjournal.JournalGrant{
		{ActorUID: "pod-a", AttemptID: "attempt-a", Name: "zone-a", UID: "uid-a", SourceVersion: "resource-a"},
		{ActorUID: "pod-b", AttemptID: "attempt-b", Name: "zone-b", UID: "uid-b", SourceVersion: "resource-b"},
	}}
	encoded, err := json.Marshal(expected)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(encoded)
	for _, fault := range []string{"success", "error-with-row", "canceled-before", "canceled-after", "explicit-canceled", "version"} {
		t.Run(fault, func(t *testing.T) {
			cfg, err := json.Marshal(binding)
			if err != nil {
				t.Fatal(err)
			}
			env := map[string]string{"WAR_ALLOCATOR_JOURNAL_PROBE_ENABLED": "true", "WAR_ALLOCATOR_JOURNAL_PROBE_BINDING": string(cfg)}
			ctx, cancel := context.WithCancel(context.WithValue(context.Background(), runtime.RUNTIME_CTX_ENV, env))
			defer cancel()
			storage := &replyStorage{row: &api.StorageObject{Collection: allocatorjournal.JournalCollection, Key: journalObjectID, UserId: nakamastorage.SystemOwnerID, Version: binding.Version, Value: string(raw)}}
			switch fault {
			case "error-with-row":
				storage.err = errors.New("private-provider-diagnostic")
			case "canceled-before":
				cancel()
			case "canceled-after":
				storage.after = cancel
			case "explicit-canceled":
				env["WAR_ALLOCATOR_JOURNAL_PROBE_CANCEL_READ"] = "true"
			case "version":
				storage.row.Version = "changed-version"
			}
			reports := 0
			err = Run(ctx, storage, func(got Report) {
				reports++
				if got.GrantCount != 2 || got.ObservationSHA256 != hex.EncodeToString(digest[:]) {
					t.Fatal("lossy startup observation")
				}
			})
			if fault == "success" {
				if err != nil || reports != 1 || storage.reads != 1 {
					t.Fatal("complete read did not report")
				}
			} else if err == nil || reports != 0 || strings.Contains(err.Error(), "private-provider") {
				t.Fatal("failed read reported or exposed diagnostics")
			}
		})
	}
}

func TestInvalidProbeNeverReadsOrReports(t *testing.T) {
	for _, value := range []string{"", "null", "{}", "{} {}", strings.Repeat("x", 20000)} {
		ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_ENV, map[string]string{
			"WAR_ALLOCATOR_JOURNAL_PROBE_ENABLED": "true",
			"WAR_ALLOCATOR_JOURNAL_PROBE_BINDING": value,
		})
		storage := &failingStorage{}
		err := Run(ctx, storage, func(Report) { t.Fatal("invalid probe reported") })
		if err == nil || storage.reads != 0 || strings.Contains(err.Error(), "private-provider") {
			t.Fatal("invalid probe reached storage or exposed diagnostics")
		}
	}
}
