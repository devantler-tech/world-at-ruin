package gameservercommit

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// A complete result, its copies and independent publisher wrappers must spend
// one shared attempt. Detached diagnostics cannot reconstruct this authority.
func TestRecoveryResultConsumesOnePublicationAttempt(t *testing.T) {
	r, _, _ := recoveryPair(t, generationAPI(t, ""), false)
	result, err := r.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	type consumer interface {
		consumePublication() (RecoveryObservation, error)
	}
	consume, ok := any(result).(consumer)
	if !ok {
		t.Fatal("complete result cannot consume its originating publication attempt")
	}
	got, err := consume.consumePublication()
	if err != nil || len(got.Grants) != 2 || got.Owner.OwnerID != "recoverer-1" {
		t.Fatal("complete originating inventory lost", err)
	}
	copy := result
	copiedConsumer, ok := any(copy).(consumer)
	if !ok {
		t.Fatal("copied result lost its publication boundary")
	}
	if _, err = copiedConsumer.consumePublication(); !errors.Is(err, ErrClosed) {
		t.Fatal("copied result restored a consumed publication attempt")
	}
	if _, ok = any(RecoveryObservation{}).(consumer); ok {
		t.Fatal("diagnostics reconstructed publication authority")
	}
}

// The fixture guard instruments this production decoder call. Expected fields
// are literal and retain every complete, mixed, allocated and empty shape.
func TestRecoveryProofKeepsEveryShippedSchemaReadable(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden_allocator_recovery_proof_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var documents []json.RawMessage
	if json.Unmarshal(raw, &documents) != nil || len(documents) != 4 {
		t.Fatal("historical proof shapes lost")
	}
	for i, document := range documents {
		got, err := DecodeRecoveryProof(string(document))
		want := historicalRecoveryProof(i)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("historical proof shape %d lost complete original binding: %+v %v", i, got, err)
		}
	}
}

// historicalRecoveryProof independently specifies every historical binding.
func historicalRecoveryProof(shape int) RecoveryObservation {
	original := []allocatorjournal.JournalGrant{{ActorUID: "pod-a", AttemptID: "attempt-a", Name: "zone-a", UID: "uid-a", SourceVersion: "resource-a"}, {ActorUID: "pod-b", AttemptID: "attempt-b", Name: "zone-b", UID: "uid-b", SourceVersion: "resource-b"}}
	binding := allocatorjournal.JournalBinding{GenerationID: "generation-1", GenerationVersion: "source-version-1", IncarnationID: "incarnation-1", Namespace: "trial", Fleet: "fleet", MemberPodUIDs: []string{"pod-a", "pod-b"}, MemberSetDigest: "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d", IssuedCount: 2, IssuedDigest: "4febaec6be92e850b2d08dd58cf55bb7e368994f597c35915286be3278f79226", Version: "root-version-4"}
	grants := []GenerationGrantObservation{{ActorUID: "pod-a", AttemptID: "attempt-a", Observation: Observation{Namespace: "trial", Name: "zone-a", UID: "uid-a", SourceVersion: "resource-a", BarrierVersion: "barrier-uid-a", Outcome: Uncommitted}}, {ActorUID: "pod-b", AttemptID: "attempt-b", Observation: Observation{Namespace: "trial", Name: "zone-b", UID: "uid-b", SourceVersion: "resource-b", BarrierVersion: "barrier-uid-b", Outcome: Uncommitted}}}
	if shape == 1 || shape == 2 {
		grants[1].Outcome = Allocated
	}
	if shape == 2 {
		grants[0].Outcome = Allocated
	}
	if shape == 3 {
		original = []allocatorjournal.JournalGrant{}
		grants = []GenerationGrantObservation{}
		binding.IssuedCount = 0
		binding.IssuedDigest = "fa56417bc7a979772aba3d458f0b5ff22a3462f45e74483a79859c7942fe60ef"
	}
	return RecoveryObservation{Owner: allocatoradmission.RecoveryOwnerObservation{OwnerID: "recoverer-1", Version: "owner-ack-1", HandoffVersion: "handoff-version-1", Handoff: allocatoradmission.Observation{Phase: "draining", Journal: allocatorjournal.JournalObservation{Binding: binding, Grants: original}}}, Grants: grants}
}

