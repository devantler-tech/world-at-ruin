package nakamaruntime

import (
	"bytes"
	"context"
	"crypto/rsa"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	agonesclient "agones.dev/agones/pkg/client/clientset/versioned"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/cryptotest"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/runtime"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/rest"
)

const orphanHTTPPath = "/apis/agones.dev/v1/namespaces/world-at-ruin/gameservers"

// orphanHTTP models API-server selection, pagination and conditional deletion.
// The production generated client serializes every request; fake clientsets do
// not enforce delete preconditions or supply a collection resource version.
type orphanHTTP struct {
	t            *testing.T
	mu           sync.Mutex
	servers      map[string]*agonesv1.GameServer
	fault        string
	deletes      []string
	lists        []time.Time
	getChanged   bool
	deleteFailed bool
}

func newOrphanHTTP(t *testing.T, servers ...*agonesv1.GameServer) *orphanHTTP {
	t.Helper()
	f := &orphanHTTP{t: t, servers: make(map[string]*agonesv1.GameServer)}
	for _, server := range servers {
		f.servers[server.Name] = server.DeepCopy()
	}
	return f
}

func orphanServer(t *testing.T, name, attempt string) *agonesv1.GameServer {
	t.Helper()
	digest, err := agones.CorrelationLabel(attempt)
	if err != nil {
		t.Fatal(err)
	}
	return &agonesv1.GameServer{
		TypeMeta:   metav1.TypeMeta{APIVersion: "agones.dev/v1", Kind: "GameServer"},
		ObjectMeta: metav1.ObjectMeta{Namespace: "world-at-ruin", Name: name, UID: types.UID(name + "-uid"), ResourceVersion: "42", Labels: map[string]string{agones.FleetLabel: "cave", agones.AttemptLabel: digest}},
		Status:     agonesv1.GameServerStatus{State: agonesv1.GameServerStateAllocated},
	}
}

func (f *orphanHTTP) setFault(fault string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fault = fault
}

func (f *orphanHTTP) snapshot() ([]string, []time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.deletes...), append([]time.Time(nil), f.lists...)
}

