package gameservercommit

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// The double holds an acknowledged storage transaction after CAS commit. The
// generation and HTTP mutation path remain real; native trials cover storage.
type durableStorage struct {
	*nakamastoragetest.Fake
	holdVersion string
	entered     chan struct{}
	release     chan struct{}
}

func (s *durableStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	acks, err := s.Fake.StorageWrite(ctx, writes)
	if err == nil && len(acks) == 1 && acks[0].GetVersion() == s.holdVersion {
		close(s.entered)
		select {
		case <-s.release:
		case <-time.After(3 * time.Second):
			return nil, errors.New("test registration reply exceeded bound")
		}
	}
	return acks, err
}

func durableFixture(t *testing.T, storage allocatoradmission.Storage, handler http.HandlerFunc) *Generation {
	t.Helper()
	_, cfg := generationFixture(t, handler)
	g, err := NewDurableGeneration(context.Background(), DurableGenerationConfig{
		Enabled: true, Commit: cfg.Commit, Record: cfg.Record,
		IncarnationID: "incarnation-1", Storage: storage,
	})
	if err != nil {
		t.Fatalf("enabled durable owner unavailable: %v", err)
	}
	return g
}

func durableRow(t *testing.T, storage *nakamastoragetest.Fake) struct {
	Phase   string
	Journal json.RawMessage
} {
	t.Helper()
	row, ok := storage.Get("world_at_ruin_allocator_admissions", "bccfcc5493d974e057fe04530eec857e7306c572868ce55c76016a12cf989fdc", "")
	if !ok || row.PermissionRead != 0 || row.PermissionWrite != 0 || row.UserID != "00000000-0000-0000-0000-000000000000" {
		t.Fatal("private generation-wide root missing")
	}
	var got struct {
		Phase   string
		Journal json.RawMessage
	}
	if err := json.Unmarshal([]byte(row.Value), &got); err != nil {
		t.Fatal(err)
	}
	return got
}

// Removing durable registration, using a second GET, or returning the wrapper
// before its acknowledgment must break this storage/exposure ordering test.
func TestDurablePreparationWaitsForCommittedRegistration(t *testing.T) {
	s := &durableStorage{Fake: nakamastoragetest.New(), holdVersion: "v2", entered: make(chan struct{}), release: make(chan struct{})}
	t.Cleanup(func() {
		select {
		case <-s.release:
		default:
			close(s.release)
		}
	})
	var gets, puts atomic.Int32
	handler := generationAPI(t, "")
	g := durableFixture(t, s, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			gets.Add(1)
		}
		if r.Method == http.MethodPut {
			puts.Add(1)
		}
		handler(w, r)
	})
	type prepared struct {
		grant GenerationGrant
		err   error
	}
	done := make(chan prepared, 1)
	go func() {
		grant, err := g.Prepare(context.Background(), "pod-a", "zone-a", "attempt-original")
		done <- prepared{grant, err}
	}()
	select {
	case <-s.entered:
	case <-time.After(time.Second):
		t.Fatal("registration never committed")
	}
	select {
	case <-done:
		t.Fatal("capability escaped before acknowledgment")
	default:
	}
	row := durableRow(t, s.Fake)
	journal, err := allocatorjournal.DecodeJournal(string(row.Journal))
	if err != nil || row.Phase != "open" || len(journal.Grants) != 1 || journal.Grants[0] != (allocatorjournal.JournalGrant{ActorUID: "pod-a", AttemptID: "attempt-original", Name: "zone-a", UID: "uid-zone-a", SourceVersion: "opaque-a"}) {
		t.Fatalf("original frozen grant not registered: %+v %v", journal, err)
	}
	if gets.Load() != 1 || puts.Load() != 0 {
		t.Fatal("preparation refreshed or allocated before exposure")
	}
	close(s.release)
	got := <-done
	if got.err != nil || got.grant.state == nil {
		t.Fatalf("acknowledged preparation: %v", got.err)
	}
	if err = got.grant.Commit(context.Background()); err != nil || puts.Load() != 1 || gets.Load() != 1 {
		t.Fatalf("registered frozen mutation did not submit once: %v", err)
	}
}

