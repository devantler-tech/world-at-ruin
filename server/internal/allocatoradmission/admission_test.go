package allocatoradmission

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/protobuf/proto"
)

// This double models only the external storage CAS; native tests bind that
// assumption to the pinned runtime, while these tests exercise our writer.
type storage struct {
	mu         sync.Mutex
	row        *api.StorageObject
	calls      int
	fault      string
	readFault  string
	cancelRead context.CancelFunc
}

func (s *storage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if len(writes) != 1 {
		return nil, errors.New("one root required")
	}
	w := writes[0]
	if w.Collection != "world_at_ruin_allocator_admissions" || w.UserID != "" || w.PermissionRead != 0 || w.PermissionWrite != 0 || w.Key == "" || w.Version == "" {
		return nil, errors.New("private conditional root required")
	}
	if (w.Version == "*" && s.row != nil) || (w.Version != "*" && (s.row == nil || s.row.GetVersion() != w.Version)) {
		return nil, errors.New("CAS rejected")
	}
	s.row = &api.StorageObject{Collection: w.Collection, Key: w.Key, UserId: "00000000-0000-0000-0000-000000000000", Value: w.Value, Version: fmt.Sprintf("v%d", s.calls)}
	ack := &api.StorageObjectAck{Collection: w.Collection, Key: w.Key, UserId: s.row.GetUserId(), Version: s.row.GetVersion()}
	switch s.fault {
	case "lost":
		return nil, errors.New("reply lost after commit")
	case "partial":
		return []*api.StorageObjectAck{ack}, errors.New("partial reply")
	case "missing":
		return nil, nil
	case "wrong-key":
		ack.Key = "substitution"
	case "empty-version":
		ack.Version = ""
	case "wildcard":
		ack.Version = "*"
	case "public-owner":
		ack.UserId = "foreign"
	}
	return []*api.StorageObjectAck{ack}, nil
}
func (s *storage) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if len(reads) != 1 || reads[0].Collection != "world_at_ruin_allocator_admissions" || reads[0].UserID != "" {
		return nil, errors.New("private read required")
	}
	if s.row == nil || reads[0].Key != s.row.GetKey() {
		return nil, nil
	}
	copy, ok := proto.Clone(s.row).(*api.StorageObject)
	if !ok {
		return nil, errors.New("invalid storage row clone")
	}
	if s.cancelRead != nil {
		s.cancelRead()
	}
	if s.readFault == "partial" {
		return []*api.StorageObject{copy}, errors.New("plausible row before failure")
	}
	return []*api.StorageObject{copy}, nil
}
func initial(t *testing.T) string {
	t.Helper()
	b, e := os.ReadFile("testdata/empty.json")
	if e != nil {
		t.Fatal(e)
	}
	return string(b)
}
func writer(t *testing.T, s *storage) *Writer {
	t.Helper()
	w, e := NewWriter(Config{Enabled: true, Storage: s, Journal: initial(t)})
	if e != nil {
		t.Fatal(e)
	}
	return w
}

var grantA = allocatorjournal.JournalGrant{ActorUID: "pod-a", AttemptID: "attempt-a", Name: "zone-a", UID: "uid-a", SourceVersion: "resource-a"}
var grantB = allocatorjournal.JournalGrant{ActorUID: "pod-b", AttemptID: "attempt-b", Name: "zone-b", UID: "uid-b", SourceVersion: "resource-b"}

