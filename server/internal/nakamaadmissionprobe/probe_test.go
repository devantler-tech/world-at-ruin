package nakamaadmissionprobe

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"testing"
)

func TestDisabledProbeReturnsBeforeDependencies(t *testing.T) {
	for _, flag := range []string{"", "false"} {
		ctx := probeContext{Context: context.Background(), env: map[string]string{"WAR_ALLOCATOR_ADMISSION_PROBE_ENABLED": flag, "WAR_ALLOCATOR_ADMISSION_PROBE_JOURNAL": "invalid"}}
		if e := Run(ctx, nil, nil); e != nil {
			t.Fatal(e)
		}
	}
}
func TestProbeRefusesInvalidEnablement(t *testing.T) {
	ctx := probeContext{Context: context.Background(), env: map[string]string{"WAR_ALLOCATOR_ADMISSION_PROBE_ENABLED": "TRUE"}}
	if e := Run(ctx, nil, nil); e == nil {
		t.Fatal("invalid flag accepted")
	}
}

// Reaching both writes is insufficient: one transition must persist, and its
// successful private readback must remain observable even after a lost reply.
func TestDrainRaceRequiresCommittedTransition(t *testing.T) {
	for _, tc := range []struct {
		name      string
		commit    bool
		readError bool
		wantError bool
	}{
		{name: "neither transition commits", wantError: true},
		{name: "committed transition loses reply", commit: true},
		{name: "readback returns row with error", commit: true, readError: true, wantError: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			initial, err := os.ReadFile("../allocatoradmission/testdata/empty.json")
			if err != nil {
				t.Fatal(err)
			}
			grant, err := json.Marshal(allocatorjournal.JournalGrant{ActorUID: "pod-a", AttemptID: "attempt-a", Name: "zone-a", UID: "uid-a", SourceVersion: "resource-a"})
			if err != nil {
				t.Fatal(err)
			}
			ctx := probeContext{Context: context.Background(), env: map[string]string{
				"WAR_ALLOCATOR_ADMISSION_PROBE_ENABLED":  "true",
				"WAR_ALLOCATOR_ADMISSION_PROBE_SCENARIO": "drain-race",
				"WAR_ALLOCATOR_ADMISSION_PROBE_JOURNAL":  string(initial),
				"WAR_ALLOCATOR_ADMISSION_PROBE_GRANT":    string(grant),
			}}
			storage := &raceReadbackStorage{commit: tc.commit, readError: tc.readError}
			reports := 0
			err = Run(ctx, storage, func(Report) { reports++ })
			wantReports := 0
			if !tc.wantError {
				wantReports = 1
			}
			if (err != nil) != tc.wantError || reports != wantReports {
				t.Fatalf("err=%v reports=%d; wantError=%t", err, reports, tc.wantError)
			}
			if storage.writes != 3 {
				t.Fatalf("both conditional writes must reach storage: %d calls", storage.writes)
			}
		})
	}
}

// The double can reject both dispatched transitions or persist exactly one but
// lose its acknowledgment. Neither case may be mistaken for source authority.
type raceReadbackStorage struct {
	mu        sync.Mutex
	row       *api.StorageObject
	writes    int
	commit    bool
	readError bool
}

func (s *raceReadbackStorage) StorageWrite(_ context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.writes++
	w := writes[0]
	if w.Version == "*" {
		s.row = &api.StorageObject{Collection: w.Collection, Key: w.Key, UserId: "00000000-0000-0000-0000-000000000000", Value: w.Value, Version: "v1"}
		return []*api.StorageObjectAck{{Collection: w.Collection, Key: w.Key, UserId: s.row.GetUserId(), Version: s.row.GetVersion()}}, nil
	}
	if s.commit && s.row.GetVersion() == w.Version {
		s.row.Value = w.Value
		s.row.Version = fmt.Sprintf("v%d", s.writes)
	}
	return nil, errors.New("conditional reply unavailable")
}

func (s *raceReadbackStorage) StorageRead(_ context.Context, _ []*runtime.StorageRead) ([]*api.StorageObject, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	row := &api.StorageObject{Collection: s.row.GetCollection(), Key: s.row.GetKey(), UserId: s.row.GetUserId(), Value: s.row.GetValue(), Version: s.row.GetVersion()}
	if s.readError {
		return []*api.StorageObject{row}, errors.New("partial readback")
	}
	return []*api.StorageObject{row}, nil
}

type probeContext struct {
	context.Context
	env map[string]string
}

func (c probeContext) Value(key any) any {
	if key == runtime.RUNTIME_CTX_ENV {
		return c.env
	}
	return c.Context.Value(key)
}
