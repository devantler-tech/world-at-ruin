package allocatoradmission

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/protobuf/proto"
)

// This interface keeps the first behavioral test executable before the writer
// implements publication. Missing publication fails the assertion, not compilation.
type handoffPublisher interface {
	PublishHandoff(context.Context, *Snapshot) (allocatorjournal.JournalBinding, string, error)
}

func TestHandoffPublicationHasOneSharedDeadline(t *testing.T) {
	s := &handoffStorage{}
	w := handoffWriter(t, s)
	head, e := w.Create(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	head, e = w.Drain(context.Background(), head)
	if e != nil {
		t.Fatal(e)
	}
	if _, _, e = w.PublishHandoff(context.Background(), head); e != nil {
		t.Fatal(e)
	}
	if s.deadline.IsZero() || time.Until(s.deadline) > 30*time.Second || time.Until(s.deadline) <= 0 {
		t.Fatal("handoff publication has no bounded storage deadline")
	}
}

func handoffWriter(t *testing.T, s Storage) *Writer {
	t.Helper()
	w, err := NewWriter(Config{Enabled: true, Storage: s, Journal: initial(t)})
	if err != nil {
		t.Fatal(err)
	}
	return w
}

func TestHandoffUnknownRepliesNeverExportOrRetry(t *testing.T) {
	for _, fault := range []string{"lost", "partial", "wrong-key", "wrong-owner", "wildcard", "missing", "cancel"} {
		t.Run(fault, func(t *testing.T) {
			s := &handoffStorage{fault: fault}
			w := handoffWriter(t, s)
			head, err := w.Create(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			head, err = w.Drain(context.Background(), head)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if fault == "cancel" {
				s.cancel = cancel
			}
			b, v, err := w.PublishHandoff(ctx, head)
			if !errors.Is(err, ErrUnknown) || v != "" || b.Version != "" || s.handoff == nil {
				t.Fatalf("ambiguous publication exported pins: %+v %s %v", b, v, err)
			}
			if fault == "cancel" && !errors.Is(err, context.Canceled) {
				t.Fatal("cancellation lost")
			}
			if _, v, err = w.PublishHandoff(context.Background(), head); v != "" || err == nil || s.handoffCalls != 1 {
				t.Fatal("ambiguous publication retried")
			}
		})
	}
}
func TestHandoffPublicationHasOneAttemptAcrossCallers(t *testing.T) {
	s := &handoffStorage{}
	w := handoffWriter(t, s)
	head, err := w.Create(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	head, err = w.Drain(context.Background(), head)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var successes atomic.Int32
	for range 20 {
		wg.Go(func() {
			_, v, err := w.PublishHandoff(context.Background(), head)
			if err == nil && v != "" {
				successes.Add(1)
			}
		})
	}
	wg.Wait()
	if successes.Load() != 1 || s.handoffCalls != 1 {
		t.Fatal("publication attempted more than once")
	}
}

type handoffReadStorage struct {
	*handoffStorage
	reads int
	fault string
}

func (s *handoffReadStorage) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	s.reads++
	if len(reads) != 1 {
		return nil, ErrUnknown
	}
	var source *api.StorageObject
	switch reads[0].Collection {
	case HandoffCollection:
		source = s.handoff
	case Collection:
		source = s.row
	default:
		return nil, ErrUnknown
	}
	if source == nil {
		return nil, nil
	}
	got, ok := proto.Clone(source).(*api.StorageObject)
	if !ok {
		return nil, ErrUnknown
	}
	if s.fault == "partial" {
		return []*api.StorageObject{got}, ErrUnknown
	}
	if s.fault == "owner" {
		got.UserId = "foreign"
	}
	if s.fault == "permission" {
		got.PermissionRead = 1
	}
	if s.fault == "key" {
		got.Key = "replacement"
	}
	if s.fault == "version" {
		got.Version = "changed"
	}
	return []*api.StorageObject{got}, ctx.Err()
}
func handoffFixture(t *testing.T) (*handoffReadStorage, HandoffReadConfig) {
	t.Helper()
	s := &handoffStorage{}
	w := handoffWriter(t, s)
	head, e := w.Create(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	head, e = w.Register(context.Background(), head, grantA)
	if e != nil {
		t.Fatal(e)
	}
	head, e = w.Register(context.Background(), head, grantB)
	if e != nil {
		t.Fatal(e)
	}
	head, e = w.Drain(context.Background(), head)
	if e != nil {
		t.Fatal(e)
	}
	b, v, e := w.PublishHandoff(context.Background(), head)
	if e != nil {
		t.Fatal(e)
	}
	read := &handoffReadStorage{handoffStorage: s}
	return read, HandoffReadConfig{Enabled: true, Storage: read, Binding: b, Version: v}
}
func TestFreshHandoffReadPinsBothOriginalDocuments(t *testing.T) {
	s, cfg := handoffFixture(t)
	got, e := ReadHandoff(context.Background(), cfg)
	if e != nil || got.Phase != "draining" || got.Journal.Binding.Version != "v4" || len(got.Journal.Grants) != 2 || got.Journal.Grants[0] != grantA || got.Journal.Grants[1] != grantB || s.reads != 2 {
		t.Fatalf("complete independent readback: %+v %v", got, e)
	}
	got.Journal.Grants[0].UID = "mutated"
	again, e := ReadHandoff(context.Background(), cfg)
	if e != nil || again.Journal.Grants[0] != grantA {
		t.Fatal("reader result aliases source")
	}
	for _, fault := range []string{"partial", "owner", "permission", "key", "version", "missing-handoff", "missing-root", "changed-root", "stale-pin", "omitted-inventory", "identity", "canceled"} {
		t.Run(fault, func(t *testing.T) {
			s, cfg := handoffFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch fault {
			case "missing-handoff":
				s.handoff = nil
			case "missing-root":
				s.row = nil
			case "changed-root":
				s.row.Version = "root-replaced"
			case "stale-pin":
				cfg.Version = "unacknowledged"
			case "omitted-inventory":
				// This is a valid independently encoded empty inventory, not malformed JSON.
				j, e := allocatorjournal.DecodeJournal(initial(t))
				if e != nil {
					t.Fatal(e)
				}
				j.Binding.Version = cfg.Binding.Version
				value, e := encodeHandoff(Observation{Phase: "draining", Journal: j})
				if e != nil {
					t.Fatal(e)
				}
				s.handoff.Value = value
			case "identity":
				cfg.Binding.IncarnationID = "replacement"
			case "canceled":
				cancel()
			default:
				s.fault = fault
			}
			got, e := ReadHandoff(ctx, cfg)
			if !errors.Is(e, ErrUnknown) || got.Phase != "" {
				t.Fatal("unknown input returned inventory")
			}
		})
	}
	disabled := HandoffReadConfig{Storage: s}
	if _, e := ReadHandoff(context.Background(), disabled); !errors.Is(e, ErrDisabled) || s.reads != 4 {
		t.Fatal("disabled reader accessed storage")
	}
}
func TestHandoffKeepsEveryShippedSchemaReadable(t *testing.T) {
	raw, e := os.ReadFile("testdata/golden_allocator_recovery_handoff_v1.json")
	if e != nil {
		t.Fatal(e)
	}
	got, e := decodeHandoff(string(raw))
	if e != nil {
		t.Fatal(e)
	}
	b := got.Journal.Binding
	if got.Phase != "draining" || b.Version != "root-version-4" || b.GenerationID != "generation-1" || b.GenerationVersion != "source-version-1" || b.IncarnationID != "incarnation-1" || b.Namespace != "trial" || b.Fleet != "fleet" || b.MemberSetDigest != "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d" || len(b.MemberPodUIDs) != 2 || b.MemberPodUIDs[0] != "pod-a" || b.MemberPodUIDs[1] != "pod-b" || b.IssuedCount != 2 || b.IssuedDigest != "4febaec6be92e850b2d08dd58cf55bb7e368994f597c35915286be3278f79226" || len(got.Journal.Grants) != 2 || got.Journal.Grants[0] != grantA || got.Journal.Grants[1] != grantB {
		t.Fatalf("historical handoff fields lost: %+v", got)
	}
}
func TestHandoffRejectsAmbiguousHistoricalDocuments(t *testing.T) {
	raw, e := os.ReadFile("testdata/golden_allocator_recovery_handoff_v1.json")
	if e != nil {
		t.Fatal(e)
	}
	for _, value := range []string{
		strings.Replace(string(raw), "\"schema\": 1", "\"schema\": 2", 1),
		strings.Replace(string(raw), "\"schema\": 1", "\"schema\": 1, \"schema\": 1", 1),
		strings.Replace(string(raw), "\"admission_version\": \"root-version-4\"", "\"admission_version\": null", 1),
		strings.Replace(string(raw), "\"admission_version\": \"root-version-4\"", "\"admission_version\": \"*\"", 1),
		strings.Replace(string(raw), "\"phase\": \"draining\"", "\"phase\": \"open\"", 1),
		strings.Replace(string(raw), "\"schema\": 1", "\"schema\": 1, \"unknown\":true", 1),
		string(raw) + "{}", string([]byte{0xff}),
	} {
		if got, e := decodeHandoff(value); e == nil || got.Phase != "" {
			t.Fatal("ambiguous handoff accepted")
		}
	}
}

type handoffStorage struct {
	storage
	handoffMu    sync.Mutex
	handoff      *api.StorageObject
	handoffCalls int
	fault        string
	cancel       context.CancelFunc
	deadline     time.Time
}

func (s *handoffStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	if len(writes) != 1 || writes[0].Collection == "world_at_ruin_allocator_admissions" {
		return s.storage.StorageWrite(ctx, writes)
	}
	s.handoffMu.Lock()
	defer s.handoffMu.Unlock()
	s.handoffCalls++
	s.deadline, _ = ctx.Deadline()
	w := writes[0]
	if ctx.Err() != nil || w.Collection != "world_at_ruin_allocator_recovery_handoffs" || w.UserID != "" || w.PermissionRead != 0 || w.PermissionWrite != 0 || w.Version != "*" || w.Key == "" || s.handoff != nil {
		return nil, errors.New("private create-only handoff refused")
	}
	s.handoff = &api.StorageObject{Collection: w.Collection, Key: w.Key, UserId: "00000000-0000-0000-0000-000000000000", Value: w.Value, Version: "handoff-ack-1"}
	ack := &api.StorageObjectAck{Collection: w.Collection, Key: w.Key, UserId: s.handoff.GetUserId(), Version: s.handoff.GetVersion()}
	if s.cancel != nil {
		s.cancel()
	}
	switch s.fault {
	case "lost":
		return nil, errors.New("handoff reply lost after commit")
	case "partial":
		return []*api.StorageObjectAck{ack}, errors.New("plausible partial acknowledgment")
	case "wrong-key":
		ack.Key = "replacement"
	case "wrong-owner":
		ack.UserId = "foreign"
	case "wildcard":
		ack.Version = "*"
	case "missing":
		return nil, nil
	}
	return []*api.StorageObjectAck{ack}, nil
}

func publication(t *testing.T, w *Writer) handoffPublisher {
	t.Helper()
	p, ok := any(w).(handoffPublisher)
	if !ok {
		t.Fatal("writer cannot retain an acknowledged private draining handoff")
	}
	return p
}

// Removing provenance/phase checks would allow public observations or an open
// root to manufacture a recovery handoff. Refreshing a version would change
// the original acknowledged draining inventory asserted here.
func TestHandoffRequiresAcknowledgedPrivateDrain(t *testing.T) {
	ctx := context.Background()
	s := &handoffStorage{}
	w, err := NewWriter(Config{Enabled: true, Storage: s, Journal: initial(t)})
	if err != nil {
		t.Fatal(err)
	}
	p := publication(t, w)
	head, err := w.Create(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, version, err := p.PublishHandoff(ctx, head); version != "" || !errors.Is(err, ErrClosed) || s.handoffCalls != 0 {
		t.Fatal("open root published a handoff")
	}
	head, err = w.Register(ctx, head, grantB)
	if err != nil {
		t.Fatal(err)
	}
	head, err = w.Register(ctx, head, grantA)
	if err != nil {
		t.Fatal(err)
	}
	head, err = w.Drain(ctx, head)
	if err != nil {
		t.Fatal(err)
	}
	other, err := NewWriter(Config{Enabled: true, Storage: s, Journal: initial(t)})
	if err != nil {
		t.Fatal(err)
	}
	if _, version, err := publication(t, other).PublishHandoff(ctx, head); version != "" || !errors.Is(err, ErrClosed) || s.handoffCalls != 0 {
		t.Fatal("foreign writer restored private drain provenance")
	}
	if _, version, err := p.PublishHandoff(ctx, &Snapshot{observation: head.Observation()}); version != "" || !errors.Is(err, ErrClosed) || s.handoffCalls != 0 {
		t.Fatal("diagnostic observation restored drain provenance")
	}
	binding, version, err := p.PublishHandoff(ctx, head)
	if err != nil || version != "handoff-ack-1" || binding.Version != "v4" || binding.IssuedCount != 2 || binding.IssuedDigest != "4febaec6be92e850b2d08dd58cf55bb7e368994f597c35915286be3278f79226" {
		t.Fatalf("acknowledged handoff: %+v %s %v", binding, version, err)
	}
	var value struct {
		Schema           int    `json:"schema"`
		AdmissionVersion string `json:"admission_version"`
		Admission        struct {
			Phase   string          `json:"phase"`
			Journal json.RawMessage `json:"journal"`
		} `json:"admission"`
	}
	if json.Unmarshal([]byte(s.handoff.GetValue()), &value) != nil || value.Schema != 1 || value.AdmissionVersion != "v4" || value.Admission.Phase != "draining" {
		t.Fatal("handoff did not retain original acknowledged drain")
	}
	j, err := allocatorjournal.DecodeJournal(string(value.Admission.Journal))
	if err != nil || len(j.Grants) != 2 || j.Grants[0] != grantA || j.Grants[1] != grantB {
		t.Fatal("complete original inventory not retained")
	}
	binding.MemberPodUIDs[0] = "mutated"
	if head.Observation().Journal.Binding.MemberPodUIDs[0] != "pod-a" {
		t.Fatal("handoff reference aliases private snapshot")
	}
	if _, version, err := p.PublishHandoff(ctx, head); version != "" || !errors.Is(err, ErrClosed) || s.handoffCalls != 1 {
		t.Fatal("handoff publication retried")
	}
}
