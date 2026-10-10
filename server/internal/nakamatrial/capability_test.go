//go:build war_native_trial

package nakamatrial

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	typed "agones.dev/agones/pkg/client/clientset/versioned/typed/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const capabilityBarrier = "world-at-ruin.dev/allocation-commit-barrier"

type controlMaterial struct {
	Host          string
	CA, Cert, Key []byte
}
type capabilityStage struct {
	entered, release    chan struct{}
	arrival, retirement sync.Once
}

func newStage() *capabilityStage {
	return &capabilityStage{entered: make(chan struct{}), release: make(chan struct{})}
}
func (s *capabilityStage) allow() { s.retirement.Do(func() { close(s.release) }) }
func stageReached(t *testing.T, s *capabilityStage) {
	t.Helper()
	select {
	case <-s.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("joined trial stage not reached")
	}
}

func ownedControlPlane(t *testing.T) *rest.Config {
	t.Helper()
	file := filepath.Join(t.TempDir(), "control.json")
	// Do not register unconditional t.TempDir cleanup: failed retirement must
	// leave potentially live child state for the disposable container to own.
	stateRoot, err := os.MkdirTemp("", "war-native-fixture-state-")
	if err != nil {
		t.Fatal("owned fixture state unavailable")
	}
	cmd := exec.Command("/out/gameserver-fixture", "-assets=/out/controlplane", "-crd=/out/controlplane/gameserver.yaml", "-output="+file)
	cmd.Env = append(os.Environ(), "TMPDIR="+stateRoot)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		_ = os.RemoveAll(stateRoot)
		t.Fatal("owned fixture pipe unavailable")
	}
	log := &lockedLog{}
	cmd.Stdout, cmd.Stderr = log, log
	if err = cmd.Start(); err != nil {
		_ = stdin.Close()
		_ = os.RemoveAll(stateRoot)
		t.Fatal("owned API fixture unavailable")
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	t.Cleanup(func() {
		_ = stdin.Close()
		select {
		case err := <-done:
			if err != nil {
				t.Error("owned API fixture did not retire cleanly")
				return
			}
			if files, err := os.ReadDir(stateRoot); err != nil || len(files) != 0 {
				t.Error("owned API fixture retained private state after retirement")
				return
			}
			if err := os.Remove(stateRoot); err != nil {
				t.Error("retired fixture state root not removed")
			}
		case <-time.After(50 * time.Second):
			_ = cmd.Process.Kill()
			<-done
			t.Error("owned API fixture retirement exceeded bound")
		}
	})
	var material controlMaterial
	waitFor(t, 55*time.Second, "private owned API manifest", func() bool {
		value, e := os.ReadFile(file)
		return e == nil && json.Unmarshal(value, &material) == nil && material.Host != "" && len(material.CA) > 0 && len(material.Cert) > 0 && len(material.Key) > 0
	})
	return &rest.Config{Host: material.Host, Timeout: 5 * time.Second, TLSClientConfig: rest.TLSClientConfig{CAData: material.CA, CertData: material.Cert, KeyData: material.Key}}
}

func actualReadyServer(t *testing.T, cfg *rest.Config) (typed.GameServerInterface, *agonesv1.GameServer) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	core, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = core.CoreV1().Namespaces().Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "trial"}}, metav1.CreateOptions{}); err != nil {
		t.Fatal(err)
	}
	api, err := typed.NewForConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	scoped := api.GameServers("trial")
	obj, err := scoped.Create(ctx, &agonesv1.GameServer{ObjectMeta: metav1.ObjectMeta{Name: "zone-a", Labels: map[string]string{agones.FleetLabel: "fleet"}}, Spec: agonesv1.GameServerSpec{Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "zone", Image: "registry.invalid/fixture:local"}}}}}, Status: agonesv1.GameServerStatus{State: agonesv1.GameServerStateReady}}, metav1.CreateOptions{})
	if err != nil || obj.UID == "" || obj.ResourceVersion == "" || obj.Status.State != agonesv1.GameServerStateReady {
		t.Fatal("actual API did not persist Ready identity")
	}
	return scoped, obj
}

