package gameservercommit

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/internal/custodywitness"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/runtime"
)

var witnessTableID = custodywitness.TableIdentity{ID: "witness-table", CreatedAt: time.Unix(1700000000, 0).UTC()}

// witnessTable is a strongly consistent map behind the real witness client.
// fault selects how the next calls end once it is armed.
type witnessTable struct {
	mu    sync.Mutex
	rows  map[string]string
	puts  int
	fault string
	// onPut runs before each write, to observe what a writer has released by then.
	onPut func()
}

func (w *witnessTable) Identity(context.Context) (custodywitness.TableIdentity, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.fault == "unavailable" {
		return custodywitness.TableIdentity{}, errors.New("identity unreadable")
	}
	return witnessTableID, nil
}

func (w *witnessTable) Get(_ context.Context, key string) (string, bool, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.fault == "lost-unreadable" {
		return "", false, errors.New("read failed")
	}
	value, found := w.rows[key]
	return value, found, nil
}

func (w *witnessTable) Put(_ context.Context, key, expected, value string) error {
	if w.onPut != nil {
		w.onPut()
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	w.puts++
	current, found := w.rows[key]
	switch {
	case w.fault == "rejected", found != (expected != ""), found && current != expected:
		return custodywitness.ErrConditionFailed
	case w.fault == "lost-uncommitted":
		return errors.New("reply lost")
	}
	w.rows[key] = value
	if w.fault == "lost-committed" || w.fault == "lost-unreadable" {
		return errors.New("reply lost")
	}
	return nil
}

func (w *witnessTable) arm(fault string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.fault = fault
}

func witnessClient(t *testing.T, table *witnessTable) *custodywitness.Client {
	t.Helper()
	client, err := custodywitness.New(custodywitness.Config{Enabled: true, Table: table, Identity: witnessTableID})
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func witnessedGeneration(t *testing.T, table *witnessTable) (*Generation, error) {
	t.Helper()
	return witnessedGenerationOn(t, table, nakamastoragetest.New())
}

func witnessedGenerationOn(t *testing.T, table *witnessTable, storage allocatoradmission.RecoveryStorage) (*Generation, error) {
	t.Helper()
	_, cfg := generationFixture(t, generationAPI(t, ""))
	return NewDurableGeneration(context.Background(), DurableGenerationConfig{
		Enabled: true, Commit: cfg.Commit, Record: cfg.Record, IncarnationID: "incarnation-1",
		Storage: storage,
		Witness: GenerationWitnessConfig{Enabled: true, Witness: clientWitness{witnessClient(t, table)}},
	})
}

func newWitnessTable() *witnessTable { return &witnessTable{rows: map[string]string{}} }

// Two registrations and a closing (a drain for a fence, a drain and a handoff
// for recovery) leave the witness holding exactly the generation's own
// retained record, one conditional write per stage. Each closing is returned
// only after the witness acknowledged its last stage.
func TestWitnessedGenerationChainMatchesItsOwnRecord(t *testing.T) {
	for _, tc := range []struct {
		name    string
		close   func(*Generation) error
		stage   string
		handoff bool
		puts    int
	}{
		{"fence", func(g *Generation) error { _, err := g.Fence(context.Background()); return err }, WitnessDrained, false, 4},
		{"handoff", closeForRecovery, WitnessHandoff, true, 5},
	} {
		t.Run(tc.name, func(t *testing.T) {
			table := newWitnessTable()
			g, err := witnessedGeneration(t, table)
			if err != nil {
				t.Fatal(err)
			}
			for _, name := range []string{"zone-a", "zone-b"} {
				if _, err = g.Prepare(context.Background(), "pod-a", name, "attempt-"+name); err != nil {
					t.Fatalf("witnessed registration %s: %v", name, err)
				}
			}
			if err = tc.close(g); err != nil {
				t.Fatalf("witnessed %s: %v", tc.name, err)
			}
			own := g.state.durable.witness.acked
			if own.Stage != tc.stage || own.GrantCount != 2 || own.DrainPin == "" || table.puts != tc.puts ||
				own.GenerationKey != allocatoradmission.Key(generationRecord().GenerationID) {
				t.Fatalf("witness chain: %+v after %d writes", own, table.puts)
			}
			if tc.handoff != (own.HandoffPin != "") || (tc.handoff && own.HandoffPin == own.DrainPin) {
				t.Fatalf("handoff pin: %+v", own)
			}
			if got := witnessClient(t, table).CompareGeneration(context.Background(), toCustody(own)); got != custodywitness.Verified {
				t.Fatalf("witness disagrees with the generation's record: %s", got)
			}
		})
	}
}

// closeForRecovery requires the handoff to come back with its binding and
// acknowledged version.
func closeForRecovery(g *Generation) error {
	binding, version, err := g.CloseForRecovery(context.Background())
	if err == nil && (binding.GenerationID == "" || version == "") {
		return errors.New("handoff without its binding or acknowledged version")
	}
	return err
}

// A refused, conflicting or unavailable witness exports no grant, closes the
// generation as uncertain, and leaves no receipt or handoff to form.
func TestWitnessRefusalExportsNoGrant(t *testing.T) {
	for _, fault := range []string{"rejected", "conflicting", "unavailable", "lost-uncommitted", "lost-unreadable"} {
		t.Run(fault, func(t *testing.T) {
			table := newWitnessTable()
			g, err := witnessedGeneration(t, table)
			if err != nil {
				t.Fatal(err)
			}
			if fault == "conflicting" {
				for key := range table.rows {
					table.rows[key] = "{}"
				}
			} else {
				table.arm(fault)
			}
			grant, err := g.Prepare(context.Background(), "pod-a", "zone-a", "attempt-a")
			if !errors.Is(err, ErrUnknown) || grant.state != nil {
				t.Fatalf("unwitnessed grant exported: %v", err)
			}
			if !g.state.closed || !g.state.durable.uncertain || len(g.state.grants) != 1 {
				t.Fatal("acknowledged registration was not kept conservatively under uncertainty")
			}
			if _, err = g.Fence(context.Background()); err == nil {
				t.Fatal("receipt formed after a witness refusal")
			}
			if _, _, err = g.CloseForRecovery(context.Background()); err == nil {
				t.Fatal("handoff published after a witness refusal")
			}
		})
	}
}

// The drained snapshot is released only after the witness holds `drained`.
func TestWitnessRefusalAtDrainFormsNoReceiptOrHandoff(t *testing.T) {
	for _, closing := range []string{"fence", "handoff"} {
		t.Run(closing, func(t *testing.T) {
			g, table := grantedWitnessedGeneration(t)
			var err error
			table.arm("rejected")
			if closing == "fence" {
				_, err = g.Fence(context.Background())
			} else {
				_, _, err = g.CloseForRecovery(context.Background())
			}
			if !errors.Is(err, ErrUnknown) || !g.state.durable.uncertain {
				t.Fatalf("unwitnessed drain released: %v", err)
			}
			if g.state.durable.witness.acked.Stage != WitnessRegistered {
				t.Fatal("refused drain advanced the retained witness record")
			}
		})
	}
}

// A lost reply is an acknowledgement only when the strongly consistent
// re-read finds exactly the intended record.
func TestWitnessLostReplySettledByExactReread(t *testing.T) {
	table := newWitnessTable()
	g, err := witnessedGeneration(t, table)
	if err != nil {
		t.Fatal(err)
	}
	table.arm("lost-committed")
	if _, err = g.Prepare(context.Background(), "pod-a", "zone-a", "attempt-a"); err != nil {
		t.Fatalf("committed registration with a lost reply refused: %v", err)
	}
	if _, err = g.Fence(context.Background()); err != nil {
		t.Fatalf("committed drain with a lost reply refused: %v", err)
	}
}

// The generation is not exported until its root registration is witnessed.
func TestWitnessRootRefusalExportsNoGeneration(t *testing.T) {
	table := newWitnessTable()
	table.arm("unavailable")
	g, err := witnessedGeneration(t, table)
	if g != nil || !errors.Is(err, ErrUnknown) {
		t.Fatalf("generation exported without its witnessed root: %v", err)
	}
}

// A half-configured witness is refused before storage is touched; the zero
// value composes none.
func TestWitnessConfigRefusesHalfConfiguration(t *testing.T) {
	var typedNil *clientWitness
	for name, cfg := range map[string]GenerationWitnessConfig{
		"enabled without witness": {Enabled: true},
		"enabled with typed nil":  {Enabled: true, Witness: typedNil},
		"enabled with nil func":   {Enabled: true, Witness: witnessFunc(nil)},
		"witness without opt-in":  {Witness: clientWitness{witnessClient(t, newWitnessTable())}},
	} {
		storage := nakamastoragetest.New()
		_, gen := generationFixture(t, generationAPI(t, ""))
		got, err := NewDurableGeneration(context.Background(), DurableGenerationConfig{
			Enabled: true, Commit: gen.Commit, Record: gen.Record, IncarnationID: "incarnation-1",
			Storage: storage, Witness: cfg,
		})
		if got != nil || !errors.Is(err, ErrInvalid) || len(storage.WrittenValues()) != 0 {
			t.Fatalf("%s: half-configured witness accepted or storage touched: %v", name, err)
		}
	}
	g := durableFixture(t, nakamastoragetest.New(), generationAPI(t, ""))
	if g.state.durable.witness != nil {
		t.Fatal("zero-value configuration composed a witness")
	}
	if w, ok := (GenerationWitnessConfig{Witness: typedNil}).compose(); !ok || w != nil {
		t.Fatal("disabled configuration with an unset witness composed one")
	}
}

// clientWitness adapts the real witness client, as a later composition will.
type clientWitness struct{ client *custodywitness.Client }

func (c clientWitness) WriteGeneration(ctx context.Context, previous, next WitnessRecord) error {
	_, err := c.client.WriteGeneration(ctx, toCustody(previous), toCustody(next))
	return err
}

func toCustody(r WitnessRecord) custodywitness.GenerationRecord {
	return custodywitness.GenerationRecord{
		GenerationKey: r.GenerationKey, Stage: custodywitness.GenerationStage(r.Stage), GrantCount: r.GrantCount,
		IssuedDigest: r.IssuedDigest, RegistrationPin: r.RegistrationPin, DrainPin: r.DrainPin, HandoffPin: r.HandoffPin,
		OwnerPin: r.OwnerPin, RecoveredPin: r.RecoveredPin, PublishedPin: r.PublishedPin,
	}
}

// The local stage names are the witness family's own.
func TestWitnessStagesAreTheGenerationFamilyStages(t *testing.T) {
	if WitnessRegistered != string(custodywitness.GenerationRegistered) || WitnessDrained != string(custodywitness.GenerationDrained) ||
		WitnessHandoff != string(custodywitness.GenerationHandoff) || allocatoradmission.WitnessOwner != string(custodywitness.GenerationOwner) ||
		WitnessRecovered != string(custodywitness.GenerationRecovered) || WitnessPublished != string(custodywitness.GenerationPublished) {
		t.Fatal("local witness stage names drifted from the generation family")
	}
}

// witnessFunc is a function adapter, whose nil value is also no witness.
type witnessFunc func(context.Context, WitnessRecord, WitnessRecord) error

func (f witnessFunc) WriteGeneration(ctx context.Context, previous, next WitnessRecord) error {
	return f(ctx, previous, next)
}

// A refused, conflicting, unavailable or lost-then-unreadable handoff witness
// exports no handoff, leaves the generation uncertain and keeps the retained
// record at `drained`; a lost reply the exact re-read finds is acknowledged.
func TestWitnessRefusalAtHandoffExportsNoHandoff(t *testing.T) {
	for _, fault := range []string{"rejected", "conflicting", "unavailable", "lost-uncommitted", "lost-unreadable", "lost-committed"} {
		t.Run(fault, func(t *testing.T) {
			g, table := grantedWitnessedGeneration(t)
			// Drain is witnessed normally; the fault applies to the handoff write.
			witness := g.state.durable.witness
			witness.writer = &faultAfter{witness.writer, 1, table, fault}
			binding, version, err := g.CloseForRecovery(context.Background())
			if fault == "lost-committed" {
				if err != nil || version == "" || binding.GenerationID == "" || g.state.durable.uncertain || witness.acked.Stage != WitnessHandoff {
					t.Fatalf("committed handoff with a lost reply refused: %v", err)
				}
				return
			}
			if !errors.Is(err, ErrUnknown) || version != "" || binding.GenerationID != "" || !g.state.durable.uncertain {
				t.Fatalf("unwitnessed handoff exported: %v", err)
			}
			if witness.acked.Stage != WitnessDrained {
				t.Fatal("refused handoff advanced the retained witness record")
			}
		})
	}
}

// A handoff binding that is not the witnessed drained generation and issued
// set, or not its journal version, is refused before any witness write.
func TestWitnessHandoffRefusesAForeignBinding(t *testing.T) {
	g, table := grantedWitnessedGeneration(t)
	if _, err := g.Fence(context.Background()); err != nil {
		t.Fatal(err)
	}
	witness := g.state.durable.witness
	own := g.state.durable.head.Observation().Journal.Binding
	puts := table.puts
	for name, mutate := range map[string]func(*allocatorjournal.JournalBinding){
		"other generation": func(b *allocatorjournal.JournalBinding) { b.GenerationID = "generation-other" },
		"other count":      func(b *allocatorjournal.JournalBinding) { b.IssuedCount++ },
		"other issued set": func(b *allocatorjournal.JournalBinding) { b.IssuedDigest = witness.acked.RegistrationPin },
		"other version":    func(b *allocatorjournal.JournalBinding) { b.Version += "-other" },
		"no version":       func(b *allocatorjournal.JournalBinding) { b.Version = "" },
	} {
		foreign := own
		mutate(&foreign)
		if err := witness.handoff(context.Background(), foreign, "v1"); !errors.Is(err, ErrInvalid) || table.puts != puts {
			t.Fatalf("%s: foreign handoff witnessed: %v", name, err)
		}
	}
	if err := witness.handoff(context.Background(), own, "v1"); err != nil || witness.acked.Stage != WitnessHandoff {
		t.Fatalf("own handoff refused: %v", err)
	}
}

// faultAfter lets the first calls through, then arms fault on the table before
// forwarding the rest. A conflict is a rival writer's valid record at the same
// next stage, stored first.
type faultAfter struct {
	next  GenerationWitness
	clean int
	table *witnessTable
	fault string
}

func (f *faultAfter) WriteGeneration(ctx context.Context, previous, next WitnessRecord) error {
	if f.clean > 0 {
		f.clean--
		return f.next.WriteGeneration(ctx, previous, next)
	}
	if f.fault == "conflicting" {
		rival := next
		switch next.Stage {
		case allocatoradmission.WitnessOwner:
			rival.OwnerPin = next.RegistrationPin
		case WitnessRecovered:
			rival.RecoveredPin = next.RegistrationPin
		case WitnessPublished:
			rival.PublishedPin = next.RegistrationPin
		default:
			rival.HandoffPin = next.RegistrationPin
		}
		if err := f.next.WriteGeneration(ctx, previous, rival); err != nil {
			return err
		}
	} else {
		f.table.arm(f.fault)
	}
	return f.next.WriteGeneration(ctx, previous, next)
}

// grantedWitnessedGeneration returns a witnessed generation holding one
// witnessed grant, and its witness table.
func grantedWitnessedGeneration(t *testing.T) (*Generation, *witnessTable) {
	t.Helper()
	table := newWitnessTable()
	g, err := witnessedGeneration(t, table)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = g.Prepare(context.Background(), "pod-a", "zone-a", "attempt-a"); err != nil {
		t.Fatal(err)
	}
	return g, table
}

// closedWitnessedGeneration closes one witnessed grant for recovery on storage
// and returns a recovery owner configuration holding its witnessed handoff.
func closedWitnessedGeneration(t *testing.T, storage allocatoradmission.RecoveryStorage, id string) (allocatoradmission.RecoveryOwnerConfig, *witnessTable) {
	t.Helper()
	table := newWitnessTable()
	g, err := witnessedGenerationOn(t, table, storage)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = g.Prepare(context.Background(), "pod-a", "zone-a", "attempt-a"); err != nil {
		t.Fatal(err)
	}
	binding, version, err := g.CloseForRecovery(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return allocatoradmission.RecoveryOwnerConfig{
		Enabled: true, Storage: storage, Binding: binding, HandoffVersion: version, OwnerID: id,
		Witness: allocatoradmission.RecoveryOwnerWitnessConfig{
			Enabled: true, Witness: clientWitness{witnessClient(t, table)}, Handoff: g.state.durable.witness.acked,
		},
	}, table
}

// The chain registered, drained, handoff, owner is one the real witness client
// accepts step by step, and it ends at exactly the recoverer's own record.
func TestWitnessedOwnerChainMatchesTheRecoverersRecord(t *testing.T) {
	cfg, table := closedWitnessedGeneration(t, nakamastoragetest.New(), "recoverer-1")
	puts := table.puts
	owner, err := allocatoradmission.NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := owner.Reserve(context.Background())
	if err != nil {
		t.Fatalf("witnessed owner refused: %v", err)
	}
	own, err := reservation.Witnessed()
	if err != nil || own.Stage != allocatoradmission.WitnessOwner || own.OwnerPin == "" || own.OwnerPin == own.HandoffPin || table.puts != puts+1 {
		t.Fatalf("witnessed owner record: %+v after %d writes: %v", own, table.puts-puts, err)
	}
	client := witnessClient(t, table)
	if got := client.CompareGeneration(context.Background(), toCustody(own)); got != custodywitness.Verified {
		t.Fatalf("witness disagrees with the recoverer's record: %s", got)
	}
	if got := client.CompareGeneration(context.Background(), toCustody(cfg.Witness.Handoff)); got != custodywitness.WitnessAhead {
		t.Fatalf("witness did not move past the handoff: %s", got)
	}
}

// A refused, conflicting, unavailable or lost-then-unreadable owner witness
// returns no reservation and ends the attempt, keeping the row as the permanent
// exclusion; a lost reply the exact re-read finds is acknowledged.
func TestWitnessRefusalAtOwnerReturnsNoReservation(t *testing.T) {
	for _, fault := range []string{"rejected", "conflicting", "unavailable", "lost-uncommitted", "lost-unreadable", "lost-committed"} {
		t.Run(fault, func(t *testing.T) {
			storage := nakamastoragetest.New()
			cfg, table := closedWitnessedGeneration(t, storage, "recoverer-1")
			cfg.Witness.Witness = &faultAfter{cfg.Witness.Witness, 0, table, fault}
			owner, err := allocatoradmission.NewRecoveryOwner(cfg)
			if err != nil {
				t.Fatal(err)
			}
			reservation, err := owner.Reserve(context.Background())
			if fault == "lost-committed" {
				if own, witnessed := reservation.Witnessed(); err != nil || witnessed != nil || own.Stage != allocatoradmission.WitnessOwner {
					t.Fatalf("committed owner with a lost reply refused: %v, %v", err, witnessed)
				}
				return
			}
			if !errors.Is(err, allocatoradmission.ErrUnknown) || reservation != (allocatoradmission.RecoveryReservation{}) {
				t.Fatalf("unwitnessed reservation returned: %v", err)
			}
			if _, err = owner.Accept(reservation); err == nil {
				t.Fatal("unwitnessed owner accepted")
			}
			if _, err = owner.Reserve(context.Background()); !errors.Is(err, allocatoradmission.ErrClosed) {
				t.Fatalf("refused attempt retried: %v", err)
			}
			if _, found := storage.Get(allocatoradmission.RecoveryOwnerCollection, allocatoradmission.RecoveryOwnerKey(cfg.Binding.GenerationID), ""); !found {
				t.Fatal("owner row did not stay as the exclusion")
			}
		})
	}
}

// After a Nakama restore drops the owner row, a second recoverer's create
// succeeds again, and only the witness still knows who won. It gets no
// reservation, so it reaches no target.
func TestWitnessRefusesTheSecondRecovererAfterARestoreDropsTheOwnerRow(t *testing.T) {
	storage := nakamastoragetest.New()
	cfg, table := closedWitnessedGeneration(t, storage, "recoverer-1")
	first, err := allocatoradmission.NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := first.Reserve(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	won, err := reservation.Witnessed()
	if err != nil {
		t.Fatal(err)
	}
	key := allocatoradmission.RecoveryOwnerKey(cfg.Binding.GenerationID)
	if err = storage.StorageDelete(context.Background(), []*runtime.StorageDelete{{Collection: allocatoradmission.RecoveryOwnerCollection, Key: key}}); err != nil {
		t.Fatal(err)
	}
	if _, found := storage.Get(allocatoradmission.RecoveryOwnerCollection, key, ""); found {
		t.Fatal("restore control: the owner row survived")
	}
	cfg.OwnerID = "recoverer-2"
	second, err := allocatoradmission.NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	lost, err := second.Reserve(context.Background())
	if !errors.Is(err, allocatoradmission.ErrUnknown) || lost != (allocatoradmission.RecoveryReservation{}) {
		t.Fatalf("second recoverer reserved: %v", err)
	}
	if _, found := storage.Get(allocatoradmission.RecoveryOwnerCollection, key, ""); !found {
		t.Fatal("control: the second create never reached the witness")
	}
	if got := witnessClient(t, table).CompareGeneration(context.Background(), toCustody(won)); got != custodywitness.Verified {
		t.Fatalf("witness no longer names the first recoverer: %s", got)
	}
	var requests atomic.Int32
	_, gen := generationFixture(t, func(http.ResponseWriter, *http.Request) { requests.Add(1) })
	commit := gen.Commit
	commit.Enabled = true
	recovery, err := NewRecovery(commit, lost)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = recovery.Fence(context.Background()); err == nil || requests.Load() != 0 {
		t.Fatalf("refused recoverer reached a target: %v after %d requests", err, requests.Load())
	}
}

// witnessedRecoveryPair closes a witnessed generation of two grants, reserves
// its witnessed owner and returns the recovery that follows it. Each target
// request counts toward puts.
func witnessedRecoveryPair(t *testing.T) (*Recovery, allocatoradmission.RecoveryReservation, *nakamastoragetest.Fake, *witnessTable, *atomic.Int32) {
	t.Helper()
	var puts atomic.Int32
	api := generationAPI(t, "")
	_, gen := generationFixture(t, func(w http.ResponseWriter, req *http.Request) {
		if req.Method == http.MethodPut {
			puts.Add(1)
		}
		api(w, req)
	})
	storage := nakamastoragetest.New()
	table := newWitnessTable()
	g, err := NewDurableGeneration(context.Background(), DurableGenerationConfig{
		Enabled: true, Commit: gen.Commit, Record: gen.Record, IncarnationID: "incarnation-1", Storage: storage,
		Witness: GenerationWitnessConfig{Enabled: true, Witness: clientWitness{witnessClient(t, table)}},
	})
	if err != nil {
		t.Fatal(err)
	}
	generationPrepare(t, g, "pod-a", "zone-a")
	generationPrepare(t, g, "pod-b", "zone-b")
	binding, version, err := g.CloseForRecovery(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	owner, err := allocatoradmission.NewRecoveryOwner(allocatoradmission.RecoveryOwnerConfig{
		Enabled: true, Storage: storage, Binding: binding, HandoffVersion: version, OwnerID: "recoverer-1",
		Witness: allocatoradmission.RecoveryOwnerWitnessConfig{
			Enabled: true, Witness: clientWitness{witnessClient(t, table)}, Handoff: g.state.durable.witness.acked,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := owner.Reserve(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	commit := gen.Commit
	commit.Enabled = true
	recovery, err := NewRecovery(commit, reservation)
	if err != nil {
		t.Fatal(err)
	}
	puts.Store(0)
	return recovery, reservation, storage, table, &puts
}

// armWitness applies one witness fault to the table's next write. A conflict is
// a rival recoverer's valid record at the same stage, stored first.
func armWitness(t *testing.T, table *witnessTable, previous allocatoradmission.WitnessRecord, stage, fault string) {
	t.Helper()
	if fault != "conflicting" {
		table.arm(fault)
		return
	}
	rival := previous
	rival.Stage = stage
	if stage == WitnessRecovered {
		rival.RecoveredPin = previous.RegistrationPin
	} else {
		rival.PublishedPin = previous.RegistrationPin
	}
	if _, err := witnessClient(t, table).WriteGeneration(context.Background(), toCustody(previous), toCustody(rival)); err != nil {
		t.Fatal(err)
	}
}

// The full chain ends at exactly the recoverer's own record, one conditional
// write per stage, and each result waits for its stage.
func TestWitnessedRecoveryChainEndsAtTheRecoverersRecord(t *testing.T) {
	recovery, reservation, storage, table, puts := witnessedRecoveryPair(t)
	writes := table.puts
	complete, err := recovery.Fence(context.Background())
	if err != nil {
		t.Fatalf("witnessed recovery refused: %v", err)
	}
	own, err := reservation.Witnessed()
	if err != nil || own.Stage != WitnessRecovered || own.RecoveredPin == "" || table.puts != writes+1 || puts.Load() != 2 {
		t.Fatalf("recovered record: %+v, %d witness writes, %d barriers: %v", own, table.puts-writes, puts.Load(), err)
	}
	publisher, err := NewRecoveryPublisher(PublicationConfig{Enabled: true, Storage: storage}, complete)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = publisher.Publish(context.Background()); err != nil {
		t.Fatalf("witnessed publication refused: %v", err)
	}
	own, err = reservation.Witnessed()
	if err != nil || own.Stage != WitnessPublished || own.PublishedPin == "" || own.PublishedPin == own.RecoveredPin || table.puts != writes+2 {
		t.Fatalf("published record: %+v: %v", own, err)
	}
	client := witnessClient(t, table)
	if got := client.CompareGeneration(context.Background(), toCustody(own)); got != custodywitness.Verified {
		t.Fatalf("witness disagrees with the recoverer's record: %s", got)
	}
}

// A refused witness returns no recovery authority and repeats no barrier; a
// lost reply the exact re-read finds is acknowledged.
func TestWitnessRefusalAtRecoveredReturnsNoAuthority(t *testing.T) {
	for _, fault := range []string{"rejected", "conflicting", "unavailable", "lost-uncommitted", "lost-unreadable", "lost-committed"} {
		t.Run(fault, func(t *testing.T) {
			recovery, reservation, storage, table, puts := witnessedRecoveryPair(t)
			before, err := reservation.Witnessed()
			if err != nil {
				t.Fatal(err)
			}
			armWitness(t, table, before, WitnessRecovered, fault)
			complete, err := recovery.Fence(context.Background())
			if fault == "lost-committed" {
				if err != nil {
					t.Fatalf("committed stage with a lost reply refused: %v", err)
				}
				return
			}
			if !errors.Is(err, ErrUnknown) || complete != (RecoveryResult{}) {
				t.Fatalf("unwitnessed recovery returned: %v", err)
			}
			if got, _ := reservation.Witnessed(); got != before {
				t.Fatalf("refused stage moved the record: %+v", got)
			}
			barriers := puts.Load()
			if _, err = recovery.Fence(context.Background()); !errors.Is(err, ErrClosed) || puts.Load() != barriers {
				t.Fatalf("refused recovery repeated barriers: %v after %d", err, puts.Load())
			}
			if _, err = NewRecoveryPublisher(PublicationConfig{Enabled: true, Storage: storage}, complete); err == nil {
				t.Fatal("publisher formed from a refused recovery")
			}
		})
	}
}

// A refused witness returns no publication result; the proof row stays behind
// unwitnessed, and the attempt is spent.
func TestWitnessRefusalAtPublishedReturnsNoResult(t *testing.T) {
	for _, fault := range []string{"rejected", "conflicting", "unavailable", "lost-uncommitted", "lost-unreadable", "lost-committed"} {
		t.Run(fault, func(t *testing.T) {
			recovery, reservation, storage, table, _ := witnessedRecoveryPair(t)
			complete, err := recovery.Fence(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			before, err := reservation.Witnessed()
			if err != nil {
				t.Fatal(err)
			}
			publisher, err := NewRecoveryPublisher(PublicationConfig{Enabled: true, Storage: storage}, complete)
			if err != nil {
				t.Fatal(err)
			}
			armWitness(t, table, before, WitnessPublished, fault)
			result, err := publisher.Publish(context.Background())
			if fault == "lost-committed" {
				if err != nil {
					t.Fatalf("committed stage with a lost reply refused: %v", err)
				}
				return
			}
			if !errors.Is(err, ErrUnknown) || result != (PublicationResult{}) {
				t.Fatalf("unwitnessed publication returned: %v", err)
			}
			if got, _ := reservation.Witnessed(); got != before {
				t.Fatalf("refused stage moved the record: %+v", got)
			}
			if _, err = publisher.Accept(result); !errors.Is(err, ErrClosed) {
				t.Fatalf("unwitnessed publication accepted: %v", err)
			}
			if _, err = publisher.Publish(context.Background()); !errors.Is(err, ErrClosed) {
				t.Fatalf("spent publication retried: %v", err)
			}
			key := RecoveryProofKey(reservationGeneration(t, reservation))
			if _, found := storage.Get(RecoveryProofCollection, key, ""); !found {
				t.Fatal("control: the proof row was never written")
			}
		})
	}
}

// The recovered pin binds every barrier acknowledgement and the owner row.
func TestWitnessRecoveredPinBindsEveryBarrier(t *testing.T) {
	got := RecoveryObservation{Grants: []GenerationGrantObservation{
		{ActorUID: "a", AttemptID: "1", Observation: Observation{Name: "zone-a", BarrierVersion: "v1"}},
		{ActorUID: "b", AttemptID: "2", Observation: Observation{Name: "zone-b", BarrierVersion: "v2"}},
	}}
	own, err := witnessRecoveredPin(got)
	if err != nil {
		t.Fatal(err)
	}
	owner := got
	owner.Owner.Version = "other"
	barrier := got
	barrier.Grants = []GenerationGrantObservation{got.Grants[0], got.Grants[1]}
	barrier.Grants[1].BarrierVersion = "other"
	missing := got
	missing.Grants = got.Grants[:1]
	for name, other := range map[string]RecoveryObservation{"owner": owner, "barrier": barrier, "missing grant": missing} {
		if pin, err := witnessRecoveredPin(other); err != nil || pin == own {
			t.Fatalf("%s pins the same recovery: %v", name, err)
		}
	}
}

// reservationGeneration reads the generation a live reservation recovers.
func reservationGeneration(t *testing.T, reservation allocatoradmission.RecoveryReservation) string {
	t.Helper()
	own, err := reservation.Witnessed()
	if err != nil {
		t.Fatal(err)
	}
	if own.GenerationKey != allocatoradmission.Key(generationRecord().GenerationID) {
		t.Fatal("reservation of another generation")
	}
	return generationRecord().GenerationID
}

// Neither result is accepted while its stage's witness write is still running.
func TestWitnessedRecoveryAcceptsNothingBeforeItsStage(t *testing.T) {
	recovery, _, storage, table, _ := witnessedRecoveryPair(t)
	writes := 0
	table.onPut = func() {
		writes++
		if recovery.state.accepted.Load() != nil {
			t.Error("recovery accepted before the witness held recovered")
		}
	}
	complete, err := recovery.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	publisher, err := NewRecoveryPublisher(PublicationConfig{Enabled: true, Storage: storage}, complete)
	if err != nil {
		t.Fatal(err)
	}
	table.onPut = func() {
		writes++
		if publisher.state.accepted.Load() != nil {
			t.Error("publication accepted before the witness held published")
		}
	}
	if _, err = publisher.Publish(context.Background()); err != nil {
		t.Fatal(err)
	}
	if writes != 2 {
		t.Fatalf("observed %d witness writes", writes)
	}
}

// The published pin binds the proof's key and acknowledged version.
func TestWitnessPublishedPinBindsTheAcknowledgedProof(t *testing.T) {
	own, err := witnessPublishedPin("generation-a", "v1")
	if err != nil || own == "" {
		t.Fatalf("own pin: %q, %v", own, err)
	}
	for name, other := range map[string][2]string{"generation": {"generation-b", "v1"}, "version": {"generation-a", "v2"}} {
		if pin, err := witnessPublishedPin(other[0], other[1]); err != nil || pin == own {
			t.Fatalf("other %s pins the same proof: %v", name, err)
		}
	}
}