func (f *orphanHTTP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	write := func(value any) {
		if err := json.NewEncoder(w).Encode(value); err != nil {
			f.t.Errorf("encode API response: %v", err)
		}
	}
	fail := func(code int32, reason metav1.StatusReason) {
		w.WriteHeader(int(code))
		write(metav1.Status{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Status"}, Status: metav1.StatusFailure, Reason: reason, Code: code, Message: "provider-private-details"})
	}
	if r.URL.Path == orphanHTTPPath && r.Method == http.MethodGet {
		f.lists = append(f.lists, time.Now())
		selector, err := labels.Parse(r.URL.Query().Get("labelSelector"))
		if err != nil || r.URL.Query().Get("limit") != "100" || selector.String() != "agones.dev/fleet=cave,world-at-ruin.dev/handoff-attempt" {
			f.t.Error("resource scan changed its namespaced Fleet/attempt selector or page size")
			fail(http.StatusBadRequest, metav1.StatusReasonBadRequest)
			return
		}
		if f.fault == "transient" {
			f.fault = ""
			fail(http.StatusInternalServerError, metav1.StatusReasonInternalError)
			return
		}
		if f.fault == "timeout" {
			<-r.Context().Done()
			return
		}
		list := agonesv1.GameServerList{TypeMeta: metav1.TypeMeta{APIVersion: "agones.dev/v1", Kind: "GameServerList"}, ListMeta: metav1.ListMeta{ResourceVersion: "42"}, Items: []agonesv1.GameServer{}}
		names := make([]string, 0, len(f.servers))
		for name := range f.servers {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			if selector.Matches(labels.Set(f.servers[name].Labels)) {
				list.Items = append(list.Items, *f.servers[name].DeepCopy())
			}
		}
		if f.fault == "partial" || f.fault == "revision" || f.fault == "cycle" {
			list.Continue = "second-page"
			if r.URL.Query().Get("continue") != "" {
				switch f.fault {
				case "partial":
					fail(http.StatusInternalServerError, metav1.StatusReasonInternalError)
					return
				case "revision":
					list.ResourceVersion, list.Continue, list.Items = "43", "", nil
				case "cycle":
					list.Items = nil
				}
			}
		}
		write(list)
		return
	}
	if !strings.HasPrefix(r.URL.Path, orphanHTTPPath+"/") {
		f.t.Error("runtime contacted an unrelated API path")
		fail(http.StatusNotFound, metav1.StatusReasonNotFound)
		return
	}
	name := strings.TrimPrefix(r.URL.Path, orphanHTTPPath+"/")
	server := f.servers[name]
	if server == nil {
		fail(http.StatusNotFound, metav1.StatusReasonNotFound)
		return
	}
	switch r.Method {
	case http.MethodGet:
		if name == "changed-zone" && !f.getChanged {
			f.getChanged = true
			server.UID, server.ResourceVersion = "replacement-uid", "43"
		}
		write(server)
	case http.MethodDelete:
		var options metav1.DeleteOptions
		if err := json.NewDecoder(r.Body).Decode(&options); err != nil || options.Preconditions == nil || options.Preconditions.UID == nil || options.Preconditions.ResourceVersion == nil || *options.Preconditions.UID != server.UID || *options.Preconditions.ResourceVersion != server.ResourceVersion {
			f.t.Error("delete omitted or changed exact UID/resource-version preconditions")
			fail(http.StatusConflict, metav1.StatusReasonConflict)
			return
		}
		f.deletes = append(f.deletes, name)
		if name == "retry-zone" && !f.deleteFailed {
			// A rejected mutation leaves the exact original UID alive. It must
			// be observed once, then retried through another complete sweep.
			f.deleteFailed = true
			fail(http.StatusForbidden, metav1.StatusReasonForbidden)
			return
		}
		delete(f.servers, name)
		if name == "lost-response-zone" {
			// The delete committed, but its acknowledgement was lost.
			fail(http.StatusServiceUnavailable, metav1.StatusReasonServiceUnavailable)
			return
		}
		write(metav1.Status{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Status"}, Status: metav1.StatusSuccess})
	default:
		f.t.Error("runtime issued an unexpected API mutation")
		fail(http.StatusMethodNotAllowed, metav1.StatusReasonMethodNotAllowed)
	}
}

type orphanHTTPLog struct {
	runtime.Logger
	messages chan string
}

func (l orphanHTTPLog) Info(format string, args ...interface{}) { l.record(format, args...) }
func (l orphanHTTPLog) Warn(format string, args ...interface{}) { l.record(format, args...) }
func (l orphanHTTPLog) record(format string, args ...interface{}) {
	select {
	case l.messages <- fmt.Sprintf(format, args...):
	default:
	}
}

func waitOrphanLog(t *testing.T, log orphanHTTPLog, contains string, timeout time.Duration) string {
	t.Helper()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case line := <-log.messages:
			if strings.Contains(line, "provider-private-details") {
				t.Fatal("provider error escaped into runtime observations")
			}
			if strings.Contains(line, contains) {
				return line
			}
		case <-timer.C:
			t.Fatalf("runtime never reported %q", contains)
		}
	}
}

func orphanHTTPDependencies(t *testing.T, f *orphanHTTP) dependencies {
	t.Helper()
	server := httptest.NewServer(f)
	t.Cleanup(server.Close)
	// Historical-shape cases share this client. Sweep deadlines are exercised
	// separately; fixture request throttling must not consume their budget.
	client, err := agonesclient.NewForConfig(&rest.Config{Host: server.URL, QPS: 1000, Burst: 1000})
	if err != nil {
		t.Fatal(err)
	}
	key, _, _ := cryptotest.Seal(t, "world-at-ruin", "zone-one", "uid-one", bytes.Repeat([]byte{1}, 32))
	return dependencies{allocator: allocatorFunction{}, resources: client.AgonesV1().GameServers("world-at-ruin"), keys: []*rsa.PrivateKey{key}}
}

func startOrphanHTTPRuntime(t *testing.T, env map[string]string, storage *moduleStorage, deps dependencies) (*registration, orphanHTTPLog) {
	t.Helper()
	r, log := &registration{}, orphanHTTPLog{messages: make(chan string, 100)}
	if err := initialize(environmentContext(env), storage, r, func(config) (dependencies, error) { return deps, nil }, log); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.shutdown(context.Background(), nil, nil, storage) })
	return r, log
}

func orphanHTTPEnvironment() map[string]string {
	env := validEnvironment()
	env["WAR_HANDOFF_ORPHANS_ENABLED"] = "true"
	env["WAR_HANDOFF_ORPHANS_GRACE"] = "30s"
	env["WAR_HANDOFF_ORPHANS_INTERVAL"] = "1s"
	env["WAR_HANDOFF_ORPHANS_TIMEOUT"] = "100ms"
	env["WAR_HANDOFF_ORPHANS_MAX_PAGES"] = "2"
	return env
}

func historicalOrphanLeases(t *testing.T, version int) []json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(fmt.Sprintf("../nakamalease/testdata/golden_lease_v%d.json", version))
	if err != nil {
		t.Fatal(err)
	}
	var records []json.RawMessage
	if err := json.Unmarshal(data, &records); err != nil {
		t.Fatal(err)
	}
	return records
}

