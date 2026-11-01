package allocatoradmission

import (
	"context"
	"errors"
	"testing"

	"github.com/heroiclabs/nakama-common/api"
)

// fakeWitness records its calls and answers with err, after running during.
type fakeWitness struct {
	previous, next []WitnessRecord
	err            error
	during         func()
	verdict        string
	compared       []WitnessRecord
}

// CompareGeneration answers verified unless told otherwise.
func (f *fakeWitness) CompareGeneration(_ context.Context, expected WitnessRecord) string {
	f.compared = append(f.compared, expected)
	if f.verdict != "" {
		return f.verdict
	}
	return WitnessVerified
}

func (f *fakeWitness) WriteGeneration(_ context.Context, previous, next WitnessRecord) error {
	f.previous, f.next = append(f.previous, previous), append(f.next, next)
	if f.during != nil {
		f.during()
	}
	return f.err
}

// witnessedHandoff is the handoff record the generation's own witness would
// hold for this recovery configuration.
func witnessedHandoff(t *testing.T, cfg RecoveryOwnerConfig) WitnessRecord {
	t.Helper()
	drain, err := WitnessStagePin(WitnessDrained, cfg.Binding)
	if err != nil {
		t.Fatal(err)
	}
	handoff, err := WitnessHandoffPin(cfg.Binding, cfg.HandoffVersion)
	if err != nil {
		t.Fatal(err)
	}
	return WitnessRecord{
		GenerationKey: Key(cfg.Binding.GenerationID), Stage: WitnessHandoff, GrantCount: cfg.Binding.IssuedCount,
		IssuedDigest: cfg.Binding.IssuedDigest, RegistrationPin: "registration-pin", DrainPin: drain, HandoffPin: handoff,
	}
}

