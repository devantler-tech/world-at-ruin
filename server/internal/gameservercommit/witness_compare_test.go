package gameservercommit

import (
	"context"
	"errors"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/custodywitness"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/runtime"
)

// The verdict a recoverer accepts is the witness family's own.
func TestWitnessVerifiedIsTheFamilysPositiveVerdict(t *testing.T) {
	if allocatoradmission.WitnessVerified != string(custodywitness.Verified) {
		t.Fatal("the positive verdict drifted from the witness client")
	}
}

func dropRow(t *testing.T, storage *nakamastoragetest.Fake, collection, key string) {
	t.Helper()
	if _, found := storage.Get(collection, key, ""); !found {
		t.Fatalf("restore control: no %s row to drop", collection)
	}
	if err := storage.StorageDelete(context.Background(), []*runtime.StorageDelete{{Collection: collection, Key: key}}); err != nil {
		t.Fatal(err)
	}
}

// publishedRecovery runs a witnessed recovery through to `published`.
func publishedRecovery(t *testing.T) (RecoveryObservation, PublicationPins, WitnessRecord, *nakamastoragetest.Fake, *witnessTable) {
	t.Helper()
	recovery, reservation, storage, table, _ := witnessedRecoveryPair(t)
	publisher, _ := fencedPublisher(t, recovery, storage)
	result, err := publisher.Publish(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	pins, err := publisher.Accept(result)
	if err != nil {
		t.Fatal(err)
	}
	own, err := reservation.Witnessed()
	if err != nil || own.Stage != WitnessPublished {
		t.Fatalf("published record: %+v: %v", own, err)
	}
	return pins.Recovery, pins, own, storage, table
}

// refusedBeforeAnyTarget asserts a fresh recoverer on cfg gets no reservation,
// writes no owner row and no witness record, and reaches no game server.
func refusedBeforeAnyTarget(t *testing.T, cfg allocatoradmission.RecoveryOwnerConfig, storage *nakamastoragetest.Fake, table *witnessTable) {
	t.Helper()
	writes := table.puts
	owner, err := allocatoradmission.NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := owner.Reserve(context.Background())
	if !errors.Is(err, allocatoradmission.ErrUnknown) || reservation != (allocatoradmission.RecoveryReservation{}) {
		t.Fatalf("restored history reserved: %v", err)
	}
	if _, found := storage.Get(allocatoradmission.RecoveryOwnerCollection, allocatoradmission.RecoveryOwnerKey(cfg.Binding.GenerationID), ""); found {
		t.Fatal("restored history wrote an owner row")
	}
	if table.puts != writes {
		t.Fatalf("restored history wrote the witness %d times", table.puts-writes)
	}
	reachesNoTarget(t, reservation)
}

// A restore that drops one registration leaves a self-consistent smaller
// history, whose pins all re-derive. Only the witness knows there was more, and
// the differing grant count makes the comparison conflicting.
func TestRecoveryKeepsQuarantineWhenARestoreDropsARegistration(t *testing.T) {
	original := newWitnessTable()
	g := twoGrantGeneration(t, original)
	if _, _, err := g.CloseForRecovery(context.Background()); err != nil {
		t.Fatal(err)
	}
	restored := nakamastoragetest.New()
	cfg, _ := closedWitnessedGeneration(t, restored)
	cfg.Witness.Witness = clientWitness{witnessClient(t, original)}
	if got := witnessClient(t, original).CompareGeneration(context.Background(), toCustody(cfg.Witness.Handoff)); got != custodywitness.Conflicting {
		t.Fatalf("restored registration compared %s", got)
	}
	refusedBeforeAnyTarget(t, cfg, restored, original)
}

// A restore that drops the handoff leaves history at `drained`, which the witness
// is ahead of. The retained pins name a handoff Nakama no longer holds.
func TestRecoveryKeepsQuarantineWhenARestoreDropsTheHandoff(t *testing.T) {
	storage := nakamastoragetest.New()
	cfg, table := closedWitnessedGeneration(t, storage)
	drained := cfg.Witness.Handoff
	drained.Stage, drained.HandoffPin = WitnessDrained, ""
	if got := witnessClient(t, table).CompareGeneration(context.Background(), toCustody(drained)); got != custodywitness.WitnessAhead {
		t.Fatalf("restored drain compared %s", got)
	}
	dropRow(t, storage, allocatoradmission.HandoffCollection, allocatoradmission.HandoffKey(cfg.Binding.GenerationID))
	refusedBeforeAnyTarget(t, cfg, storage, table)
}

// A restore to before the proof and the owner row is a history the witness has
// moved past, so a fresh recoverer holding the handoff pins is refused. Dropping
// only the proof also fails the read-only verification of the completed chain.
func TestRecoveryKeepsQuarantineWhenARestoreDropsTheProof(t *testing.T) {
	complete, pins, published, storage, table := publishedRecovery(t)
	owner := complete.Owner
	binding := owner.Handoff.Journal.Binding
	dropRow(t, storage, RecoveryProofCollection, RecoveryProofKey(binding.GenerationID))
	if _, err := ReadRecoveryPublication(context.Background(), PublicationReadConfig{
		Enabled: true, Storage: storage, Pins: pins,
		Witness: PublicationWitnessConfig{Enabled: true, Witness: clientWitness{witnessClient(t, table)}, Published: published},
	}); !errors.Is(err, ErrUnknown) {
		t.Fatalf("dropped proof verified: %v", err)
	}
	dropRow(t, storage, allocatoradmission.RecoveryOwnerCollection, allocatoradmission.RecoveryOwnerKey(binding.GenerationID))
	handoff := published
	handoff.Stage, handoff.OwnerPin, handoff.RecoveredPin, handoff.PublishedPin = WitnessHandoff, "", "", ""
	cfg := allocatoradmission.RecoveryOwnerConfig{
		Enabled: true, Storage: storage, Binding: binding, HandoffVersion: owner.HandoffVersion, OwnerID: "recoverer-2",
		Witness: allocatoradmission.RecoveryOwnerWitnessConfig{Enabled: true, Witness: clientWitness{witnessClient(t, table)}, Handoff: handoff},
	}
	refusedBeforeAnyTarget(t, cfg, storage, table)
}

// fenceChange is what a case may change between the reservation and the fence.
type fenceChange struct {
	t       *testing.T
	storage *nakamastoragetest.Fake
	table   *witnessTable
	own     WitnessRecord
	id      string
}

// Whatever changed between the reservation and the fence, a recovery ends with
// zero barrier I/O, its inventory spent and its retained record unmoved.
func TestFenceComparesBeforeAnyBarrier(t *testing.T) {
	for name, change := range map[string]func(fenceChange){
		"journal dropped": func(c fenceChange) {
			dropRow(c.t, c.storage, allocatoradmission.Collection, allocatoradmission.Key(c.id))
		},
		"handoff dropped": func(c fenceChange) {
			dropRow(c.t, c.storage, allocatoradmission.HandoffCollection, allocatoradmission.HandoffKey(c.id))
		},
		"owner row dropped": func(c fenceChange) {
			dropRow(c.t, c.storage, allocatoradmission.RecoveryOwnerCollection, allocatoradmission.RecoveryOwnerKey(c.id))
		},
		"witness ahead": func(c fenceChange) {
			armWitness(c.t, c.table, c.own, WitnessRecovered, "conflicting")
		},
		"witness behind": func(c fenceChange) {
			earlier := c.own
			earlier.Stage, earlier.OwnerPin = WitnessHandoff, ""
			value, err := custodywitness.EncodeGenerationRecord(toCustody(earlier))
			if err != nil {
				c.t.Fatal(err)
			}
			c.table.setEvery(value)
		},
		"witness conflicting": func(c fenceChange) {
			c.table.setEvery("not a witness record")
		},
		"witness absent": func(c fenceChange) {
			c.table.mu.Lock()
			defer c.table.mu.Unlock()
			clear(c.table.rows)
		},
		"witness table replaced": func(c fenceChange) {
			c.table.arm("replaced")
		},
		"witness unavailable": func(c fenceChange) {
			c.table.arm("unavailable")
		},
	} {
		t.Run(name, func(t *testing.T) {
			recovery, reservation, storage, table, puts := witnessedRecoveryPair(t)
			own, err := reservation.Witnessed()
			if err != nil {
				t.Fatal(err)
			}
			change(fenceChange{t, storage, table, own, reservationGeneration(t, reservation)})
			writes := table.puts
			complete, err := recovery.Fence(context.Background())
			if !errors.Is(err, ErrUnknown) || complete != (RecoveryResult{}) {
				t.Fatalf("recovery returned: %v", err)
			}
			if puts.Load() != 0 || table.puts != writes {
				t.Fatalf("refusal performed %d barriers and %d witness writes", puts.Load(), table.puts-writes)
			}
			if got, _ := reservation.Witnessed(); got != own {
				t.Fatalf("refusal moved the record: %+v", got)
			}
			if _, err = recovery.Fence(context.Background()); !errors.Is(err, ErrClosed) || puts.Load() != 0 {
				t.Fatalf("refused recovery retried: %v after %d barriers", err, puts.Load())
			}
		})
	}
}

// A matching completed chain verifies read-only: nothing is written, and the
// verification gives a later recoverer nothing. Any disagreement returns nothing.
func TestCompletedChainAllowsReadOnlyVerificationOnly(t *testing.T) {
	complete, pins, published, storage, table := publishedRecovery(t)
	reader := clientWitness{witnessClient(t, table)}
	read := func(c PublicationWitnessConfig, p PublicationPins) (RecoveryObservation, error) {
		return ReadRecoveryPublication(context.Background(), PublicationReadConfig{Enabled: true, Storage: storage, Pins: p, Witness: c})
	}
	writes := table.puts
	got, err := read(PublicationWitnessConfig{Enabled: true, Witness: reader, Published: published}, pins)
	if err != nil || got.Owner.OwnerID != complete.Owner.OwnerID || table.puts != writes {
		t.Fatalf("completed chain: %v after %d writes", err, table.puts-writes)
	}
	if _, err = read(PublicationWitnessConfig{}, pins); err != nil {
		t.Fatalf("no witness composed: %v", err)
	}
	binding := complete.Owner.Handoff.Journal.Binding
	handoff := published
	handoff.Stage, handoff.OwnerPin, handoff.RecoveredPin, handoff.PublishedPin = WitnessHandoff, "", "", ""
	refusedOwner, err := allocatoradmission.NewRecoveryOwner(allocatoradmission.RecoveryOwnerConfig{
		Enabled: true, Storage: storage, Binding: binding, HandoffVersion: complete.Owner.HandoffVersion, OwnerID: "recoverer-2",
		Witness: allocatoradmission.RecoveryOwnerWitnessConfig{Enabled: true, Witness: reader, Handoff: handoff},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = refusedOwner.Reserve(context.Background()); !errors.Is(err, allocatoradmission.ErrUnknown) {
		t.Fatalf("verified chain let a recoverer reserve: %v", err)
	}
	for name, c := range map[string]func(*PublicationWitnessConfig){
		"half configured":     func(c *PublicationWitnessConfig) { c.Enabled = false },
		"no reader":           func(c *PublicationWitnessConfig) { c.Witness = nil },
		"typed nil reader":    func(c *PublicationWitnessConfig) { c.Witness = (*faultAfter)(nil) },
		"not the proof's pin": func(c *PublicationWitnessConfig) { c.Published.PublishedPin = c.Published.RecoveredPin },
		"not the barriers":    func(c *PublicationWitnessConfig) { c.Published.RecoveredPin = c.Published.DrainPin },
		"not the owner":       func(c *PublicationWitnessConfig) { c.Published.OwnerPin = c.Published.DrainPin },
		"not the handoff":     func(c *PublicationWitnessConfig) { c.Published.HandoffPin = c.Published.DrainPin },
		"not the drain":       func(c *PublicationWitnessConfig) { c.Published.DrainPin = c.Published.HandoffPin },
		"earlier stage":       func(c *PublicationWitnessConfig) { c.Published.Stage = WitnessRecovered },
		"no registration":     func(c *PublicationWitnessConfig) { c.Published.RegistrationPin = "" },
		"other registration": func(c *PublicationWitnessConfig) {
			c.Published.RegistrationPin = c.Published.DrainPin
		},
	} {
		t.Run(name, func(t *testing.T) {
			cfg := PublicationWitnessConfig{Enabled: true, Witness: reader, Published: published}
			c(&cfg)
			if _, err := read(cfg, pins); !errors.Is(err, ErrUnknown) {
				t.Fatalf("verified: %v", err)
			}
		})
	}
	t.Run("witness unavailable", func(t *testing.T) {
		table.arm("unavailable")
		defer table.arm("")
		if _, err := read(PublicationWitnessConfig{Enabled: true, Witness: reader, Published: published}, pins); !errors.Is(err, ErrUnknown) {
			t.Fatalf("verified: %v", err)
		}
	})
}

// A proof stored but never witnessed is the matrix's partial publication: the
// witness is behind it, so it is not complete evidence.
func TestPartialPublicationIsNotCompleteEvidence(t *testing.T) {
	recovery, reservation, storage, table, _ := witnessedRecoveryPair(t)
	publisher, complete := fencedPublisher(t, recovery, storage)
	accepted, err := recovery.Accept(complete)
	if err != nil {
		t.Fatal(err)
	}
	recovered, err := reservation.Witnessed()
	if err != nil {
		t.Fatal(err)
	}
	table.arm("lost-uncommitted")
	if _, err = publisher.Publish(context.Background()); !errors.Is(err, ErrUnknown) {
		t.Fatalf("unwitnessed publication returned: %v", err)
	}
	table.arm("")
	row, found := storage.Get(RecoveryProofCollection, RecoveryProofKey(reservationGeneration(t, reservation)), "")
	if !found {
		t.Fatal("control: the proof row was never written")
	}
	pins := PublicationPins{Version: row.Version, Recovery: accepted}
	pin, err := witnessPublishedPin(reservationGeneration(t, reservation), pins.Version)
	if err != nil {
		t.Fatal(err)
	}
	published := recovered
	published.Stage, published.PublishedPin = WitnessPublished, pin
	reader := clientWitness{witnessClient(t, table)}
	if got := reader.CompareGeneration(context.Background(), published); got != string(custodywitness.WitnessBehind) {
		t.Fatalf("partial publication compared %s", got)
	}
	if _, err = ReadRecoveryPublication(context.Background(), PublicationReadConfig{
		Enabled: true, Storage: storage, Pins: pins,
		Witness: PublicationWitnessConfig{Enabled: true, Witness: reader, Published: published},
	}); !errors.Is(err, ErrUnknown) {
		t.Fatalf("partial publication verified: %v", err)
	}
}

// A custodian that dies before its write leaves the witness at `handoff`, and one
// that dies after it leaves `owner` with nobody told. Either way the recoverer
// holds nothing and the next one stays refused, by the row or by the witness.
func TestCustodianDeathAtOwnerKeepsTheQuarantine(t *testing.T) {
	for _, tc := range []struct {
		name, fault string
		verdict     custodywitness.Verdict
	}{
		{"before its write", "lost-uncommitted", custodywitness.Verified},
		{"after its write", "lost-unreadable", custodywitness.WitnessAhead},
	} {
		t.Run(tc.name, func(t *testing.T) {
			storage := nakamastoragetest.New()
			cfg, table := closedWitnessedGeneration(t, storage)
			owner, err := allocatoradmission.NewRecoveryOwner(cfg)
			if err != nil {
				t.Fatal(err)
			}
			table.onPut = func() { table.arm(tc.fault) }
			if _, err = owner.Reserve(context.Background()); !errors.Is(err, allocatoradmission.ErrUnknown) {
				t.Fatalf("dead custodian's owner returned: %v", err)
			}
			table.onPut = nil
			table.arm("")
			if got := witnessClient(t, table).CompareGeneration(context.Background(), toCustody(cfg.Witness.Handoff)); got != tc.verdict {
				t.Fatalf("after the death the handoff compares %s", got)
			}
			cfg.OwnerID = "recoverer-2"
			next, err := allocatoradmission.NewRecoveryOwner(cfg)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = next.Reserve(context.Background()); !errors.Is(err, allocatoradmission.ErrUnknown) {
				t.Fatalf("next recoverer reserved: %v", err)
			}
		})
	}
}