// Unknown/repeated/aliased/missing/null fields and changed complete-set evidence
// cannot be hidden by a plausible schema number or visible storage version.
func TestRecoveryProofRejectsMalformedOrIncompleteDocuments(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden_allocator_recovery_proof_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var documents []json.RawMessage
	if json.Unmarshal(raw, &documents) != nil {
		t.Fatal("fixture malformed")
	}
	base := string(documents[1])
	for _, value := range []string{
		strings.Replace(base, `"schema": 1`, `"schema": 2`, 1),
		strings.Replace(base, `"schema": 1`, `"schema": 1, "schema": 1`, 1),
		strings.Replace(base, `"schema": 1`, `"schema": 1, "Schema": 1`, 1),
		strings.Replace(base, `"schema": 1`, `"schema": 1, "unknown": 1`, 1),
		strings.Replace(base, `"owner_version": "owner-ack-1"`, `"owner_version": null`, 1),
		strings.Replace(base, `"owner_version": "owner-ack-1"`, `"owner_version": "*"`, 1),
		strings.Replace(base, `"owner_version": "owner-ack-1",`, ``, 1),
		strings.Replace(base, `"barrier_version": "barrier-uid-a"`, `"barrier_version": "resource-a"`, 1),
		strings.Replace(base, `"barrier_version": "barrier-uid-a"`, `"barrier_version": "*"`, 1),
		strings.Replace(base, `"barrier_version": "barrier-uid-a"`, `"barrier_version": null`, 1),
		strings.Replace(base, `"barrier_version": "barrier-uid-a"`, `"barrier_version": "barrier-uid-a", "barrier_version": "barrier-uid-a"`, 1),
		strings.Replace(base, `"barrier_version": "barrier-uid-a"`, `"barrier_version": "barrier-uid-a", "unknown": false`, 1),
		strings.Replace(base, `"outcome": "allocated-before-barrier"`, `"outcome": "unknown"`, 1),
		base + `{}`, string([]byte{0xff}), strings.Repeat(" ", (1<<20)+1),
	} {
		got, err := DecodeRecoveryProof(value)
		if !errors.Is(err, ErrUnknown) || !reflect.DeepEqual(got, RecoveryObservation{}) {
			t.Fatal("ambiguous proof exported diagnostics")
		}
	}
	for _, fault := range []string{"omitted", "actor", "attempt", "namespace", "name", "uid", "source", "order", "duplicate"} {
		got := historicalRecoveryProof(1)
		switch fault {
		case "omitted":
			got.Grants = got.Grants[:1]
		case "actor":
			got.Grants[0].ActorUID = "pod-b"
		case "attempt":
			got.Grants[0].AttemptID = "changed"
		case "namespace":
			got.Grants[0].Namespace = "changed"
		case "name":
			got.Grants[0].Name = "changed"
		case "uid":
			got.Grants[0].UID = "uid-b"
		case "source":
			got.Grants[0].SourceVersion = "changed"
		case "order":
			got.Grants[0], got.Grants[1] = got.Grants[1], got.Grants[0]
		case "duplicate":
			got.Grants[1] = got.Grants[0]
		}
		if _, err := encodeRecoveryProof(got); !errors.Is(err, ErrUnknown) {
			t.Fatal("incomplete or substituted grant became a complete proof:", fault)
		}
	}
}

// Defaults inspect no dependencies; a canceled attempt is spent before I/O.
func TestRecoveryPublicationDisabledInvalidAndCanceled(t *testing.T) {
	if p, err := NewRecoveryPublisher(PublicationConfig{}, RecoveryResult{}); p != nil || !errors.Is(err, ErrDisabled) {
		t.Fatal("disabled publication inspected dependencies")
	}
	for _, storage := range []PublicationConfig{{Enabled: true}, {Enabled: true, Storage: (*publicationStorage)(nil)}} {
		if p, err := NewRecoveryPublisher(storage, RecoveryResult{}); p != nil || !errors.Is(err, ErrClosed) {
			t.Fatal("invalid constructor accepted")
		}
	}
	s := &publicationStorage{Fake: nakamastoragetest.New()}
	r, _, _ := recoveryPairWithStorage(t, generationAPI(t, ""), false, s)
	complete, err := r.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	p, err := NewRecoveryPublisher(PublicationConfig{Enabled: true, Storage: s}, complete)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got, err := p.Publish(ctx); !errors.Is(err, ErrUnknown) || !errors.Is(err, context.Canceled) || got.state != nil || s.writes.Load() != 0 {
		t.Fatal("canceled publication exported or wrote")
	}
	if _, err = p.Publish(context.Background()); !errors.Is(err, ErrClosed) || s.writes.Load() != 0 {
		t.Fatal("canceled attempt resumed")
	}
	if _, err = (*RecoveryPublisher)(nil).Publish(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatal("nil publisher accepted")
	}
	if _, err = p.Accept(PublicationResult{}); !errors.Is(err, ErrClosed) {
		t.Fatal("zero result accepted")
	}
}