// The reservation waits for the witness: the row is written first, nothing is
// accepted while the witness call runs, and `owner` advances from exactly the
// retained handoff record, changing nothing but its stage and pin.
func TestReserveWithholdsTheReservationUntilTheWitnessAcknowledges(t *testing.T) {
	s, cfg := recoveryFixture(t)
	witness := &fakeWitness{}
	cfg.Witness = RecoveryOwnerWitnessConfig{Enabled: true, Witness: witness, Handoff: witnessedHandoff(t, cfg)}
	owner, err := NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	witness.during = func() {
		if s.writes != 1 || owner.state.accepted.Load() != nil {
			t.Errorf("witness ran with %d row writes and accepted=%v", s.writes, owner.state.accepted.Load())
		}
	}
	reservation, err := owner.Reserve(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	own, err := reservation.Witnessed()
	if err != nil {
		t.Fatal(err)
	}
	want := cfg.Witness.Handoff
	want.Stage, want.OwnerPin = WitnessOwner, own.OwnerPin
	if own != want || own.OwnerPin == "" || len(witness.next) != 1 || witness.next[0] != own || witness.previous[0] != cfg.Witness.Handoff {
		t.Fatalf("witnessed owner: %+v, calls %+v from %+v", own, witness.next, witness.previous)
	}
	if _, err = owner.Accept(reservation); err != nil {
		t.Fatal(err)
	}
}

// The owner pin binds who won and what they hold: any other owner, handoff or
// acknowledged version pins a different owner row.
func TestWitnessOwnerPinBindsTheAcknowledgedRow(t *testing.T) {
	_, cfg := recoveryFixture(t)
	own, err := WitnessOwnerPin(cfg, "v1")
	if err != nil || own == "" {
		t.Fatalf("own pin: %q, %v", own, err)
	}
	otherOwner, otherHandoff, otherDrain := cfg, cfg, cfg
	otherOwner.OwnerID += "-other"
	otherHandoff.HandoffVersion += "-other"
	otherDrain.Binding.Version += "-other"
	for name, got := range map[string]RecoveryOwnerConfig{"owner": otherOwner, "handoff": otherHandoff, "drain": otherDrain} {
		if pin, err := WitnessOwnerPin(got, "v1"); err != nil || pin == own {
			t.Fatalf("other %s pins the same row: %v", name, err)
		}
	}
	if pin, err := WitnessOwnerPin(cfg, "v2"); err != nil || pin == own {
		t.Fatalf("other acknowledged version pins the same row: %v", err)
	}
}

// A refusal returns no reservation, keeps no acceptance and ends the attempt;
// the row stays as the permanent exclusion.
func TestReserveReturnsNothingWhenTheWitnessRefuses(t *testing.T) {
	s, cfg := recoveryFixture(t)
	witness := &fakeWitness{err: errors.New("refused")}
	cfg.Witness = RecoveryOwnerWitnessConfig{Enabled: true, Witness: witness, Handoff: witnessedHandoff(t, cfg)}
	owner, err := NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := owner.Reserve(context.Background())
	if !errors.Is(err, ErrUnknown) || reservation != (RecoveryReservation{}) {
		t.Fatalf("unwitnessed reservation: %v", err)
	}
	if _, err = owner.Accept(reservation); !errors.Is(err, ErrClosed) {
		t.Fatalf("unwitnessed owner accepted: %v", err)
	}
	if _, err = reservation.Consume(); !errors.Is(err, ErrClosed) {
		t.Fatalf("unwitnessed reservation consumed: %v", err)
	}
	if _, err = reservation.Witnessed(); !errors.Is(err, ErrClosed) {
		t.Fatalf("unwitnessed record returned: %v", err)
	}
	if _, err = owner.Reserve(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("refused attempt retried: %v", err)
	}
	if s.writes != 1 || len(witness.next) != 1 {
		t.Fatalf("%d row writes and %d witness calls", s.writes, len(witness.next))
	}
}

// With no witness the row alone reserves, as before, and no record exists.
func TestRecoveryOwnerWithoutAWitnessHoldsNoRecord(t *testing.T) {
	_, cfg := recoveryFixture(t)
	owner, reservation := reservedOwner(t, cfg)
	if _, err := reservation.Witnessed(); !errors.Is(err, ErrClosed) {
		t.Fatalf("witness record without a witness: %v", err)
	}
	if _, err := owner.Accept(reservation); err != nil {
		t.Fatal(err)
	}
}

// A half-configured witness, or a handoff record that is not this recovery's
// exact witnessed handoff, is refused before storage is touched.
func TestRecoveryOwnerRefusesAnInexactWitnessConfiguration(t *testing.T) {
	var typedNil *fakeWitness
	witness := &fakeWitness{}
	for name, mutate := range map[string]func(*RecoveryOwnerWitnessConfig){
		"no witness":        func(c *RecoveryOwnerWitnessConfig) { c.Witness = nil },
		"typed nil":         func(c *RecoveryOwnerWitnessConfig) { c.Witness = typedNil },
		"witness only":      func(c *RecoveryOwnerWitnessConfig) { c.Enabled, c.Handoff = false, WitnessRecord{} },
		"record only":       func(c *RecoveryOwnerWitnessConfig) { c.Enabled, c.Witness = false, nil },
		"no record":         func(c *RecoveryOwnerWitnessConfig) { c.Handoff = WitnessRecord{} },
		"drained stage":     func(c *RecoveryOwnerWitnessConfig) { c.Handoff.Stage = WitnessDrained },
		"owner already":     func(c *RecoveryOwnerWitnessConfig) { c.Handoff.OwnerPin = "pin" },
		"recovered already": func(c *RecoveryOwnerWitnessConfig) { c.Handoff.RecoveredPin = "pin" },
		"published already": func(c *RecoveryOwnerWitnessConfig) { c.Handoff.PublishedPin = "pin" },
		"other generation":  func(c *RecoveryOwnerWitnessConfig) { c.Handoff.GenerationKey = Key("other") },
		"other count":       func(c *RecoveryOwnerWitnessConfig) { c.Handoff.GrantCount++ },
		"other issued set":  func(c *RecoveryOwnerWitnessConfig) { c.Handoff.IssuedDigest += "0" },
		"no registration":   func(c *RecoveryOwnerWitnessConfig) { c.Handoff.RegistrationPin = "" },
		"other drain":       func(c *RecoveryOwnerWitnessConfig) { c.Handoff.DrainPin = c.Handoff.HandoffPin },
		"other handoff pin": func(c *RecoveryOwnerWitnessConfig) { c.Handoff.HandoffPin = c.Handoff.DrainPin },
	} {
		t.Run(name, func(t *testing.T) {
			s, cfg := recoveryFixture(t)
			cfg.Witness = RecoveryOwnerWitnessConfig{Enabled: true, Witness: witness, Handoff: witnessedHandoff(t, cfg)}
			mutate(&cfg.Witness)
			if owner, err := NewRecoveryOwner(cfg); owner != nil || !errors.Is(err, ErrClosed) || s.writes != 0 {
				t.Fatalf("inexact witness accepted: %v", err)
			}
		})
	}
	_, cfg := recoveryFixture(t)
	cfg.Witness = RecoveryOwnerWitnessConfig{Enabled: true, Witness: witness, Handoff: witnessedHandoff(t, cfg)}
	cfg.HandoffVersion += "-other"
	if owner, err := NewRecoveryOwner(cfg); owner != nil || !errors.Is(err, ErrClosed) {
		t.Fatalf("witnessed handoff of another handoff version accepted: %v", err)
	}
	if len(witness.next) != 0 {
		t.Fatal("witness called during configuration")
	}
}

// Only the exact live acceptance returns the record: a reservation of a
// different observation does not, even when it holds an `owner` record.
func TestWitnessedRequiresTheLiveAcceptance(t *testing.T) {
	_, cfg := recoveryFixture(t)
	cfg.Witness = RecoveryOwnerWitnessConfig{Enabled: true, Witness: &fakeWitness{}, Handoff: witnessedHandoff(t, cfg)}
	_, reservation := reservedOwner(t, cfg)
	copied := *reservation.observation
	reservation.observation = &copied
	if _, err := reservation.Witnessed(); !errors.Is(err, ErrClosed) {
		t.Fatalf("record returned without the live acceptance: %v", err)
	}
}

// reservedOwner returns a recovery owner and its reservation.
func reservedOwner(t *testing.T, cfg RecoveryOwnerConfig) (*RecoveryOwner, RecoveryReservation) {
	t.Helper()
	var reservation RecoveryReservation
	owner, err := NewRecoveryOwner(cfg)
	if err == nil {
		reservation, err = owner.Reserve(context.Background())
	}
	if err != nil {
		t.Fatal(err)
	}
	return owner, reservation
}

// The recovery stages advance in order from the exact retained record, each
// changing only its stage and pin; a refused write leaves the record in place.
func TestAdvanceWitnessMovesForwardOneStageAtATime(t *testing.T) {
	witness, reservation := witnessedReservation(t)
	own, _ := reservation.Witnessed()
	if err := reservation.AdvanceWitness(context.Background(), WitnessPublished, "pin"); !errors.Is(err, ErrClosed) {
		t.Fatalf("published skipped recovered: %v", err)
	}
	if err := reservation.AdvanceWitness(context.Background(), WitnessOwner, "pin"); !errors.Is(err, ErrClosed) {
		t.Fatalf("owner repeated: %v", err)
	}
	if err := reservation.AdvanceWitness(context.Background(), WitnessRecovered, ""); !errors.Is(err, ErrClosed) {
		t.Fatalf("empty pin accepted: %v", err)
	}
	if len(witness.next) != 1 {
		t.Fatalf("refused stages reached the witness: %d calls", len(witness.next))
	}
	witness.err = errors.New("refused")
	if err := reservation.AdvanceWitness(context.Background(), WitnessRecovered, "recovered-pin"); !errors.Is(err, ErrUnknown) {
		t.Fatalf("refused write acknowledged: %v", err)
	}
	if got, _ := reservation.Witnessed(); got != own {
		t.Fatalf("refused write moved the record: %+v", got)
	}
	witness.err = nil
	if err := reservation.AdvanceWitness(context.Background(), WitnessRecovered, "recovered-pin"); err != nil {
		t.Fatal(err)
	}
	if err := reservation.AdvanceWitness(context.Background(), WitnessRecovered, "again"); !errors.Is(err, ErrClosed) {
		t.Fatalf("recovered repeated: %v", err)
	}
	if err := reservation.AdvanceWitness(context.Background(), WitnessPublished, "published-pin"); err != nil {
		t.Fatal(err)
	}
	want := own
	want.Stage, want.RecoveredPin, want.PublishedPin = WitnessPublished, "recovered-pin", "published-pin"
	got, _ := reservation.Witnessed()
	if got != want || witness.previous[len(witness.previous)-1].Stage != WitnessRecovered {
		t.Fatalf("chain ended at %+v, want %+v", got, want)
	}
}

// With no witness composed, advancing does nothing and a dead reservation is
// still refused.
func TestAdvanceWitnessWithoutAWitnessDoesNothing(t *testing.T) {
	_, cfg := recoveryFixture(t)
	_, reservation := reservedOwner(t, cfg)
	if err := reservation.AdvanceWitness(context.Background(), WitnessRecovered, "pin"); err != nil {
		t.Fatal(err)
	}
	if err := (RecoveryReservation{}).AdvanceWitness(context.Background(), WitnessRecovered, "pin"); !errors.Is(err, ErrClosed) {
		t.Fatalf("dead reservation advanced: %v", err)
	}
}

// Only the exact live acceptance advances: a reservation of a different
// observation does not, and the witness never hears of it.
func TestAdvanceWitnessRequiresTheLiveAcceptance(t *testing.T) {
	witness, reservation := witnessedReservation(t)
	copied := *reservation.observation
	reservation.observation = &copied
	if err := reservation.AdvanceWitness(context.Background(), WitnessRecovered, "pin"); !errors.Is(err, ErrClosed) || len(witness.next) != 1 {
		t.Fatalf("dead reservation advanced: %v after %d witness calls", err, len(witness.next))
	}
}

// witnessedReservation returns a live reservation whose witness holds `owner`.
func witnessedReservation(t *testing.T) (*fakeWitness, RecoveryReservation) {
	t.Helper()
	_, cfg := recoveryFixture(t)
	witness := &fakeWitness{}
	cfg.Witness = RecoveryOwnerWitnessConfig{Enabled: true, Witness: witness, Handoff: witnessedHandoff(t, cfg)}
	_, reservation := reservedOwner(t, cfg)
	return witness, reservation
}

// Every answer but verified refuses before the owner row is written, including
// one this package has never heard of.
func TestReserveRefusesEveryOtherVerdictBeforeTheRow(t *testing.T) {
	for _, verdict := range []string{"witness-ahead", "witness-behind", "absent", "conflicting", "table-replaced", "unavailable", "something-new"} {
		t.Run(verdict, func(t *testing.T) {
			storage, cfg := recoveryFixture(t)
			witness := &fakeWitness{verdict: verdict}
			cfg.Witness = RecoveryOwnerWitnessConfig{Enabled: true, Witness: witness, Handoff: witnessedHandoff(t, cfg)}
			owner, err := NewRecoveryOwner(cfg)
			if err != nil {
				t.Fatal(err)
			}
			writes := storage.writes
			if _, err = owner.Reserve(context.Background()); !errors.Is(err, ErrUnknown) {
				t.Fatalf("reserved on %s: %v", verdict, err)
			}
			if storage.writes != writes || len(witness.next) != 0 {
				t.Fatalf("refusal wrote %d rows and %d witness records", storage.writes-writes, len(witness.next))
			}
			if len(witness.compared) != 1 || witness.compared[0] != cfg.Witness.Handoff {
				t.Fatalf("compared %+v", witness.compared)
			}
		})
	}
}

// The comparison before the barriers names the exact owner record and accepts
// nothing but verified.
func TestVerifyWitnessComparesTheOwnerRecord(t *testing.T) {
	for _, verdict := range []string{"witness-ahead", "witness-behind", "absent", "conflicting", "table-replaced", "unavailable", "something-new"} {
		t.Run(verdict, func(t *testing.T) {
			witness, reservation := witnessedReservation(t)
			witness.verdict = verdict
			if err := reservation.VerifyWitness(context.Background()); !errors.Is(err, ErrUnknown) {
				t.Fatalf("verified on %s: %v", verdict, err)
			}
		})
	}
	witness, reservation := witnessedReservation(t)
	if err := reservation.VerifyWitness(context.Background()); err != nil {
		t.Fatal(err)
	}
	own, err := reservation.Witnessed()
	if err != nil || witness.compared[len(witness.compared)-1] != own {
		t.Fatalf("compared %+v, own %+v: %v", witness.compared, own, err)
	}
	if err = reservation.AdvanceWitness(context.Background(), WitnessRecovered, "recovered-pin"); err != nil {
		t.Fatal(err)
	}
	if err = reservation.VerifyWitness(context.Background()); !errors.Is(err, ErrUnknown) {
		t.Fatalf("verified past the owner stage: %v", err)
	}
	if err = (RecoveryReservation{}).VerifyWitness(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("zero reservation: %v", err)
	}
}

// With no witness composed there is nothing to compare and nothing to read.
func TestVerifyWitnessWithoutAWitnessDoesNothing(t *testing.T) {
	storage, cfg := recoveryFixture(t)
	_, reservation := reservedOwner(t, cfg)
	reads := storage.reads
	if err := reservation.VerifyWitness(context.Background()); err != nil || storage.reads != reads {
		t.Fatalf("no witness: %v after %d reads", err, storage.reads-reads)
	}
}

// Nakama must still hold this reservation's exact owner row, whatever the witness
// says: one a restore dropped or replaced refuses before the comparison.
func TestVerifyWitnessRequiresTheExactOwnerRow(t *testing.T) {
	for name, change := range map[string]func(*api.StorageObject) *api.StorageObject{
		"dropped":            func(*api.StorageObject) *api.StorageObject { return nil },
		"another version":    func(r *api.StorageObject) *api.StorageObject { r.Version = "owner-ack-2"; return r },
		"foreign collection": func(r *api.StorageObject) *api.StorageObject { r.Collection = "foreign"; return r },
		"foreign key":        func(r *api.StorageObject) *api.StorageObject { r.Key = "foreign"; return r },
		"foreign user":       func(r *api.StorageObject) *api.StorageObject { r.UserId = "foreign"; return r },
		"readable":           func(r *api.StorageObject) *api.StorageObject { r.PermissionRead = 1; return r },
		"writable":           func(r *api.StorageObject) *api.StorageObject { r.PermissionWrite = 1; return r },
		"unreadable":         func(r *api.StorageObject) *api.StorageObject { r.Value = "{}"; return r },
		"another owner": func(r *api.StorageObject) *api.StorageObject {
			got, err := DecodeRecoveryOwner(r.GetValue())
			if err != nil {
				t.Fatal(err)
			}
			got.OwnerID = "recoverer-other"
			if r.Value, err = EncodeRecoveryOwner(got); err != nil {
				t.Fatal(err)
			}
			return r
		},
	} {
		t.Run(name, func(t *testing.T) {
			storage, cfg := recoveryFixture(t)
			witness := &fakeWitness{}
			cfg.Witness = RecoveryOwnerWitnessConfig{Enabled: true, Witness: witness, Handoff: witnessedHandoff(t, cfg)}
			_, reservation := reservedOwner(t, cfg)
			compared := len(witness.compared)
			storage.row = change(storage.row)
			if err := reservation.VerifyWitness(context.Background()); !errors.Is(err, ErrUnknown) {
				t.Fatalf("verified: %v", err)
			}
			if len(witness.compared) != compared {
				t.Fatal("compared a record Nakama no longer holds")
			}
		})
	}
}

// A handoff read that differs from the one the owner reserved refuses, even with
// the same pins.
func TestVerifyWitnessRequiresTheReservedHandoff(t *testing.T) {
	witness, reservation := witnessedReservation(t)
	compared := len(witness.compared)
	reservation.observation.Handoff.Phase = "other"
	if err := reservation.VerifyWitness(context.Background()); !errors.Is(err, ErrUnknown) {
		t.Fatalf("verified: %v", err)
	}
	if len(witness.compared) != compared {
		t.Fatal("compared a record Nakama no longer holds")
	}
}