func TestDurableGenerationDisabledBeforeDependencyInspection(t *testing.T) {
	s := nakamastoragetest.New()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	got, err := NewDurableGeneration(ctx, DurableGenerationConfig{Storage: s, IncarnationID: "invalid"})
	if got != nil || !errors.Is(err, ErrDisabled) || len(s.WrittenValues()) != 0 {
		t.Fatal("disabled constructor accessed dependencies")
	}
}

func TestDurableClosureAccountsLateUnexposedRegistration(t *testing.T) {
	s := &durableStorage{Fake: nakamastoragetest.New(), holdVersion: "v3", entered: make(chan struct{}), release: make(chan struct{})}
	t.Cleanup(func() {
		select {
		case <-s.release:
		default:
			close(s.release)
		}
	})
	g := durableFixture(t, s, generationAPI(t, ""))
	exported := generationPrepare(t, g, "pod-a", "zone-a")
	prepared := make(chan error, 1)
	go func() {
		grant, err := g.Prepare(context.Background(), "pod-b", "zone-b", "original-b")
		if grant.state != nil {
			prepared <- errors.New("late capability escaped")
			return
		}
		prepared <- err
	}()
	select {
	case <-s.entered:
	case <-time.After(time.Second):
		t.Fatal("registration did not commit")
	}
	type fenced struct {
		receipt GenerationReceipt
		err     error
	}
	done := make(chan fenced, 1)
	go func() { r, err := g.Fence(context.Background()); done <- fenced{r, err} }()
	deadline := time.Now().Add(time.Second)
	for {
		g.state.mu.Lock()
		closed := g.state.closed
		g.state.mu.Unlock()
		if closed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("local closure waited for storage")
		}
		time.Sleep(time.Millisecond)
	}
	if err := exported.Commit(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("exported commit admission remained open: %v", err)
	}
	select {
	case <-done:
		t.Fatal("drain skipped held registration")
	default:
	}
	close(s.release)
	if err := <-prepared; !errors.Is(err, ErrClosed) {
		t.Fatalf("late preparation: %v", err)
	}
	result := <-done
	got, err := g.Accept(result.receipt)
	if result.err != nil || err != nil || len(got.Grants) != 2 {
		t.Fatalf("incomplete registered set: %+v %v %v", got, result.err, err)
	}
	for _, grant := range got.Grants {
		if grant.Outcome != Uncommitted {
			t.Fatal("unexposed grant was allocated")
		}
	}
	row := durableRow(t, s.Fake)
	journal, err := allocatorjournal.DecodeJournal(string(row.Journal))
	if err != nil || row.Phase != "draining" || len(journal.Grants) != 2 || journal.Grants[1].AttemptID != "original-b" {
		t.Fatalf("drained set lost late grant: %+v %v", journal, err)
	}
	got.Grants[0].AttemptID = "caller-substitution"
	again, err := g.Accept(result.receipt)
	if err != nil || again.Grants[0].AttemptID == "caller-substitution" {
		t.Fatal("receipt data changed owner inventory")
	}
	if _, err = g.Fence(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatal("closure replayed")
	}
}

func TestDurableConcurrentPreparationPreservesEveryExactVersion(t *testing.T) {
	s := nakamastoragetest.New()
	g := durableFixture(t, s, generationAPI(t, ""))
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	for _, name := range []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := g.Prepare(context.Background(), "pod-a", name, "attempt-"+name)
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	r, err := g.Fence(context.Background())
	got, accepted := g.Accept(r)
	if err != nil || accepted != nil || len(got.Grants) != 12 {
		t.Fatalf("complete serial root: %+v %v %v", got, err, accepted)
	}
	journal, err := allocatorjournal.DecodeJournal(string(durableRow(t, s).Journal))
	if err != nil || len(journal.Grants) != 12 {
		t.Fatalf("durable registrations were lost: %+v %v", journal, err)
	}
}