type publicationStorage struct {
	*nakamastoragetest.Fake
	fault    string
	cancel   context.CancelFunc
	writes   atomic.Int32
	deadline time.Time
}

// StorageWrite faults only the new proof boundary after actual fixture commit.
func (s *publicationStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	if len(writes) != 1 || writes[0].Collection != RecoveryProofCollection {
		return s.Fake.StorageWrite(ctx, writes)
	}
	s.writes.Add(1)
	s.deadline, _ = ctx.Deadline()
	w := writes[0]
	if w.Version != "*" || w.UserID != "" || w.PermissionRead != 0 || w.PermissionWrite != 0 {
		return nil, errors.New("proof write was not private create-only")
	}
	acks, err := s.Fake.StorageWrite(ctx, writes)
	if err != nil {
		return acks, err
	}
	switch s.fault {
	case "lost-ack":
		return nil, errors.New("private storage detail")
	case "nil-ack":
		return []*api.StorageObjectAck{nil}, nil
	case "empty-ack":
		return nil, nil
	case "multiple-ack":
		return append(acks, acks[0]), nil
	case "ack-key":
		acks[0].Key = "different"
	case "ack-collection":
		acks[0].Collection = "different"
	case "ack-owner":
		acks[0].UserId = "different"
	case "ack-version":
		acks[0].Version = "*"
	case "cancel-ack":
		s.cancel()
	}
	return acks, nil
}

// StorageRead retains all original storage paths; only proof replies are cut.
func (s *publicationStorage) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	rows, err := s.Fake.StorageRead(ctx, reads)
	if len(reads) != 1 || reads[0].Collection != RecoveryProofCollection || err != nil {
		return rows, err
	}
	deadline, _ := ctx.Deadline()
	if !deadline.Equal(s.deadline) {
		return nil, errors.New("publication renewed its deadline")
	}
	if len(rows) != 1 {
		return rows, nil
	}
	switch s.fault {
	case "lost-readback":
		return nil, errors.New("private storage detail")
	case "nil-readback":
		return []*api.StorageObject{nil}, nil
	case "missing-readback":
		return nil, nil
	case "multiple-readback":
		return append(rows, rows[0]), nil
	case "readback-version":
		rows[0].Version = "changed"
	case "readback-owner":
		rows[0].UserId = "changed"
	case "readback-key":
		rows[0].Key = "changed"
	case "readback-collection":
		rows[0].Collection = "changed"
	case "readback-public":
		rows[0].PermissionRead = 2
	case "readback-writable":
		rows[0].PermissionWrite = 1
	case "readback-content":
		rows[0].Value = "{}"
	case "readback-outcome":
		rows[0].Value = strings.Replace(rows[0].GetValue(), `"outcome":"uncommitted"`, `"outcome":"allocated-before-barrier"`, 1)
	case "cancel-readback":
		s.cancel()
	}
	return rows, nil
}