// Real module supervision, real elapsed grace, production lease protection and
// real generated HTTP deletes must all agree before a crash leftover is gone.
func TestOrphanRuntimeGeneratedHTTPProtectionAndCleanup(t *testing.T) {
	t.Parallel()
	storage := &moduleStorage{Fake: nakamastoragetest.New()}
	for i, value := range historicalOrphanLeases(t, 4) {
		storage.Seed(nakamastoragetest.Object{Collection: nakamalease.Collection, Key: fmt.Sprintf("%064x", i+1), Value: string(value), Version: "retained-v4"})
	}
	before := storageValues(storage.Fake)
	sort.Strings(before)
	ready := orphanServer(t, "ready-zone", "unowned-ready")
	ready.Status.State = agonesv1.GameServerStateReady
	unlabelled := orphanServer(t, "pool-zone", "pool")
	delete(unlabelled.Labels, agones.AttemptLabel)
	foreign := orphanServer(t, "foreign-zone", "foreign")
	foreign.Labels[agones.FleetLabel] = "other-fleet"
	f := newOrphanHTTP(t, orphanServer(t, "protected-zone", "attempt-7"), orphanServer(t, "orphan-zone", "orphan"), orphanServer(t, "lost-response-zone", "lost-response"), orphanServer(t, "changed-zone", "changed"), orphanServer(t, "retry-zone", "retry"), ready, unlabelled, foreign)
	f.setFault("transient")
	_, log := startOrphanHTTPRuntime(t, orphanHTTPEnvironment(), storage, orphanHTTPDependencies(t, f))
	waitOrphanLog(t, log, "outcome=incomplete", 2*time.Second)
	line := waitOrphanLog(t, log, "protected=1", 2*time.Second)
	if !strings.Contains(line, "scanned=5 waiting=4") {
		t.Fatalf("startup scan lost exact scope or durable protection: %s", line)
	}
	firstComplete := time.Now()
	line = waitOrphanLog(t, log, "deleted=2 changed=1", 35*time.Second)
	if time.Since(firstComplete) < 29*time.Second || !strings.Contains(line, "outcome=cleanup-pending") || !strings.Contains(line, "failed=1") {
		t.Fatal("runtime bypassed the configured grace or lost an ambiguous-delete acknowledgement")
	}
	waitOrphanLog(t, log, "deleted=1 changed=0 failed=0", 2*time.Second)
	deletes, scans := f.snapshot()
	sort.Strings(deletes)
	if !reflect.DeepEqual(deletes, []string{"lost-response-zone", "orphan-zone", "retry-zone", "retry-zone"}) {
		t.Fatalf("cleanup touched a protected, replaced, Ready or foreign resource: %v", deletes)
	}
	for i := 1; i < len(scans); i++ {
		if scans[i].Sub(scans[i-1]) < 500*time.Millisecond {
			t.Fatal("runtime retried a sweep outside its configured periodic cadence")
		}
	}
	after := storageValues(storage.Fake)
	sort.Strings(after)
	if !reflect.DeepEqual(before, after) || len(storage.WrittenValues()) != 0 {
		t.Fatal("orphan supervision rewrote or retired a protected historical lease")
	}
}

// Replacing the module cannot inherit the previous process-local grace clock.
func TestOrphanRuntimeRestartRequiresFreshGrace(t *testing.T) {
	t.Parallel()
	f := newOrphanHTTP(t, orphanServer(t, "orphan-zone", "orphan"))
	storage := &moduleStorage{Fake: nakamastoragetest.New()}
	deps := orphanHTTPDependencies(t, f)
	r, log := startOrphanHTTPRuntime(t, orphanHTTPEnvironment(), storage, deps)
	waitOrphanLog(t, log, "waiting=1", 2*time.Second)
	time.Sleep(15 * time.Second)
	r.shutdown(context.Background(), nil, nil, storage)
	_, log = startOrphanHTTPRuntime(t, orphanHTTPEnvironment(), storage, deps)
	waitOrphanLog(t, log, "waiting=1", 2*time.Second)
	time.Sleep(17 * time.Second)
	if deletes, _ := f.snapshot(); len(deletes) != 0 {
		t.Fatal("replacement module reused the previous worker's observation grace")
	}
	waitOrphanLog(t, log, "waiting=1", time.Second)
}