func TestDurablePreparationStillFreezingAtClosureDoesNotRegister(t *testing.T) {
	s := nakamastoragetest.New()
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	handler := generationAPI(t, "")
	g := durableFixture(t, s, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			close(entered)
			select {
			case <-release:
			case <-time.After(time.Second):
				w.WriteHeader(504)
				return
			}
		}
		handler(w, r)
	})
	done := make(chan error, 1)
	go func() {
		grant, err := g.Prepare(context.Background(), "pod-a", "zone-a", "attempt-a")
		if grant.state != nil {
			done <- errors.New("late freeze exposed capability")
			return
		}
		done <- err
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("freeze GET not held")
	}
	r, err := g.Fence(context.Background())
	got, accepted := g.Accept(r)
	if err != nil || accepted != nil || len(got.Grants) != 0 {
		t.Fatal("empty durable drain waited for unregistered freeze")
	}
	once.Do(func() { close(release) })
	if err := <-done; !errors.Is(err, ErrClosed) {
		t.Fatalf("late freeze: %v", err)
	}
	if len(s.WrittenValues()) != 2 {
		t.Fatal("late freeze wrote a registration after drain")
	}
}

func TestDurableRegistrationNeverRefreshesRecreatedTarget(t *testing.T) {
	s := &durableStorage{Fake: nakamastoragetest.New(), holdVersion: "v2", entered: make(chan struct{}), release: make(chan struct{})}
	t.Cleanup(func() {
		select {
		case <-s.release:
		default:
			close(s.release)
		}
	})
	obj := ready()
	obj.Name = "zone-a"
	obj.UID = "uid-original"
	var mu sync.Mutex
	var gets, puts atomic.Int32
	g := durableFixture(t, s, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Method == http.MethodGet {
			gets.Add(1)
			reply(w, obj)
			return
		}
		puts.Add(1)
		var next agonesv1.GameServer
		if json.NewDecoder(r.Body).Decode(&next) != nil {
			w.WriteHeader(400)
			return
		}
		if next.UID != obj.UID || next.ResourceVersion != obj.ResourceVersion {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(409)
			_, _ = w.Write([]byte(`{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"Conflict","code":409}`))
			return
		}
		t.Error("recreated target accepted original frozen write")
		reply(w, obj)
	})
	type prepared struct {
		grant GenerationGrant
		err   error
	}
	done := make(chan prepared, 1)
	go func() {
		grant, err := g.Prepare(context.Background(), "pod-a", "zone-a", "original-attempt")
		done <- prepared{grant, err}
	}()
	select {
	case <-s.entered:
	case <-time.After(time.Second):
		t.Fatal("registration not held")
	}
	mu.Lock()
	obj.UID = "uid-replacement"
	obj.ResourceVersion = "replacement-version"
	mu.Unlock()
	close(s.release)
	p := <-done
	if p.err != nil {
		t.Fatal(p.err)
	}
	if err := p.grant.Commit(context.Background()); !errors.Is(err, ErrConflict) || gets.Load() != 1 || puts.Load() != 1 {
		t.Fatalf("target was refreshed or original write not refused: %v", err)
	}
	journal, err := allocatorjournal.DecodeJournal(string(durableRow(t, s.Fake).Journal))
	if err != nil || journal.Grants[0].UID != "uid-original" || journal.Grants[0].SourceVersion != "opaque-a" || journal.Grants[0].AttemptID != "original-attempt" {
		t.Fatal("registration substituted frozen identity")
	}
	if _, err = g.Prepare(context.Background(), "pod-a", "zone-a", "replacement-attempt"); !errors.Is(err, ErrUnknown) {
		t.Fatalf("same-name replacement bypassed original registration: %v", err)
	}
	if len(g.state.grants) != 1 {
		t.Fatal("replacement exported another capability")
	}
}

func TestDurableClosureDeadlineDoesNotWaitForRegistrationReply(t *testing.T) {
	s := &durableStorage{Fake: nakamastoragetest.New(), holdVersion: "v3", entered: make(chan struct{}), release: make(chan struct{})}
	t.Cleanup(func() {
		select {
		case <-s.release:
		default:
			close(s.release)
		}
	})
	g := durableFixture(t, s, generationAPI(t, ""))
	prior := generationPrepare(t, g, "pod-a", "zone-a")
	done := make(chan error, 1)
	go func() { _, err := g.Prepare(context.Background(), "pod-b", "zone-b", "attempt-b"); done <- err }()
	select {
	case <-s.entered:
	case <-time.After(time.Second):
		t.Fatal("registration not held")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	r, err := g.Fence(ctx)
	if r.state != nil || !errors.Is(err, ErrUnknown) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("bounded closure: %v", err)
	}
	if err = prior.Commit(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatal("deadline reopened prior handle")
	}
	close(s.release)
	if err = <-done; !errors.Is(err, ErrClosed) {
		t.Fatalf("late registration after deadline: %v", err)
	}
	before := len(s.WrittenValues())
	if _, err = g.Fence(context.Background()); !errors.Is(err, ErrClosed) || len(s.WrittenValues()) != before {
		t.Fatal("expired drain replayed")
	}
	if len(g.state.grants) != 2 || durableRow(t, s.Fake).Phase != "open" {
		t.Fatal("late committed inventory was lost or unknown drain called success")
	}
}

