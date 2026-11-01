package allocatoradmission

import (
	"context"
	"errors"
	"testing"
)

// fakeWitness records its calls and answers with err, after running during.
type fakeWitness struct {
	previous, next []WitnessRecord
	err            error
	during         func()
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
	own, err := reservation.WitnessedOwner()
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
	own, err := witnessOwnerPin(cfg, "v1")
	if err != nil || own == "" {
		t.Fatalf("own pin: %q, %v", own, err)
	}
	otherOwner, otherHandoff, otherDrain := cfg, cfg, cfg
	otherOwner.OwnerID += "-other"
	otherHandoff.HandoffVersion += "-other"
	otherDrain.Binding.Version += "-other"
	for name, got := range map[string]RecoveryOwnerConfig{"owner": otherOwner, "handoff": otherHandoff, "drain": otherDrain} {
		if pin, err := witnessOwnerPin(got, "v1"); err != nil || pin == own {
			t.Fatalf("other %s pins the same row: %v", name, err)
		}
	}
	if pin, err := witnessOwnerPin(cfg, "v2"); err != nil || pin == own {
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
	if _, err = reservation.WitnessedOwner(); !errors.Is(err, ErrClosed) {
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
	owner, err := NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := owner.Reserve(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = reservation.WitnessedOwner(); !errors.Is(err, ErrClosed) {
		t.Fatalf("witness record without a witness: %v", err)
	}
	if _, err = owner.Accept(reservation); err != nil {
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
func TestWitnessedOwnerRequiresTheLiveAcceptance(t *testing.T) {
	_, cfg := recoveryFixture(t)
	cfg.Witness = RecoveryOwnerWitnessConfig{Enabled: true, Witness: &fakeWitness{}, Handoff: witnessedHandoff(t, cfg)}
	owner, err := NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := owner.Reserve(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	copied := *reservation.observation
	reservation.observation = &copied
	if _, err = reservation.WitnessedOwner(); !errors.Is(err, ErrClosed) {
		t.Fatalf("record returned without the live acceptance: %v", err)
	}
}
