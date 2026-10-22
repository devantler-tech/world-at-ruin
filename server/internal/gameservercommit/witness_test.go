package gameservercommit

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/internal/custodywitness"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

var witnessTableID = custodywitness.TableIdentity{ID: "witness-table", CreatedAt: time.Unix(1700000000, 0).UTC()}

// witnessTable is a strongly consistent map behind the real witness client.
// fault selects how the next calls end once it is armed.
type witnessTable struct {
	mu    sync.Mutex
	rows  map[string]string
	puts  int
	fault string
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
	_, cfg := generationFixture(t, generationAPI(t, ""))
	return NewDurableGeneration(context.Background(), DurableGenerationConfig{
		Enabled: true, Commit: cfg.Commit, Record: cfg.Record, IncarnationID: "incarnation-1",
		Storage: nakamastoragetest.New(),
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
	}
}

// The local stage names are the witness family's own.
func TestWitnessStagesAreTheGenerationFamilyStages(t *testing.T) {
	if WitnessRegistered != string(custodywitness.GenerationRegistered) || WitnessDrained != string(custodywitness.GenerationDrained) ||
		WitnessHandoff != string(custodywitness.GenerationHandoff) {
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
// set is refused before any witness write.
func TestWitnessHandoffRefusesAForeignBinding(t *testing.T) {
	g, table := grantedWitnessedGeneration(t)
	if _, err := g.Fence(context.Background()); err != nil {
		t.Fatal(err)
	}
	witness := g.state.durable.witness
	own := allocatorjournal.JournalBinding{
		GenerationID: generationRecord().GenerationID, IssuedCount: witness.acked.GrantCount, IssuedDigest: witness.acked.IssuedDigest,
	}
	puts := table.puts
	for name, mutate := range map[string]func(*allocatorjournal.JournalBinding){
		"other generation": func(b *allocatorjournal.JournalBinding) { b.GenerationID = "generation-other" },
		"other count":      func(b *allocatorjournal.JournalBinding) { b.IssuedCount++ },
		"other issued set": func(b *allocatorjournal.JournalBinding) { b.IssuedDigest = witness.acked.RegistrationPin },
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
		rival.HandoffPin = next.RegistrationPin
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