// A failed observation breaks consecutive absence, even after earlier success.
func TestOrphanRuntimeIncompleteScanRestartsGrace(t *testing.T) {
	t.Parallel()
	f := newOrphanHTTP(t, orphanServer(t, "orphan-zone", "orphan"))
	storage := &moduleStorage{Fake: nakamastoragetest.New()}
	_, log := startOrphanHTTPRuntime(t, orphanHTTPEnvironment(), storage, orphanHTTPDependencies(t, f))
	waitOrphanLog(t, log, "waiting=1", 2*time.Second)
	time.Sleep(10 * time.Second)
	f.setFault("partial")
	waitOrphanLog(t, log, "outcome=incomplete", 2*time.Second)
	f.setFault("")
	waitOrphanLog(t, log, "waiting=1", 2*time.Second)
	time.Sleep(21 * time.Second)
	if deletes, _ := f.snapshot(); len(deletes) != 0 {
		t.Fatal("incomplete scan counted toward consecutive orphan grace")
	}
	waitOrphanLog(t, log, "deleted=1", 12*time.Second)
}

// All shipped lease shapes protect attempts in the actual composed store,
// including releasing and expired states which the expiry worker alone owns.
func TestComposedOrphansProtectEveryHistoricalLeaseShape(t *testing.T) {
	f := newOrphanHTTP(t, orphanServer(t, "protected-zone", "attempt-7"))
	deps := orphanHTTPDependencies(t, f)
	for version := 1; version <= 4; version++ {
		for i, value := range historicalOrphanLeases(t, version) {
			for _, expired := range []bool{false, true} {
				value := string(value)
				if expired {
					value = strings.ReplaceAll(value, "2000000000123456789", "2000000000")
					value = strings.ReplaceAll(value, "1999999999123456789", "1000000000")
				}
				t.Run(fmt.Sprintf("v%d/shape%d/expired=%t", version, i, expired), func(t *testing.T) {
					storage := &moduleStorage{Fake: nakamastoragetest.New()}
					storage.Seed(nakamastoragetest.Object{Collection: nakamalease.Collection, Key: fmt.Sprintf("%064x", i+1), Value: value, Version: "historical"})
					cfg, err := readConfig(orphanHTTPEnvironment())
					if err != nil {
						t.Fatal(err)
					}
					_, _, _, reaper, err := compose(cfg, storage, deps)
					if err != nil || reaper == nil {
						t.Fatalf("runtime did not compose orphan protection: %v", err)
					}
					report, err := reaper.Sweep(context.Background())
					if err != nil || report.Protected != 1 || report.Waiting != 0 || report.Deleted != 0 || storageValues(storage.Fake)[0] != value || len(storage.WrittenValues()) != 0 {
						t.Fatalf("historical lease lost protection or byte identity: report=%+v err=%v", report, err)
					}
				})
			}
		}
	}
}

func TestOrphanRuntimeRefusesIncompleteHTTPOrPrivateEvidence(t *testing.T) {
	for _, fault := range []string{"partial", "revision", "cycle", "page budget", "timeout", "malformed lease", "lease page budget"} {
		t.Run(fault, func(t *testing.T) {
			f := newOrphanHTTP(t, orphanServer(t, "orphan-zone", "orphan"))
			storage := &moduleStorage{Fake: nakamastoragetest.New()}
			env := orphanHTTPEnvironment()
			outcome := "outcome=incomplete"
			switch fault {
			case "page budget":
				f.setFault("partial")
				env["WAR_HANDOFF_ORPHANS_MAX_PAGES"] = "1"
			case "timeout":
				f.setFault(fault)
				outcome = "outcome=deadline"
			case "malformed lease":
				storage.Seed(nakamastoragetest.Object{Collection: nakamalease.Collection, Key: strings.Repeat("a", 64), Value: `{"schema":999,"private":"storage-secret"}`, Version: "bad"})
			case "lease page budget":
				env["WAR_HANDOFF_ORPHANS_MAX_PAGES"] = "1"
				value := historicalOrphanLeases(t, 4)[0]
				for i := range 101 {
					storage.Seed(nakamastoragetest.Object{Collection: nakamalease.Collection, Key: fmt.Sprintf("%064x", i+1), Value: string(value), Version: "retained"})
				}
			default:
				f.setFault(fault)
			}
			_, log := startOrphanHTTPRuntime(t, env, storage, orphanHTTPDependencies(t, f))
			line := waitOrphanLog(t, log, outcome, 2*time.Second)
			if !strings.Contains(line, "scanned=0 waiting=0 protected=0 deleted=0") || strings.Contains(line, "storage-secret") {
				t.Fatalf("incomplete evidence authorized cleanup or leaked content: %s", line)
			}
			if deletes, scans := f.snapshot(); len(deletes) != 0 || (fault == "page budget" && len(scans) != 1) {
				t.Fatal("incomplete or over-budget runtime issued additional cleanup requests")
			}
		})
	}
}