// Forward the held original PUT to real storage using an independent context.
// Canceling its submitting client cannot erase a request already captured here.
type capabilityTraffic struct {
	allocations, gets atomic.Int32
	frozen            chan *agonesv1.GameServer
}

func heldActualAPI(t *testing.T, cfg *rest.Config) (controlMaterial, *capabilityStage, *capabilityTraffic, chan int) {
	t.Helper()
	target, err := url.Parse(cfg.Host)
	if err != nil {
		t.Fatal(err)
	}
	tlsConfig, err := rest.TLSConfigFor(cfg)
	if err != nil {
		t.Fatal(err)
	}
	transport := &http.Transport{TLSClientConfig: tlsConfig, DisableKeepAlives: true}
	t.Cleanup(transport.CloseIdleConnections)
	held := newStage()
	traffic := &capabilityTraffic{frozen: make(chan *agonesv1.GameServer, 4)}
	status := make(chan int, 1)
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			traffic.gets.Add(1)
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
		if err != nil {
			w.WriteHeader(500)
			return
		}
		var obj agonesv1.GameServer
		allocation := r.Method == http.MethodPut && json.Unmarshal(body, &obj) == nil && obj.Status.State == agonesv1.GameServerStateAllocated && obj.Annotations[capabilityBarrier] == ""
		if allocation {
			traffic.allocations.Add(1)
			traffic.frozen <- obj.DeepCopy()
			held.arrival.Do(func() { close(held.entered) })
			select {
			case <-held.release:
			case <-time.After(10 * time.Second):
				w.WriteHeader(504)
				return
			}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		forward := r.Clone(ctx)
		forward.URL.Scheme, forward.URL.Host, forward.Host = target.Scheme, target.Host, target.Host
		forward.RequestURI = ""
		forward.Body = io.NopCloser(bytes.NewReader(body))
		forward.ContentLength = int64(len(body))
		response, e := transport.RoundTrip(forward)
		if e != nil {
			w.WriteHeader(502)
			if allocation {
				status <- 502
			}
			return
		}
		defer response.Body.Close()
		for key, values := range response.Header {
			w.Header()[key] = append([]string(nil), values...)
		}
		w.WriteHeader(response.StatusCode)
		_, _ = io.Copy(w, response.Body)
		if allocation {
			status <- response.StatusCode
		}
	}))
	t.Cleanup(s.Close)
	t.Cleanup(held.allow)
	return controlMaterial{Host: s.URL}, held, traffic, status
}

func assertCapabilityRow(t *testing.T, f *fixture, original *agonesv1.GameServer, phase string) {
	t.Helper()
	var value, version, owner string
	var read, write, count int
	if f.db.QueryRow("SELECT value::text,version,user_id::text,read,write FROM storage WHERE collection='world_at_ruin_allocator_admissions' AND key=$1", admissionObjectID).Scan(&value, &version, &owner, &read, &write) != nil || version == "" || owner != zeroOwner || read != 0 || write != 0 {
		t.Fatal("private native admission row missing")
	}
	if f.db.QueryRow("SELECT count(*) FROM storage WHERE collection='world_at_ruin_allocator_admissions'").Scan(&count) != nil || count != 1 {
		t.Fatal("multiple generation roots")
	}
	var row struct {
		Phase   string
		Journal json.RawMessage
	}
	if json.Unmarshal([]byte(value), &row) != nil || row.Phase != phase {
		t.Fatal("native admission phase mismatch")
	}
	journal, err := allocatorjournal.DecodeJournal(string(row.Journal))
	if err != nil || journal.Binding.IncarnationID != "native-incarnation" || journal.Binding.GenerationID != "generation-1" || journal.Binding.GenerationVersion != "source-version-1" || journal.Binding.Namespace != "trial" || journal.Binding.Fleet != "fleet" || len(journal.Grants) != 1 || journal.Grants[0] != (allocatorjournal.JournalGrant{ActorUID: "pod-a", AttemptID: "attempt-original", Name: original.Name, UID: string(original.UID), SourceVersion: original.ResourceVersion}) {
		t.Fatal("native admission changed original frozen identity")
	}
}

