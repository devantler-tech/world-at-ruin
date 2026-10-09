package gameservercommit

import (
	"context"
	"errors"
	"os"
	"reflect"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const journalFixtureAddress = "c3be3a401178b7bbc9e7df4140309335b7d5f06188f18c7c8dadcd2378e466e8"

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
	return &api.StorageObject{Collection: JournalCollection, Key: journalFixtureAddress, UserId: nakamastorage.SystemOwnerID,
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
	decoded, decodeErr := decodeJournal(journalJSON(t))
	decoded.Binding.Version = want.Binding.Version
	if decodeErr != nil || !reflect.DeepEqual(decoded, want) {
		t.Fatal("compatibility decoder lost historical fields")
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("lossy journal: %#v %v", got, err)
	}
	if len(storage.reads) != 1 || storage.reads[0].Collection != JournalCollection || storage.reads[0].Key != journalFixtureAddress || storage.reads[0].UserID != "" {
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

func TestJournalCompatibilityErrors(t *testing.T) {
	for _, fault := range []error{errors.New("private storage failure"), context.Canceled, context.DeadlineExceeded} {
		storage := &journalReply{err: fault}
		reader, err := NewJournalReader(JournalReaderConfig{Enabled: true, Storage: storage, Binding: journalBinding()})
		if err != nil {
			t.Fatal(err)
		}
		got, err := reader.Load(context.Background())
		if !errors.Is(err, ErrUnknown) || !reflect.DeepEqual(got, JournalObservation{}) {
			t.Fatal("compatibility error changed")
		}
		if errors.Is(fault, context.Canceled) || errors.Is(fault, context.DeadlineExceeded) {
			if !errors.Is(err, fault) {
				t.Fatal("caller cancellation identity lost")
			}
		}
	}
	if _, err := NewJournalReader(JournalReaderConfig{Enabled: true}); !errors.Is(err, ErrInvalid) {
		t.Fatal("invalid construction identity lost")
	}
}