// Losing any ACK/readback component must consume the originating attempt; a
// later visible committed row cannot repair that missing evidence.
func TestRecoveryPublicationRefusesUncertainAcknowledgmentAndReadback(t *testing.T) {
	for _, fault := range []string{"lost-ack", "nil-ack", "empty-ack", "multiple-ack", "ack-key", "ack-collection", "ack-owner", "ack-version", "cancel-ack", "lost-readback", "nil-readback", "missing-readback", "multiple-readback", "readback-version", "readback-owner", "readback-key", "readback-collection", "readback-public", "readback-writable", "readback-content", "readback-outcome", "cancel-readback"} {
		t.Run(fault, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			s := &publicationStorage{Fake: nakamastoragetest.New(), fault: fault, cancel: cancel}
			r, _, _ := recoveryPairWithStorage(t, generationAPI(t, ""), false, s)
			complete, err := r.Fence(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			cfg := PublicationConfig{Enabled: true, Storage: s}
			p, err := NewRecoveryPublisher(cfg, complete)
			if err != nil {
				t.Fatal(err)
			}
			result, err := p.Publish(ctx)
			if !errors.Is(err, ErrUnknown) || result.state != nil || s.writes.Load() != 1 {
				t.Fatalf("uncertain publication escaped: %v", err)
			}
			if strings.HasPrefix(fault, "cancel-") && !errors.Is(err, context.Canceled) {
				t.Fatal("publication dropped the caller's cancellation")
			}
			if _, err = p.Accept(result); !errors.Is(err, ErrClosed) {
				t.Fatal("uncertain publication accepted")
			}
			s.fault = ""
			other, err := NewRecoveryPublisher(cfg, complete)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = other.Publish(context.Background()); !errors.Is(err, ErrClosed) || s.writes.Load() != 1 {
				t.Fatal("visible row restored publishing attempt")
			}
		})
	}
}