func TestDurableUnknownWritesCannotRestoreAuthority(t *testing.T) {
	for _, version := range []string{"v1", "v2", "v3"} {
		t.Run(version, func(t *testing.T) {
			s := nakamastoragetest.New()
			s.AfterWrite = func(firstVersion int) error {
				if version == []string{"v1", "v2", "v3"}[firstVersion-1] {
					return errors.New("committed reply lost")
				}
				return nil
			}
			_, cfg := generationFixture(t, generationAPI(t, ""))
			config := DurableGenerationConfig{Enabled: true, Commit: cfg.Commit, Record: cfg.Record, IncarnationID: "incarnation-1", Storage: s}
			g, err := NewDurableGeneration(context.Background(), config)
			if version == "v1" {
				if g != nil || !errors.Is(err, ErrUnknown) {
					t.Fatalf("create uncertainty: %v", err)
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				grant, prepErr := g.Prepare(context.Background(), "pod-a", "zone-a", "attempt-a")
				if version == "v2" {
					if grant.state != nil || !errors.Is(prepErr, ErrUnknown) {
						t.Fatalf("register uncertainty: %v", prepErr)
					}
				} else {
					if prepErr != nil {
						t.Fatal(prepErr)
					}
					r, fenceErr := g.Fence(context.Background())
					if r.state != nil || !errors.Is(fenceErr, ErrUnknown) {
						t.Fatalf("drain uncertainty: %v", fenceErr)
					}
				}
				before := len(s.WrittenValues())
				if _, err = g.Prepare(context.Background(), "pod-b", "zone-b", "attempt-b"); !errors.Is(err, ErrClosed) {
					t.Fatal("unknown owner reopened")
				}
				if _, err = g.Fence(context.Background()); !errors.Is(err, ErrClosed) || len(s.WrittenValues()) != before {
					t.Fatal("unknown closure replayed storage")
				}
			}
			// A new incarnation cannot create another generation-wide root or
			// reconstruct capability authority from the committed private row.
			config.IncarnationID = "incarnation-2"
			if restored, restoreErr := NewDurableGeneration(context.Background(), config); restored != nil || !errors.Is(restoreErr, ErrUnknown) {
				t.Fatalf("restart restored authority: %v", restoreErr)
			}
			if durableRow(t, s).Phase == "" {
				t.Fatal("uncertain committed root disappeared")
			}
		})
	}
}

func TestDurableEmptyDrainReceiptStaysPrivate(t *testing.T) {
	g := durableFixture(t, nakamastoragetest.New(), generationAPI(t, ""))
	r, err := g.Fence(context.Background())
	got, err2 := g.Accept(r)
	if err != nil || err2 != nil || len(got.Grants) != 0 || !slices.Equal(got.MemberPodUIDs, []string{"pod-a", "pod-b"}) {
		t.Fatalf("empty receipt: %+v %v %v", got, err, err2)
	}
	other := durableFixture(t, nakamastoragetest.New(), generationAPI(t, ""))
	if _, err = other.Accept(r); !errors.Is(err, ErrInvalid) {
		t.Fatal("foreign owner accepted receipt")
	}
	if _, err = g.Accept(GenerationReceipt{}); !errors.Is(err, ErrInvalid) {
		t.Fatal("detached observation reconstructed receipt")
	}
}

// Hold local accounting after the real acknowledgment, and capture the exact
// nil cancellation check used by Writer before canceling. This distinguishes a
// post-ack/pre-exposure cancellation from a lost StorageWrite acknowledgment.
type postAckStorage struct {
	*nakamastoragetest.Fake
	owner     *generationState
	committed atomic.Bool
	beforeAck chan struct{}
	resumeAck chan struct{}
}

func (s *postAckStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	acks, err := s.Fake.StorageWrite(ctx, writes)
	if err == nil && len(acks) == 1 && acks[0].GetVersion() == "v3" {
		if s.beforeAck != nil {
			close(s.beforeAck)
			<-s.resumeAck
		}
		s.owner.mu.Lock()
		s.committed.Store(true)
	}
	return acks, err
}

func TestDurableConcurrentFenceCannotRecoverCanceledRegistration(t *testing.T) {
	s := &postAckStorage{Fake: nakamastoragetest.New(), beforeAck: make(chan struct{}), resumeAck: make(chan struct{})}
	g := durableFixture(t, s, generationAPI(t, ""))
	s.owner = g.state
	prior := generationPrepare(t, g, "pod-a", "zone-a")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	checked := &ackContext{Context: ctx, storage: s, checked: make(chan struct{})}
	raw, err := g.state.client.Prepare(context.Background(), "zone-b", "original-b")
	if err != nil {
		t.Fatal(err)
	}
	prepared := make(chan error, 1)
	go func() { _, err := g.state.register(checked, raw, "pod-b", "original-b"); prepared <- err }()
	select {
	case <-s.beforeAck:
	case <-time.After(time.Second):
		t.Fatal("committed registration not held")
	}
	type fenced struct {
		receipt GenerationReceipt
		err     error
	}
	fences := make(chan fenced, 1)
	go func() { r, err := g.Fence(context.Background()); fences <- fenced{r, err} }()
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		_, err := g.Prepare(context.Background(), "non-member", "unused", "unused")
		if errors.Is(err, ErrClosed) {
			break
		}
		select {
		case <-ticker.C:
		case <-deadline.C:
			t.Fatal("pending fence did not close admission")
		}
	}
	close(s.resumeAck)
	select {
	case <-checked.checked:
	case <-time.After(time.Second):
		t.Fatal("acknowledgment check not reached")
	}
	cancel()
	s.owner.mu.Unlock()
	if err := <-prepared; !errors.Is(err, ErrUnknown) || !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled preparation lost uncertainty: %v", err)
	}
	f := <-fences
	if !errors.Is(f.err, ErrUnknown) || f.receipt.state != nil {
		t.Fatalf("pending fence restored uncertain authority: %v", f.err)
	}
	if durableRow(t, s.Fake).Phase != "open" || len(g.state.grants) != 2 {
		t.Fatal("uncertain registration was omitted or drained")
	}
	if err := prior.Commit(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatal("uncertain owner reopened prior capability")
	}
}