func TestDisabledWriterCannotTouchDependencies(t *testing.T) {
	s := &storage{}
	if w, e := NewWriter(Config{Storage: s, Journal: "not JSON"}); w != nil || !errors.Is(e, ErrDisabled) || s.calls != 0 {
		t.Fatalf("disabled writer: %v %v", w, e)
	}
}
func TestRegisterAndDrainPersistCompleteSet(t *testing.T) {
	s := &storage{}
	w := writer(t, s)
	head, e := w.Create(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	head, e = w.Register(context.Background(), head, grantB)
	if e != nil {
		t.Fatal(e)
	}
	head, e = w.Register(context.Background(), head, grantA)
	if e != nil {
		t.Fatal(e)
	}
	head, e = w.Drain(context.Background(), head)
	if e != nil {
		t.Fatal(e)
	}
	got := head.Observation()
	if got.Phase != "draining" || got.Journal.Binding.IssuedCount != 2 || got.Journal.Binding.IssuedDigest != "4febaec6be92e850b2d08dd58cf55bb7e368994f597c35915286be3278f79226" || got.Journal.Grants[0] != grantA || got.Journal.Grants[1] != grantB {
		t.Fatalf("complete frozen set: %+v", got)
	}
	if next, e := w.Register(context.Background(), head, grantA); next != nil || !errors.Is(e, ErrClosed) || s.calls != 4 {
		t.Fatalf("drain reopened: %v %v calls=%d", next, e, s.calls)
	}
	got.Journal.Grants[0].UID = "tampered"
	got.Journal.Binding.MemberPodUIDs[0] = "tampered"
	if head.Observation().Journal.Grants[0] != grantA || head.Observation().Journal.Binding.MemberPodUIDs[0] != "pod-a" {
		t.Fatal("snapshot aliases writer state")
	}
	binding := head.Observation().Journal.Binding
	read, e := Read(context.Background(), s, binding, "draining")
	if e != nil || len(read.Journal.Grants) != 2 {
		t.Fatalf("exact readback: %+v %v", read, e)
	}
	binding.Version = "stale"
	if got, e := Read(context.Background(), s, binding, "draining"); e == nil || got.Phase != "" {
		t.Fatal("stale read returned observation")
	}
}
func TestGenerationKeyArbitratesDifferentIncarnations(t *testing.T) {
	s := &storage{}
	a := writer(t, s)
	b, e := NewWriter(Config{Enabled: true, Storage: s, Journal: strings.Replace(initial(t), "incarnation-1", "incarnation-2", 1)})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = a.Create(context.Background()); e != nil {
		t.Fatal(e)
	}
	if got, e := b.Create(context.Background()); e == nil || got != nil {
		t.Fatal("second incarnation created another authority root")
	}
	if s.calls != 2 {
		t.Fatal("contender did not reach shared CAS")
	}
}
func TestStaleSnapshotCannotOverwriteDrain(t *testing.T) {
	s := &storage{}
	w := writer(t, s)
	old, e := w.Create(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	closed, e := w.Drain(context.Background(), old)
	if e != nil {
		t.Fatal(e)
	}
	if got, e := w.Register(context.Background(), old, grantA); got != nil || !errors.Is(e, ErrUnknown) {
		t.Fatal("stale registration overwrote drain")
	}
	if got, e := w.Create(context.Background()); got != nil || e == nil {
		t.Fatal("writer reopened after rejected transition")
	}
	if closed.Observation().Phase != "draining" || s.calls != 3 {
		t.Fatalf("unexpected state or retry: %d", s.calls)
	}
}
func TestUnknownAcknowledgmentNeverReturnsSnapshotOrRetries(t *testing.T) {
	for _, fault := range []string{"lost", "partial", "missing", "wrong-key", "empty-version", "wildcard", "public-owner"} {
		t.Run(fault, func(t *testing.T) {
			s := &storage{fault: fault}
			w := writer(t, s)
			if got, e := w.Create(context.Background()); got != nil || !errors.Is(e, ErrUnknown) {
				t.Fatal("unknown write returned successful snapshot")
			}
			if s.row == nil {
				t.Fatal("fault did not model committed write")
			}
			if got, e := w.Create(context.Background()); got != nil || e == nil || s.calls != 1 {
				t.Fatal("ambiguous create was retried")
			}
		})
	}
}
func TestCanceledAndInvalidInputDoNotWrite(t *testing.T) {
	s := &storage{}
	w := writer(t, s)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got, e := w.Create(ctx); got != nil || e == nil || s.calls != 0 {
		t.Fatal("canceled create wrote")
	}
	s = &storage{}
	w = writer(t, s)
	head, e := w.Create(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	invalid := grantA
	invalid.ActorUID = "not-member"
	if got, e := w.Register(context.Background(), head, invalid); got != nil || e == nil || s.calls != 1 {
		t.Fatal("unattributed grant persisted")
	}
	foreign := writer(t, &storage{})
	if got, e := foreign.Drain(context.Background(), head); got != nil || e == nil {
		t.Fatal("foreign writer used snapshot")
	}
}
func TestAdmissionKeepsEveryShippedSchemaReadable(t *testing.T) {
	raw, e := os.ReadFile("testdata/golden_allocator_admission_v1.json")
	if e != nil {
		t.Fatal(e)
	}
	got, e := decodeAdmission(string(raw))
	if e != nil {
		t.Fatal(e)
	}
	if got.Phase != "draining" || got.Journal.Binding.GenerationID != "generation-1" || got.Journal.Binding.GenerationVersion != "source-version-1" || got.Journal.Binding.IncarnationID != "incarnation-1" || got.Journal.Binding.Namespace != "trial" || got.Journal.Binding.Fleet != "fleet" || got.Journal.Binding.MemberSetDigest != "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d" || len(got.Journal.Binding.MemberPodUIDs) != 2 || got.Journal.Binding.MemberPodUIDs[0] != "pod-a" || got.Journal.Binding.MemberPodUIDs[1] != "pod-b" || got.Journal.Binding.IssuedCount != 2 || got.Journal.Binding.IssuedDigest != "4febaec6be92e850b2d08dd58cf55bb7e368994f597c35915286be3278f79226" || len(got.Journal.Grants) != 2 || got.Journal.Grants[0] != grantA || got.Journal.Grants[1] != grantB {
		t.Fatalf("historical fields lost: %+v", got)
	}
}
func TestAdmissionRejectsAmbiguousDocuments(t *testing.T) {
	raw, e := os.ReadFile("testdata/golden_allocator_admission_v1.json")
	if e != nil {
		t.Fatal(e)
	}
	for _, value := range []string{strings.Replace(string(raw), "\"schema\": 1", "\"schema\": 2", 1), strings.Replace(string(raw), "\"phase\": \"draining\"", "\"phase\": \"closed\"", 1), strings.Replace(string(raw), "\"schema\": 1", "\"schema\": 1, \"schema\": 1", 1), strings.Replace(string(raw), "\"phase\": \"draining\"", "\"phase\": null", 1), strings.Replace(string(raw), "\"phase\": \"draining\"", "\"phase\": \"draining\", \"extra\": true", 1), string(raw) + "{}"} {
		if got, e := decodeAdmission(value); e == nil || got.Phase != "" {
			t.Fatal("ambiguous document accepted")
		}
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		t.Fatal("fixture")
	}
	delete(fields, "phase")
	missing, _ := json.Marshal(fields)
	if _, e := decodeAdmission(string(missing)); e == nil {
		t.Fatal("missing phase accepted")
	}
}

func TestRegisterRejectsLossyIdentityBeforeEncoding(t *testing.T) {
	for _, field := range []string{"uid", "source-version"} {
		t.Run(field, func(t *testing.T) {
			s := &storage{}
			w := writer(t, s)
			head, e := w.Create(context.Background())
			if e != nil {
				t.Fatal(e)
			}
			bad := grantA
			if field == "uid" {
				bad.UID = string([]byte{0xff})
			} else {
				bad.SourceVersion = string([]byte{0xff})
			}
			if got, e := w.Register(context.Background(), head, bad); got != nil || e == nil || s.calls != 1 {
				t.Fatal("lossy identity persisted or returned")
			}
		})
	}
	s := &storage{}
	w := writer(t, s)
	head, e := w.Create(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	literal := grantA
	literal.UID = "\ufffd"
	head, e = w.Register(context.Background(), head, literal)
	if e != nil || head.Observation().Journal.Grants[0].UID != "\ufffd" {
		t.Fatal("literal valid UTF-8 identity changed")
	}
}

func TestRegisterRejectsActorAliasBeforeEncoding(t *testing.T) {
	s := &storage{}
	value := strings.Replace(initial(t), "pod-b", "pod-\ufffd", 1)
	value = strings.Replace(value, "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d", "1b18aec2e73007bb3ea90d18bcdcf7953c281bf998292c841e9f04a72a2be7d9", 1)
	w, e := NewWriter(Config{Enabled: true, Storage: s, Journal: value})
	if e != nil {
		t.Fatal(e)
	}
	head, e := w.Create(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	bad := grantA
	bad.ActorUID = "pod-" + string([]byte{0xff})
	if got, e := w.Register(context.Background(), head, bad); got != nil || e == nil || s.calls != 1 {
		t.Fatal("lossy actor aliased a valid generation member")
	}
	bad.ActorUID = "pod-\ufffd"
	if got, e := w.Register(context.Background(), head, bad); e != nil || got.Observation().Journal.Grants[0].ActorUID != "pod-\ufffd" {
		t.Fatal("literal valid actor refused or changed")
	}
}
func TestDrainEmptySetIsExplicit(t *testing.T) {
	s := &storage{}
	w := writer(t, s)
	head, e := w.Create(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	head, e = w.Drain(context.Background(), head)
	if e != nil {
		t.Fatal(e)
	}
	got := head.Observation()
	if got.Phase != "draining" || got.Journal.Binding.IssuedCount != 0 || got.Journal.Binding.IssuedDigest != "fa56417bc7a979772aba3d458f0b5ff22a3462f45e74483a79859c7942fe60ef" || got.Journal.Grants == nil || len(got.Journal.Grants) != 0 {
		t.Fatal("zero-grant closure incomplete")
	}
}
func TestLostTransitionAcknowledgmentPoisonsFurtherWrites(t *testing.T) {
	for _, operation := range []string{"register", "drain"} {
		t.Run(operation, func(t *testing.T) {
			s := &storage{}
			w := writer(t, s)
			head, e := w.Create(context.Background())
			if e != nil {
				t.Fatal(e)
			}
			s.fault = "lost"
			var next *Snapshot
			if operation == "register" {
				next, e = w.Register(context.Background(), head, grantA)
			} else {
				next, e = w.Drain(context.Background(), head)
			}
			if next != nil || !errors.Is(e, ErrUnknown) {
				t.Fatal("lost transition reply returned success")
			}
			if _, e = w.Drain(context.Background(), head); e == nil || s.calls != 2 {
				t.Fatal("poisoned writer retried")
			}
			got, e := decodeAdmission(s.row.GetValue())
			if e != nil {
				t.Fatal(e)
			}
			if operation == "register" && len(got.Journal.Grants) != 1 {
				t.Fatal("lost registration did not persist conservative entry")
			}
			if operation == "drain" && got.Phase != "draining" {
				t.Fatal("lost drain did not persist closure")
			}
		})
	}
}

// Hold a winning reply until the competing real CAS has been rejected. The
// successful storage side effect must not revive a writer poisoned meanwhile.
type heldAck struct {
	inner            *storage
	entered, release chan struct{}
}

func (s *heldAck) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	acks, e := s.inner.StorageWrite(ctx, writes)
	if e == nil && writes[0].Version != "*" {
		close(s.entered)
		select {
		case <-s.release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return acks, e
}
func TestLateWinningReplyCannotRevivePoisonedWriter(t *testing.T) {
	s := &storage{}
	boundary := &heldAck{inner: s, entered: make(chan struct{}), release: make(chan struct{})}
	w, e := NewWriter(Config{Enabled: true, Storage: boundary, Journal: initial(t)})
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	head, e := w.Create(ctx)
	if e != nil {
		t.Fatal(e)
	}
	done := make(chan error, 1)
	go func() {
		got, e := w.Register(ctx, head, grantA)
		if got != nil {
			done <- errors.New("late reply returned snapshot")
		} else {
			done <- e
		}
	}()
	select {
	case <-boundary.entered:
	case <-ctx.Done():
		t.Fatal("registration never reached committed storage")
	}
	if got, e := w.Drain(ctx, head); got != nil || !errors.Is(e, ErrUnknown) {
		t.Fatal("competing drain overwrote registration")
	}
	close(boundary.release)
	if e := <-done; !errors.Is(e, ErrUnknown) {
		t.Fatalf("late winner: %v", e)
	}
	if got, e := w.Register(ctx, head, grantB); got != nil || e == nil || s.calls != 3 {
		t.Fatal("poisoned writer performed another write")
	}
	observation, e := decodeAdmission(s.row.GetValue())
	if e != nil || observation.Phase != "open" || len(observation.Journal.Grants) != 1 || observation.Journal.Grants[0] != grantA {
		t.Fatal("race lost conservative durable entry")
	}
}
func TestReadRefusesPartialPublicAndConflictingEvidence(t *testing.T) {
	for _, fault := range []string{"partial", "canceled", "public-read", "public-write", "foreign-owner", "wrong-phase", "wrong-incarnation", "wrong-count", "wrong-digest", "wrong-source"} {
		t.Run(fault, func(t *testing.T) {
			s := &storage{}
			w := writer(t, s)
			head, e := w.Create(context.Background())
			if e != nil {
				t.Fatal(e)
			}
			binding := head.Observation().Journal.Binding
			phase := "open"
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch fault {
			case "partial":
				s.readFault = fault
			case "canceled":
				s.cancelRead = cancel
			case "public-read":
				s.row.PermissionRead = 1
			case "public-write":
				s.row.PermissionWrite = 1
			case "foreign-owner":
				s.row.UserId = "foreign"
			case "wrong-phase":
				phase = "draining"
			case "wrong-incarnation":
				binding.IncarnationID = "another"
			case "wrong-count":
				binding.IssuedCount = 1
			case "wrong-digest":
				binding.IssuedDigest = strings.Repeat("0", 64)
			case "wrong-source":
				binding.GenerationVersion = "another"
			}
			got, e := Read(ctx, s, binding, phase)
			if e == nil || got.Phase != "" || got.Journal.Grants != nil {
				t.Fatal("incomplete read returned partial observation")
			}
			if fault == "canceled" && !errors.Is(e, context.Canceled) {
				t.Fatal("caller cancellation lost")
			}
		})
	}
}
func TestDuplicateAndOversizedRegistrationsDoNotWrite(t *testing.T) {
	for _, field := range []string{"uid", "name"} {
		t.Run(field, func(t *testing.T) {
			s := &storage{}
			w := writer(t, s)
			head, e := w.Create(context.Background())
			if e != nil {
				t.Fatal(e)
			}
			head, e = w.Register(context.Background(), head, grantA)
			if e != nil {
				t.Fatal(e)
			}
			bad := grantB
			if field == "uid" {
				bad.UID = grantA.UID
			} else {
				bad.Name = grantA.Name
			}
			if got, e := w.Register(context.Background(), head, bad); got != nil || e == nil || s.calls != 2 {
				t.Fatal("duplicate target persisted")
			}
		})
	}
	s := &storage{}
	w := writer(t, s)
	head, e := w.Create(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	for i := range 256 {
		grant := grantA
		grant.UID = fmt.Sprintf("uid-%03d", i)
		grant.Name = fmt.Sprintf("zone-%03d", i)
		head, e = w.Register(context.Background(), head, grant)
		if e != nil {
			t.Fatalf("bounded registration %d: %v", i, e)
		}
	}
	extra := grantA
	extra.UID = "uid-256"
	extra.Name = "zone-256"
	if got, e := w.Register(context.Background(), head, extra); got != nil || e == nil || s.calls != 257 {
		t.Fatal("257th grant persisted")
	}
}

func TestOrdinaryPluginCannotComposeAdmissionWriter(t *testing.T) {
	for _, tags := range []string{"", "war_native_trial"} {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		cmd := exec.CommandContext(ctx, "go", "list", "-mod=readonly", "-tags=", "-deps", "./cmd/nakama")
		if tags != "" {
			cmd = exec.CommandContext(ctx, "go", "list", "-mod=readonly", "-tags=war_native_trial", "-deps", "./cmd/nakama")
		}
		cmd.Dir = filepath.Join("..", "..")
		out, e := cmd.CombinedOutput()
		cancel()
		if e != nil {
			t.Fatalf("complete composition unavailable: %v %s", e, out)
		}
		for _, pkg := range []string{"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission", "github.com/devantler-tech/world-at-ruin/server/internal/nakamaadmissionprobe"} {
			present := slices.Contains(strings.Fields(string(out)), pkg)
			if present != (tags != "") {
				t.Fatalf("admission package %s present=%t tags=%q", pkg, present, tags)
			}
		}
	}
}