// A permanent diagnostic reader needs independently retained full pins and
// unchanged original private evidence. It returns no publication capability.
func TestRecoveryPublicationReaderRequiresExactIndependentPinsAndOriginalRows(t *testing.T) {
	for _, fault := range []string{"none", "proof-version", "owner-version", "handoff-version", "root-version", "generation", "member", "issued", "outcome", "owner-row-version", "owner-row-public", "owner-row-content", "handoff-row-version", "root-row-version", "proof-row-version"} {
		t.Run(fault, func(t *testing.T) {
			s := &publicationStorage{Fake: nakamastoragetest.New()}
			r, _, _ := recoveryPairWithStorage(t, generationAPI(t, ""), false, s)
			complete, err := r.Fence(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			p, err := NewRecoveryPublisher(PublicationConfig{Enabled: true, Storage: s}, complete)
			if err != nil {
				t.Fatal(err)
			}
			other, err := NewRecoveryPublisher(PublicationConfig{Enabled: true, Storage: s}, complete)
			if err != nil {
				t.Fatal(err)
			}
			result, err := p.Publish(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			pins, err := p.Accept(result)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = other.Accept(result); !errors.Is(err, ErrClosed) {
				t.Fatal("independent wrapper accepted originating publication")
			}
			if _, err = NewRecoveryPublisher(PublicationConfig{Enabled: true, Storage: s}, RecoveryResult{}); !errors.Is(err, ErrClosed) {
				t.Fatal("detached reader restored publisher")
			}
			switch fault {
			case "proof-version":
				pins.Version = "changed"
			case "owner-version":
				pins.Recovery.Owner.Version = "changed"
			case "handoff-version":
				pins.Recovery.Owner.HandoffVersion = "changed"
			case "root-version":
				pins.Recovery.Owner.Handoff.Journal.Binding.Version = "changed"
			case "generation":
				pins.Recovery.Owner.Handoff.Journal.Binding.GenerationID = "changed"
			case "member":
				pins.Recovery.Owner.Handoff.Journal.Binding.MemberPodUIDs[0] = "changed"
			case "issued":
				pins.Recovery.Owner.Handoff.Journal.Grants[0].SourceVersion = "changed"
			case "outcome":
				pins.Recovery.Grants[0].Outcome = Allocated
			default:
				collection, key := "", ""
				switch fault {
				case "owner-row-version", "owner-row-public", "owner-row-content":
					collection, key = allocatoradmission.RecoveryOwnerCollection, allocatoradmission.RecoveryOwnerKey(pins.Recovery.Owner.Handoff.Journal.Binding.GenerationID)
				case "handoff-row-version":
					collection, key = allocatoradmission.HandoffCollection, allocatoradmission.HandoffKey(pins.Recovery.Owner.Handoff.Journal.Binding.GenerationID)
				case "root-row-version":
					collection, key = allocatoradmission.Collection, allocatoradmission.Key(pins.Recovery.Owner.Handoff.Journal.Binding.GenerationID)
				case "proof-row-version":
					collection, key = RecoveryProofCollection, RecoveryProofKey(pins.Recovery.Owner.Handoff.Journal.Binding.GenerationID)
				}
				if collection != "" {
					row, ok := s.Get(collection, key, "")
					if !ok {
						t.Fatal("original row mutation did not find its target")
					}
					switch fault {
					case "owner-row-public":
						row.PermissionRead = 2
					case "owner-row-content":
						row.Value = "{}"
					default:
						row.Version = "changed"
					}
					s.Seed(row)
				}
			}
			got, err := ReadRecoveryPublication(context.Background(), PublicationReadConfig{Enabled: true, Storage: s.Fake, Pins: pins})
			if fault == "none" {
				if err != nil || !reflect.DeepEqual(got, pins.Recovery) {
					t.Fatal("pinned permanent readback lost complete evidence", err)
				}
			} else if !errors.Is(err, ErrUnknown) || !reflect.DeepEqual(got, RecoveryObservation{}) {
				t.Fatal("changed pins or original evidence became complete proof", fault, err)
			}
			if s.writes.Load() != 1 {
				t.Fatal("diagnostic reader wrote storage")
			}
		})
	}
}

// A visible create-only row excludes publication, including after process loss;
// its version cannot be used as a CAS replacement or a restart token.
func TestRecoveryPublicationRejectsPreexistingGenerationProof(t *testing.T) {
	s := &publicationStorage{Fake: nakamastoragetest.New()}
	r, _, _ := recoveryPairWithStorage(t, generationAPI(t, ""), false, s)
	complete, err := r.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	s.Seed(nakamastoragetest.Object{Collection: RecoveryProofCollection, Key: RecoveryProofKey("generation-1"), Value: `{"diagnostic":"visible"}`, Version: "preexisting"})
	p, err := NewRecoveryPublisher(PublicationConfig{Enabled: true, Storage: s}, complete)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := p.Publish(context.Background()); !errors.Is(err, ErrUnknown) || got.state != nil {
		t.Fatal("preexisting proof restored publication")
	}
	row, ok := s.Get(RecoveryProofCollection, RecoveryProofKey("generation-1"), "")
	if !ok || row.Version != "preexisting" || row.Value != `{"diagnostic":"visible"}` || s.writes.Load() != 1 {
		t.Fatal("publication replaced existing proof")
	}
	if _, err = p.Publish(context.Background()); !errors.Is(err, ErrClosed) || s.writes.Load() != 1 {
		t.Fatal("duplicate create was retried")
	}
}

// Independent wrappers and copies must race one result, not one bit per wrapper.
func TestRecoveryPublicationIndependentPublishersRaceOneCompleteResult(t *testing.T) {
	s := &publicationStorage{Fake: nakamastoragetest.New()}
	r, _, _ := recoveryPairWithStorage(t, generationAPI(t, ""), true, s)
	complete, err := r.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	cfg := PublicationConfig{Enabled: true, Storage: s}
	p, err := NewRecoveryPublisher(cfg, complete)
	if err != nil {
		t.Fatal(err)
	}
	other, err := NewRecoveryPublisher(cfg, complete)
	if err != nil {
		t.Fatal(err)
	}
	copy := *p
	var wg sync.WaitGroup
	var wins atomic.Int32
	for _, publisher := range []*RecoveryPublisher{p, &copy, other} {
		wg.Go(func() {
			result, e := publisher.Publish(context.Background())
			if e != nil {
				if !errors.Is(e, ErrClosed) {
					t.Error(e)
				}
				return
			}
			pins, e := publisher.Accept(result)
			if e != nil || pins.Version == "" || len(pins.Recovery.Grants) != 2 || pins.Recovery.Grants[1].Outcome != Allocated {
				t.Error("complete mixed pins lost", e)
				return
			}
			pins.Recovery.Grants[0].UID = "changed"
			again, e := publisher.Accept(result)
			if e != nil || again.Recovery.Grants[0].UID != "uid-zone-a" {
				t.Error("accepted pins alias live evidence")
			}
			wins.Add(1)
		})
	}
	wg.Wait()
	if wins.Load() != 1 || s.writes.Load() != 1 || s.deadline.IsZero() || time.Until(s.deadline) > 30*time.Second {
		t.Fatalf("publication owners=%d writes=%d", wins.Load(), s.writes.Load())
	}
}
