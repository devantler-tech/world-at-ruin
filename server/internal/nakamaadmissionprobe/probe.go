// Package nakamaadmissionprobe is an opt-in disposable startup experiment.
// Only the explicitly experimental native bundle composes it; normal plugins do not.
package nakamaadmissionprobe

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Storage interface {
	allocatoradmission.Storage
	allocatorjournal.JournalStorage
}
type Report struct {
	Scenario   string
	Phase      string
	GrantCount int
}

// Run exercises one disposable storage scenario only after explicit enablement.
// A report records diagnostic behavior and never exports allocation authority.
func Run(ctx context.Context, storage Storage, report func(Report)) error {
	env, _ := ctx.Value(runtime.RUNTIME_CTX_ENV).(map[string]string)
	flag := env["WAR_ALLOCATOR_ADMISSION_PROBE_ENABLED"]
	if flag == "" || flag == "false" {
		return nil
	}
	if flag != "true" || report == nil {
		return errors.New("admission probe: invalid enablement")
	}
	scenario := env["WAR_ALLOCATOR_ADMISSION_PROBE_SCENARIO"]
	if scenario != "sequence" && scenario != "incarnation-race" && scenario != "drain-race" && scenario != "lost-ack" {
		return errors.New("admission probe: invalid scenario")
	}
	initial := env["WAR_ALLOCATOR_ADMISSION_PROBE_JOURNAL"]
	var grant allocatorjournal.JournalGrant
	decoder := json.NewDecoder(strings.NewReader(env["WAR_ALLOCATOR_ADMISSION_PROBE_GRANT"]))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&grant) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return errors.New("admission probe: invalid grant")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if _, err := allocatoradmission.NewWriter(allocatoradmission.Config{Enabled: true, Storage: storage, Journal: initial}); err != nil {
		return errors.New("admission probe: invalid journal or dependencies")
	}
	var boundary allocatoradmission.Storage = storage
	var held *raceStorage
	var lost *lostStorage
	if scenario == "drain-race" {
		held = &raceStorage{Storage: storage, ready: make(chan struct{})}
		boundary = held
	}
	if scenario == "lost-ack" {
		lost = &lostStorage{Storage: storage}
		boundary = lost
	}
	w, err := allocatoradmission.NewWriter(allocatoradmission.Config{Enabled: true, Storage: boundary, Journal: initial})
	if err != nil {
		return errors.New("admission probe: invalid journal or dependencies")
	}
	if scenario == "incarnation-race" {
		var document map[string]json.RawMessage
		if json.Unmarshal([]byte(initial), &document) != nil {
			return errors.New("admission probe: invalid journal")
		}
		document["authority_incarnation"] = json.RawMessage("\"contending-incarnation\"")
		encoded, e := json.Marshal(document)
		if e != nil {
			return e
		}
		contender, e := allocatoradmission.NewWriter(allocatoradmission.Config{Enabled: true, Storage: storage, Journal: string(encoded)})
		if e != nil {
			return e
		}
		results := make(chan error, 2)
		for _, candidate := range []*allocatoradmission.Writer{w, contender} {
			go func() { _, e := candidate.Create(ctx); results <- e }()
		}
		successes := 0
		for range 2 {
			if <-results == nil {
				successes++
			}
		}
		if successes != 1 {
			return errors.New("admission probe: generation election not exclusive")
		}
		report(Report{Scenario: scenario, Phase: "open", GrantCount: 0})
		return nil
	}
	head, err := w.Create(ctx)
	if scenario == "lost-ack" {
		if err == nil || head != nil || !errors.Is(err, allocatoradmission.ErrUnknown) {
			return errors.New("admission probe: lost reply returned a snapshot")
		}
		if next, e := w.Create(ctx); e == nil || next != nil || lost.calls.Load() != 1 {
			return errors.New("admission probe: ambiguous create retried")
		}
		report(Report{Scenario: scenario, Phase: "unknown", GrantCount: -1})
		return nil
	}
	if err != nil {
		return errors.New("admission probe: create unknown")
	}
	if scenario == "drain-race" {
		results := make(chan error, 2)
		go func() { _, e := w.Register(ctx, head, grant); results <- e }()
		go func() { _, e := w.Drain(ctx, head); results <- e }()
		failures := 0
		for range 2 {
			if <-results != nil {
				failures++
			}
		}
		if failures < 1 || held.arrived.Load() != 2 || ctx.Err() != nil {
			return errors.New("admission probe: competing transitions not rejected")
		}
		// Both results may be unknown when the losing CAS poisons the writer
		// before the winner's reply. Independently prove that storage advanced:
		// transport arrival and an errored read cannot establish a committed CAS.
		binding := head.Observation().Journal.Binding
		key := allocatoradmission.Key(binding.GenerationID)
		rows, readErr := storage.StorageRead(ctx, []*runtime.StorageRead{{Collection: allocatoradmission.Collection, Key: key, UserID: ""}})
		if readErr != nil || ctx.Err() != nil || len(rows) != 1 || rows[0] == nil {
			return errors.New("admission probe: committed race readback unknown")
		}
		row := rows[0]
		if row.GetCollection() != allocatoradmission.Collection || row.GetKey() != key || row.GetUserId() != nakamastorage.SystemOwnerID || row.GetPermissionRead() != 0 || row.GetPermissionWrite() != 0 || row.GetVersion() == binding.Version || row.GetVersion() == "*" || !handoffidentity.OpaqueUTF8(row.GetVersion(), 1024) {
			return errors.New("admission probe: neither competing transition persisted")
		}
		report(Report{Scenario: scenario, Phase: "unknown", GrantCount: -1})
		return nil
	}
	registered, err := w.Register(ctx, head, grant)
	if err != nil {
		return errors.New("admission probe: registration unknown")
	}
	drained, err := w.Drain(ctx, registered)
	if err != nil {
		return errors.New("admission probe: drain unknown")
	}
	got := drained.Observation()
	if got.Phase != "draining" || len(got.Journal.Grants) != 1 || got.Journal.Grants[0] != grant {
		return errors.New("admission probe: incomplete drain")
	}
	if _, err = allocatoradmission.Read(ctx, storage, got.Journal.Binding, "draining"); err != nil {
		return errors.New("admission probe: exact readback unknown")
	}
	// Replaying an old root snapshot must reach and lose the real runtime CAS.
	if stale, e := w.Register(ctx, head, grant); e == nil || stale != nil {
		return errors.New("admission probe: stale root overwrote drain")
	}
	if _, err = allocatoradmission.Read(ctx, storage, got.Journal.Binding, "draining"); err != nil {
		return errors.New("admission probe: stale write changed root")
	}
	report(Report{Scenario: scenario, Phase: "draining", GrantCount: 1})
	return nil
}

// The fault is injected AFTER the actual native transaction commits. It cannot
// turn the unknown result into a grant or clear quarantine.
type lostStorage struct {
	Storage
	calls atomic.Int32
}

func (s *lostStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	s.calls.Add(1)
	acks, err := s.Storage.StorageWrite(ctx, writes)
	if err != nil || len(acks) != 1 {
		return acks, err
	}
	return nil, errors.New("disposable trial: reply lost after commit")
}

// Both requests reach the transport before either can win the real database CAS.
type raceStorage struct {
	Storage
	ready   chan struct{}
	arrived atomic.Int32
	once    sync.Once
}

func (s *raceStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	if len(writes) == 1 && writes[0].Version != "*" {
		if s.arrived.Add(1) == 2 {
			s.once.Do(func() { close(s.ready) })
		}
		select {
		case <-s.ready:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return s.Storage.StorageWrite(ctx, writes)
}