func TestNativeDurableCapabilityComposition(t *testing.T) {
	verifyJournalArtifact(t)
	for _, scenario := range []string{"unfenced", "held-put", "late-ack", "lost-ack", "cancel-after-write", "crash-before-exposure"} {
		t.Run(scenario, func(t *testing.T) {
			cfg := ownedControlPlane(t)
			api, original := actualReadyServer(t, cfg)
			material, held, traffic, status := heldActualAPI(t, cfg)
			f := newFixture(t)
			stages := map[string]*capabilityStage{}
			for _, stage := range []string{"registered", "closing", "exposed", "drain", "fenced"} {
				stages[stage] = newStage()
			}
			control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				stage := stages[strings.TrimPrefix(r.URL.Path, "/")]
				if stage == nil {
					w.WriteHeader(404)
					return
				}
				stage.arrival.Do(func() { close(stage.entered) })
				select {
				case <-stage.release:
					w.WriteHeader(http.StatusNoContent)
				case <-time.After(10 * time.Second):
					w.WriteHeader(504)
				}
			}))
			t.Cleanup(control.Close)
			t.Cleanup(func() {
				for _, stage := range stages {
					stage.allow()
				}
			})
			value, err := json.Marshal(material)
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(f.dir, "durable-material.json")
			if os.WriteFile(path, value, 0600) != nil {
				t.Fatal("private probe material unavailable")
			}
			env := map[string]string{"WAR_DURABLE_GENERATION_PROBE_ENABLED": "true", "WAR_DURABLE_GENERATION_PROBE_SCENARIO": scenario, "WAR_DURABLE_GENERATION_PROBE_CONTROL": control.URL, "WAR_DURABLE_GENERATION_PROBE_MATERIAL": path}
			process := f.start(env, filepath.Join(*bundle, "modules"), 10)
			stageReached(t, stages["registered"])
			assertCapabilityRow(t, f, original, "open")
			if traffic.allocations.Load() != 0 || traffic.gets.Load() != 1 {
				t.Fatal("allocation escaped before registration acknowledgment")
			}
			select {
			case <-stages["exposed"].entered:
				t.Fatal("capability escaped before registration acknowledgment")
			default:
			}
			if scenario == "crash-before-exposure" {
				// The process dies with a committed registration but no exported
				// handle. Join it before starting another native incarnation.
				if err := process.cmd.Process.Kill(); err != nil {
					t.Fatal("owned crash injection failed")
				}
				select {
				case <-process.done:
				case <-time.After(5 * time.Second):
					t.Fatal("crashed native process not joined")
				}
				stages["registered"].allow()
				env["WAR_DURABLE_GENERATION_PROBE_SCENARIO"] = "restart"
				process = f.start(env, filepath.Join(*bundle, "modules"), 10)
				stageReached(t, stages["fenced"])
				assertCapabilityRow(t, f, original, "open")
				after, err := api.Get(context.Background(), original.Name, metav1.GetOptions{})
				if err != nil || after.ResourceVersion != original.ResourceVersion || after.Annotations[capabilityBarrier] != "" || traffic.allocations.Load() != 0 {
					t.Fatal("restart reconstructed capability or barrier authority")
				}
				stages["fenced"].allow()
				p := f.awaitStartup(process, true)
				if !strings.Contains(p.log.String(), "NAKAMA CAPABILITY PROBE PASS: scenario=restart") {
					t.Fatal("native restart refusal not exercised")
				}
				t.Log("DURABLE CAPABILITY JOIN PASS: scenario=crash-before-exposure committed_registration=1 restarted_authority=0 allocation_puts=0")
				return
			}
			if scenario == "late-ack" || scenario == "cancel-after-write" {
				stageReached(t, stages["closing"])
				stages["closing"].allow()
			}
			stages["registered"].allow()
			if scenario == "held-put" || scenario == "unfenced" {
				stageReached(t, stages["exposed"])
				if traffic.gets.Load() != 1 {
					t.Fatal("registered target refreshed before exposure")
				}
				stages["exposed"].allow()
				stageReached(t, held)
				captured := <-traffic.frozen
				attempt, err := agones.CorrelationLabel("attempt-original")
				if err != nil || captured.Name != original.Name || captured.Namespace != original.Namespace || captured.UID != original.UID || captured.ResourceVersion != original.ResourceVersion || captured.Labels[agones.AttemptLabel] != attempt || captured.Annotations[capabilityBarrier] != "" || !reflect.DeepEqual(captured.Spec, original.Spec) || traffic.gets.Load() != 1 {
					t.Fatal("captured PUT was not the original complete frozen mutation")
				}
				stageReached(t, stages["drain"])
				if scenario == "unfenced" {
					held.allow()
				}
				stages["drain"].allow()
			}
			stageReached(t, stages["fenced"])
			phase := "draining"
			if scenario == "lost-ack" || scenario == "cancel-after-write" || scenario == "unfenced" {
				phase = "open"
			}
			assertCapabilityRow(t, f, original, phase)
			barrier, err := api.Get(context.Background(), original.Name, metav1.GetOptions{})
			if err != nil {
				t.Fatal(err)
			}
			if scenario == "unfenced" {
				attempt, err := agones.CorrelationLabel("attempt-original")
				if err != nil || barrier.UID != original.UID || barrier.ResourceVersion == original.ResourceVersion || barrier.Status.State != agonesv1.GameServerStateAllocated || barrier.Labels[agones.AttemptLabel] != attempt || barrier.Annotations[capabilityBarrier] != "" || traffic.allocations.Load() != 1 {
					t.Fatal("unfenced positive control did not allocate original target")
				}
				select {
				case code := <-status:
					if code != 200 {
						t.Fatalf("actual positive PUT status %d", code)
					}
				case <-time.After(5 * time.Second):
					t.Fatal("positive write status missing")
				}
			} else if scenario == "lost-ack" || scenario == "cancel-after-write" {
				if barrier.ResourceVersion != original.ResourceVersion || barrier.Annotations[capabilityBarrier] != "" || traffic.allocations.Load() != 0 {
					t.Fatal("unknown registration acquired mutation authority")
				}
			} else if barrier.Status.State != agonesv1.GameServerStateReady || barrier.Annotations[capabilityBarrier] == "" || barrier.ResourceVersion == original.ResourceVersion {
				t.Fatal("real API barrier not persisted")
			}
			if scenario == "held-put" {
				held.allow()
				select {
				case code := <-status:
					if code != 409 {
						t.Fatalf("actual held PUT status %d", code)
					}
				case <-time.After(5 * time.Second):
					t.Fatal("held actual write did not settle")
				}
				after, err := api.Get(context.Background(), original.Name, metav1.GetOptions{})
				if err != nil || after.ResourceVersion != barrier.ResourceVersion || after.Status.State != agonesv1.GameServerStateReady {
					t.Fatal("held allocation changed accepted barrier")
				}
			} else if scenario != "unfenced" && traffic.allocations.Load() != 0 {
				t.Fatal("unexposed grant allocated")
			}
			stages["fenced"].allow()
			p := f.awaitStartup(process, true)
			if !strings.Contains(p.log.String(), "NAKAMA CAPABILITY PROBE PASS: scenario="+scenario) {
				t.Fatal("joined native scenario incomplete")
			}
			if scenario == "held-put" && traffic.allocations.Load() != 1 {
				t.Fatal("allocation was retried")
			}
			t.Logf("DURABLE CAPABILITY JOIN PASS: scenario=%s native_registration=1 real_barrier=%t allocation_puts=%d", scenario, scenario == "held-put" || scenario == "late-ack", traffic.allocations.Load())
		})
	}
}