type ackContext struct {
	context.Context
	storage *postAckStorage
	checked chan struct{}
	once    sync.Once
}

func (c *ackContext) Err() error {
	err := c.Context.Err()
	if c.storage.committed.Load() {
		c.once.Do(func() { close(c.checked) })
	}
	return err
}
func TestDurableCancellationAfterAcknowledgmentClosesPriorHandles(t *testing.T) {
	s := &postAckStorage{Fake: nakamastoragetest.New()}
	g := durableFixture(t, s, generationAPI(t, ""))
	s.owner = g.state
	prior := generationPrepare(t, g, "pod-a", "zone-a")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	checked := &ackContext{Context: ctx, storage: s, checked: make(chan struct{})}
	raw, err := g.state.client.Prepare(context.Background(), "zone-b", "original-b")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		grant, err := g.state.register(checked, raw, "pod-b", "original-b")
		if grant.state != nil {
			done <- errors.New("canceled capability escaped")
			return
		}
		done <- err
	}()
	select {
	case <-checked.checked:
	case <-time.After(time.Second):
		t.Fatal("post-ack check not reached")
	}
	cancel()
	s.owner.mu.Unlock()
	if err := <-done; !errors.Is(err, ErrUnknown) || !errors.Is(err, context.Canceled) {
		t.Fatalf("post-ack cancellation lost: %v", err)
	}
	if len(g.state.grants) != 2 {
		t.Fatal("acknowledged unexposed entry was lost")
	}
	if err := prior.Commit(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("uncertain owner kept prior handle open: %v", err)
	}
}
