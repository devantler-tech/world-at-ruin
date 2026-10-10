//go:build war_native_trial

package nakamatrial

import (
	"bytes"
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	typed "agones.dev/agones/pkg/client/clientset/versioned/typed/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/internal/gameservercommit"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/rest"
)

type pairAPI struct {
	material              controlMaterial
	held                  map[string]*capabilityStage
	status                map[string]chan int
	frozen                chan *agonesv1.GameServer
	barrierWritten        *capabilityStage
	allocations, barriers atomic.Int32
	recovering            atomic.Bool
}

// Two independent old PUTs retain their original bytes/context after source
// death. Each is forwarded exactly once to actual owned kube-apiserver/etcd.
func heldPairAPI(t *testing.T, cfg *rest.Config, scenario, first string) *pairAPI {
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
	p := &pairAPI{held: map[string]*capabilityStage{"zone-a": newStage(), "zone-b": newStage()}, status: map[string]chan int{"zone-a": make(chan int, 1), "zone-b": make(chan int, 1)}, frozen: make(chan *agonesv1.GameServer, 2), barrierWritten: newStage()}
	if scenario != "crash-after-submission" {
		p.barrierWritten.allow()
	}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := path.Base(r.URL.Path)
		if scenario == "partial" && p.recovering.Load() && r.Method == http.MethodGet && name != first {
			w.WriteHeader(503)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
		if err != nil {
			w.WriteHeader(400)
			return
		}
		var obj agonesv1.GameServer
		allocation, barrier := false, false
		if r.Method == http.MethodPut && json.Unmarshal(body, &obj) == nil {
			barrier = obj.Annotations[capabilityBarrier] != ""
			allocation = !barrier && obj.Status.State == agonesv1.GameServerStateAllocated
		}
		if allocation {
			p.allocations.Add(1)
			stage := p.held[name]
			if stage == nil {
				w.WriteHeader(400)
				return
			}
			p.frozen <- obj.DeepCopy()
			stage.arrival.Do(func() { close(stage.entered) })
			select {
			case <-stage.release:
			case <-time.After(10 * time.Second):
				w.WriteHeader(504)
				return
			}
		}
		if barrier {
			p.barriers.Add(1)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		forward := r.Clone(ctx)
		forward.URL.Scheme, forward.URL.Host, forward.Host = target.Scheme, target.Host, target.Host
		forward.RequestURI = ""
		forward.Body = io.NopCloser(bytes.NewReader(body))
		forward.ContentLength = int64(len(body))
		response, err := transport.RoundTrip(forward)
		if err != nil {
			w.WriteHeader(502)
			if allocation {
				p.status[name] <- 502
			}
			return
		}
		defer func() { _ = response.Body.Close() }()
		if barrier && name == first && response.StatusCode == 200 {
			p.barrierWritten.arrival.Do(func() { close(p.barrierWritten.entered) })
			select {
			case <-p.barrierWritten.release:
			case <-time.After(10 * time.Second):
				w.WriteHeader(504)
				return
			}
		}
		for key, values := range response.Header {
			w.Header()[key] = append([]string(nil), values...)
		}
		w.WriteHeader(response.StatusCode)
		_, _ = io.Copy(w, response.Body)
		if allocation {
			p.status[name] <- response.StatusCode
		}
	}))
	t.Cleanup(s.Close)
	t.Cleanup(func() {
		for _, stage := range p.held {
			stage.allow()
		}
		p.barrierWritten.allow()
	})
	p.material = controlMaterial{Host: s.URL}
	return p
}

// pairExpected binds original source ACK pins to both real targets in canonical
// UID order, independently of which target the fixture created first.
func pairExpected(t *testing.T, originals []*agonesv1.GameServer, pins retainedHandoffPins) allocatoradmission.Observation {
	t.Helper()
	grants := []allocatorjournal.JournalGrant{{ActorUID: "pod-a", AttemptID: "attempt-original-a", Name: "zone-a", UID: string(originals[0].UID), SourceVersion: originals[0].ResourceVersion}, {ActorUID: "pod-b", AttemptID: "attempt-original-b", Name: "zone-b", UID: string(originals[1].UID), SourceVersion: originals[1].ResourceVersion}}
	slices.SortFunc(grants, func(a, b allocatorjournal.JournalGrant) int { return cmp.Compare(a.UID, b.UID) })
	raw, err := json.Marshal(grants)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-issued-grants/v1\n"), raw...))
	b := pins.Binding
	if b.GenerationID != "generation-1" || b.GenerationVersion != "source-version-1" || b.IncarnationID != "native-incarnation" || b.Namespace != "trial" || b.Fleet != "fleet" || b.MemberSetDigest != "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d" || !reflect.DeepEqual(b.MemberPodUIDs, []string{"pod-a", "pod-b"}) || b.IssuedCount != 2 || b.IssuedDigest != hex.EncodeToString(digest[:]) || b.Version == "" || pins.Version == "" {
		t.Fatal("pair pins lost original complete binding")
	}
	return allocatoradmission.Observation{Phase: "draining", Journal: allocatorjournal.JournalObservation{Binding: b, Grants: grants}}
}

// assertPairHandoff checks persisted private rows as evidence while the retained
// source ACK pins remain the recoverer's sole handoff input.
func assertPairHandoff(t *testing.T, f *fixture, originals []*agonesv1.GameServer, pins retainedHandoffPins) {
	t.Helper()
	want := pairExpected(t, originals, pins)
	var value, version, user string
	var read, write, count int
	if f.db.QueryRowContext(t.Context(), "SELECT value::text,version,user_id::text,read,write FROM storage WHERE collection=$1 AND key=$2", allocatoradmission.HandoffCollection, allocatoradmission.HandoffKey("generation-1")).Scan(&value, &version, &user, &read, &write) != nil || version != pins.Version || user != zeroOwner || read != 0 || write != 0 {
		t.Fatal("pair handoff lacks private exact ACK row")
	}
	var doc struct {
		Schema           int
		AdmissionVersion string `json:"admission_version"`
		Admission        struct {
			Phase   string
			Journal json.RawMessage
		}
	}
	if json.Unmarshal([]byte(value), &doc) != nil || doc.Schema != 1 || doc.AdmissionVersion != pins.Binding.Version || doc.Admission.Phase != "draining" {
		t.Fatal("pair handoff lost acknowledged drain")
	}
	j, err := allocatorjournal.DecodeJournal(string(doc.Admission.Journal))
	j.Binding.Version = doc.AdmissionVersion
	if err != nil || !reflect.DeepEqual(j, want.Journal) {
		t.Fatal("pair handoff lost complete original inventory")
	}
	if f.db.QueryRowContext(t.Context(), "SELECT count(*) FROM storage WHERE collection=$1", allocatoradmission.HandoffCollection).Scan(&count) != nil || count != 1 {
		t.Fatal("pair handoff duplicated")
	}
	if f.db.QueryRowContext(t.Context(), "SELECT version,user_id::text,read,write FROM storage WHERE collection=$1 AND key=$2", allocatoradmission.Collection, admissionObjectID).Scan(&version, &user, &read, &write) != nil || version != pins.Binding.Version || user != zeroOwner || read != 0 || write != 0 {
		t.Fatal("pair root refreshed or lost private ownership")
	}
}

// assertFenceRefused joins the real failed process and requires its specific
// recovery refusal, so an unrelated crash cannot pass a negative control.
func assertFenceRefused(t *testing.T, p *nativeProcess, reason string) {
	t.Helper()
	assertRecoveryRefused(t, p, "fence", reason)
}

// assertRecoveryRefused requires the protocol's exact refusal from the joined
// native process; an unrelated crash cannot satisfy a negative control.
func assertRecoveryRefused(t *testing.T, p *nativeProcess, kind, reason string) {
	t.Helper()
	select {
	case <-p.done:
	case <-time.After(20 * time.Second):
		p.stop(t)
		t.Fatal("refused fence process not joined")
	}
	var exit *exec.ExitError
	if !errors.As(p.err, &exit) || exit.ExitCode() != 1 || !strings.Contains(p.log.String(), "recovery "+kind+" probe: "+reason+" unknown") || strings.Contains(p.log.String(), "NAKAMA RECOVERY "+strings.ToUpper(kind)+" PROBE PASS") {
		t.Fatalf("fresh fence did not produce specific refusal: %s", p.log.String())
	}
}

// settlePairWrite forwards the held original PUT once and checks the real target;
// a conflict must preserve the complete acknowledged barrier observation.
func settlePairWrite(t *testing.T, p *pairAPI, api typed.GameServerInterface, original *agonesv1.GameServer, code int) {
	t.Helper()
	before, err := api.Get(t.Context(), original.Name, metav1.GetOptions{})
	if err != nil {
		t.Fatal("pre-release target unavailable")
	}
	p.held[original.Name].allow()
	select {
	case got := <-p.status[original.Name]:
		if got != code {
			t.Fatalf("original %s PUT HTTP=%d want=%d", original.Name, got, code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("original pair write did not settle")
	}
	after, err := api.Get(t.Context(), original.Name, metav1.GetOptions{})
	if err != nil || after.UID != original.UID || after.ResourceVersion == original.ResourceVersion {
		t.Fatal("pair write did not examine original real target")
	}
	if code == 200 {
		attempt, _ := agones.CorrelationLabel("attempt-original-" + strings.TrimPrefix(original.Name, "zone-"))
		if after.Status.State != agonesv1.GameServerStateAllocated || after.Labels[agones.AttemptLabel] != attempt || after.Annotations[capabilityBarrier] != "" {
			t.Fatal("unfenced pair write did not actually allocate")
		}
	} else if after.Annotations[capabilityBarrier] == "" {
		t.Fatal("old write conflict lacked actual barrier")
	} else if after.ResourceVersion != before.ResourceVersion || !reflect.DeepEqual(after.Annotations, before.Annotations) || !reflect.DeepEqual(after.Labels, before.Labels) || !reflect.DeepEqual(after.Spec, before.Spec) || !reflect.DeepEqual(after.Status, before.Status) {
		t.Fatal("old write changed accepted real barrier")
	}
}

// awaitFenceReady binds health and the complete-proof marker to the elected
// process's own endpoint, including when the second native process wins.
func awaitFenceReady(t *testing.T, p *nativeProcess, port string, publication bool) {
	t.Helper()
	marker := "NAKAMA RECOVERY FENCE PROBE PASS: owner="
	if publication {
		marker = "NAKAMA RECOVERY PUBLICATION PROBE PASS: owner="
	}
	waitFor(t, 20*time.Second, "winning native recovery health", func() bool {
		select {
		case <-p.done:
			t.Fatalf("winning recovery exited: %s", p.log.String())
		default:
		}
		response, err := (&http.Client{Timeout: 200 * time.Millisecond}).Get("http://127.0.0.1:" + port + "/healthcheck")
		if err != nil {
			return false
		}
		_ = response.Body.Close()
		return response.StatusCode == 200 && strings.Contains(p.log.String(), marker)
	})
}

// The supervisor accepts only original-source ACK pins; SQL supplies evidence,
// never recovery input. All cuts kill/join the actual packaged native process.
func TestNativeRecoveryFence(t *testing.T) {
	runNativeRecoveryPair(t, false, []string{"unfenced", "complete", "mixed", "competing", "omitted", "partial", "lost-barrier-ack", "cancel-barrier-ack", "lost-readback", "cancel-readback", "crash-after-submission", "crash-after-ack", "crash-before-export"})
}

// Publication adds actual native storage ACK/readback and process-death cuts
// after the unchanged two-target recovery protocol has completed.
func TestNativeRecoveryPublication(t *testing.T) {
	runNativeRecoveryPair(t, true, []string{"complete", "mixed", "competing", "competing-publishers", "omitted", "omitted-proof", "changed-proof", "lost-proof-ack", "cancel-proof-ack", "lost-proof-readback", "cancel-proof-readback", "crash-before-proof-submit", "crash-after-proof-commit", "crash-after-proof-ack", "crash-before-proof-export"})
}

// runNativeRecoveryPair preserves the full source/owner/barrier fixture while
// the publication mode adds independent supervisor-retained proof pins.
func runNativeRecoveryPair(t *testing.T, publication bool, scenarios []string) {
	t.Helper()
	verifyJournalArtifact(t)
	for _, scenario := range scenarios {
		t.Run(scenario, func(t *testing.T) {
			cfg := ownedControlPlane(t)
			api, a := actualReadyServer(t, cfg)
			b, err := api.Create(t.Context(), &agonesv1.GameServer{ObjectMeta: metav1.ObjectMeta{Name: "zone-b", Labels: map[string]string{agones.FleetLabel: "fleet"}}, Spec: *a.Spec.DeepCopy(), Status: *a.Status.DeepCopy()}, metav1.CreateOptions{})
			if err != nil || b.UID == "" || b.ResourceVersion == "" {
				t.Fatal("second real Ready target unavailable")
			}
			originals := []*agonesv1.GameServer{a, b}
			first, second := a, b
			if string(b.UID) < string(a.UID) {
				first, second = b, a
			}
			traffic := heldPairAPI(t, cfg, scenario, first.Name)
			f := newFixture(t)
			stages := make(map[string]*capabilityStage)
			for _, name := range []string{"registered", "exposed", "close", "drained", "published", "handoff", "a-before-write", "a-written", "a-owner", "a-before-readback-zone-a", "a-before-readback-zone-b", "a-complete", "b-before-write", "b-written", "b-owner", "b-before-readback-zone-a", "b-before-readback-zone-b", "b-complete"} {
				stages[name] = newStage()
			}
			for _, id := range []string{"a", "b"} {
				for _, seam := range []string{"before-proof-submit", "proof-written", "before-proof-readback", "proof-complete"} {
					stages[id+"-"+seam] = newStage()
				}
			}
			pinsReceived := make(chan retainedHandoffPins, 1)
			results := make(chan gameservercommit.RecoveryObservation, 2)
			publications := make(chan gameservercommit.PublicationPins, 2)
			var retainedPublication gameservercommit.PublicationPins
			written := make(chan string, 2)
			control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPost {
					decoder := json.NewDecoder(io.LimitReader(r.Body, 128<<10))
					decoder.DisallowUnknownFields()
					switch r.URL.Path {
					case "/pins":
						var pins retainedHandoffPins
						if decoder.Decode(&pins) != nil || decoder.Decode(&struct{}{}) != io.EOF {
							w.WriteHeader(400)
							return
						}
						select {
						case pinsReceived <- pins:
							w.WriteHeader(204)
						default:
							w.WriteHeader(409)
						}
					case "/recovery-result":
						var result gameservercommit.RecoveryObservation
						if decoder.Decode(&result) != nil || decoder.Decode(&struct{}{}) != io.EOF {
							w.WriteHeader(400)
							return
						}
						select {
						case results <- result:
							w.WriteHeader(204)
						default:
							w.WriteHeader(409)
						}
					case "/publication-pins":
						var pins gameservercommit.PublicationPins
						if !publication || decoder.Decode(&pins) != nil || decoder.Decode(&struct{}{}) != io.EOF {
							w.WriteHeader(400)
							return
						}
						select {
						case publications <- pins:
							results <- pins.Recovery
							w.WriteHeader(204)
						default:
							w.WriteHeader(409)
						}
					default:
						w.WriteHeader(404)
					}
					return
				}
				name := strings.TrimPrefix(r.URL.Path, "/")
				stage := stages[name]
				if r.Method != http.MethodGet || stage == nil {
					w.WriteHeader(404)
					return
				}
				stage.arrival.Do(func() {
					close(stage.entered)
					if name == "a-written" || name == "b-written" {
						written <- strings.TrimSuffix(name, "-written")
					}
				})
				select {
				case <-stage.release:
					w.WriteHeader(204)
				case <-r.Context().Done():
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
			raw, err := json.Marshal(traffic.material)
			if err != nil {
				t.Fatal(err)
			}
			materialPath := filepath.Join(f.dir, "pair-material.json")
			if os.WriteFile(materialPath, raw, 0600) != nil {
				t.Fatal("private pair material unavailable")
			}
			source := f.start(map[string]string{"WAR_DURABLE_RECOVERY_HANDOFF_PROBE_ENABLED": "true", "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_SCENARIO": "pair-held", "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_CONTROL": control.URL, "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_MATERIAL": materialPath}, filepath.Join(*bundle, "modules"), 10)
			stageReached(t, stages["registered"])
			stages["registered"].allow()
			stageReached(t, stages["exposed"])
			stages["exposed"].allow()
			for _, original := range originals {
				stageReached(t, traffic.held[original.Name])
			}
			for range 2 {
				frozen := <-traffic.frozen
				index := 0
				if frozen.Name == "zone-b" {
					index = 1
				}
				original := originals[index]
				attempt, _ := agones.CorrelationLabel("attempt-original-" + strings.TrimPrefix(original.Name, "zone-"))
				if frozen.Name != original.Name || frozen.Namespace != original.Namespace || frozen.UID != original.UID || frozen.ResourceVersion != original.ResourceVersion || frozen.Status.State != agonesv1.GameServerStateAllocated || frozen.Labels[agones.AttemptLabel] != attempt || frozen.Annotations[capabilityBarrier] != "" || !reflect.DeepEqual(frozen.Spec, original.Spec) {
					t.Fatal("pair source did not freeze original allocation")
				}
			}
			stageReached(t, stages["close"])
			stages["close"].allow()
			stageReached(t, stages["drained"])
			stages["drained"].allow()
			stageReached(t, stages["published"])
			stages["published"].allow()
			stageReached(t, stages["handoff"])
			pins := <-pinsReceived
			assertPairHandoff(t, f, originals, pins)
			killJoinedSource(t, source)
			stages["handoff"].allow()
			if scenario == "unfenced" {
				for _, original := range originals {
					settlePairWrite(t, traffic, api, original, 200)
				}
				if traffic.barriers.Load() != 0 {
					t.Fatal("unfenced control emitted a barrier")
				}
				t.Log("RECOVERY FENCE JOIN PASS: scenario=unfenced targets=2 original_puts=200,200 barrier_puts=0 complete_exports=0")
				return
			}
			if scenario == "mixed" {
				settlePairWrite(t, traffic, api, b, 200)
			}
			if scenario == "omitted" {
				if _, err = f.db.ExecContext(t.Context(), "UPDATE storage SET value=jsonb_set(value,'{admission,journal,grants}',(value#>'{admission,journal,grants}') - 1) WHERE collection=$1 AND key=$2", allocatoradmission.HandoffCollection, allocatoradmission.HandoffKey("generation-1")); err != nil {
					t.Fatalf("omitted inventory control failed: %v", err)
				}
				var retained int
				var retainedVersion string
				if err = f.db.QueryRowContext(t.Context(), "SELECT jsonb_array_length(value#>'{admission,journal,grants}'),version FROM storage WHERE collection=$1 AND key=$2", allocatoradmission.HandoffCollection, allocatoradmission.HandoffKey("generation-1")).Scan(&retained, &retainedVersion); err != nil || retained != 1 || retainedVersion != pins.Version {
					t.Fatal("omitted inventory control did not retain exactly one grant at the original version")
				}
			}
			for name, stage := range stages {
				if name == "a-written" || name == "b-written" || (strings.Contains(name, "-before-readback") && (scenario != "crash-after-ack" || name != "a-before-readback-"+first.Name)) {
					stage.allow()
				}
				if strings.Contains(name, "proof") {
					hold := (scenario == "crash-before-proof-submit" && strings.HasSuffix(name, "before-proof-submit")) || ((scenario == "crash-after-proof-commit" || scenario == "omitted-proof" || scenario == "changed-proof") && strings.HasSuffix(name, "proof-written")) || (scenario == "crash-after-proof-ack" && strings.HasSuffix(name, "before-proof-readback")) || (scenario == "crash-before-proof-export" && strings.HasSuffix(name, "proof-complete"))
					if !hold {
						stage.allow()
					}
				}
			}
			// All stage pointers are fixed before any recovery process requests them.
			envFor := func(id string) map[string]string {
				raw, e := json.Marshal(pins)
				if e != nil {
					t.Fatal(e)
				}
				probeScenario := "complete"
				if strings.HasPrefix(scenario, "lost-") || strings.HasPrefix(scenario, "cancel-") {
					probeScenario = scenario
				}
				prefix := "WAR_DURABLE_RECOVERY_FENCE_PROBE_"
				if publication {
					prefix = "WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_"
					if scenario == "competing-publishers" || strings.HasPrefix(scenario, "lost-proof-") || strings.HasPrefix(scenario, "cancel-proof-") {
						probeScenario = scenario
					} else {
						probeScenario = "complete"
					}
				}
				return map[string]string{prefix + "ENABLED": "true", prefix + "ID": id, prefix + "SCENARIO": probeScenario, prefix + "PINS": string(raw), prefix + "MATERIAL": materialPath, prefix + "CONTROL": control.URL}
			}
			traffic.recovering.Store(true)
			recoverer := f.start(envFor("a"), filepath.Join(*bundle, "modules"), 10)
			winnerID := "a"
			var loser *nativeProcess
			if scenario != "omitted" {
				stageReached(t, stages["a-before-write"])
			}
			if scenario == "competing" {
				peer := startRecoveryPeer(t, f, envFor("b"))
				stageReached(t, stages["b-before-write"])
				stages["a-before-write"].allow()
				stages["b-before-write"].allow()
				select {
				case winnerID = <-written:
				case <-time.After(5 * time.Second):
					t.Fatal("no live recoverer acknowledged election")
				}
				if winnerID == "a" {
					loser = peer
				} else {
					loser = recoverer
					recoverer = peer
				}
				assertFenceRefused(t, loser, "reservation")
			} else {
				stages["a-before-write"].allow()
			}
			if scenario == "omitted" {
				assertFenceRefused(t, recoverer, "reservation")
				for _, original := range originals {
					settlePairWrite(t, traffic, api, original, 200)
				}
				if traffic.barriers.Load() != 0 {
					t.Fatal("omitted inventory emitted barrier")
				}
				select {
				case <-results:
					t.Fatal("omitted inventory exported complete proof")
				default:
				}
				if publication {
					var count int
					if f.db.QueryRowContext(t.Context(), "SELECT count(*) FROM storage WHERE collection=$1", gameservercommit.RecoveryProofCollection).Scan(&count) != nil || count != 0 {
						t.Fatal("omitted original inventory wrote a proof")
					}
					select {
					case <-publications:
						t.Fatal("omitted inventory exported publication pins")
					default:
					}
					t.Log("RECOVERY PUBLICATION JOIN PASS: scenario=omitted targets=2 proof_rows=0 independent_pin_export=false original_puts=200,200 barrier_puts=0 source_joined=1 publisher_joined=1")
				}
				t.Log("RECOVERY FENCE JOIN PASS: scenario=omitted targets=2 original_puts=200,200 barrier_puts=0 complete_exports=0")
				return
			}
			stageReached(t, stages[winnerID+"-owner"])
			stages[winnerID+"-owner"].allow()
			success := scenario == "complete" || scenario == "mixed" || scenario == "competing" || scenario == "competing-publishers"
			expectedBarriers := 1
			if publication {
				stageReached(t, stages[winnerID+"-complete"])
				stages[winnerID+"-complete"].allow()
				expectedBarriers = 2
				runPublicationCut(t, f, recoverer, stages, scenario, winnerID, success)
			} else {
				switch scenario {
				case "crash-after-submission":
					stageReached(t, traffic.barrierWritten)
					killJoinedSource(t, recoverer)
					traffic.barrierWritten.allow()
				case "crash-after-ack":
					stageReached(t, stages["a-before-readback-"+first.Name])
					killJoinedSource(t, recoverer)
					stages["a-before-readback-"+first.Name].allow()
				case "crash-before-export":
					stageReached(t, stages["a-complete"])
					killJoinedSource(t, recoverer)
					stages["a-complete"].allow()
					expectedBarriers = 2
				default:
					if success {
						stageReached(t, stages[winnerID+"-complete"])
						stages[winnerID+"-complete"].allow()
						expectedBarriers = 2
					} else {
						assertFenceRefused(t, recoverer, "barrier outcome")
					}
				}
			}
			if traffic.barriers.Load() != int32(expectedBarriers) || traffic.allocations.Load() != 2 {
				t.Fatal("recovery omitted/replayed mutation inventory")
			}
			if success {
				if publication {
					var pins gameservercommit.PublicationPins
					select {
					case pins = <-publications:
					case <-time.After(time.Second):
						t.Fatal("acknowledged publication pins not retained independently")
					}
					assertPublishedPair(t, f, pins, winnerID)
					retainedPublication = pins
				}
				var complete gameservercommit.RecoveryObservation
				select {
				case complete = <-results:
				case <-time.After(time.Second):
					t.Fatal("complete recovery not exported")
				}
				want := pairExpected(t, originals, pins)
				if complete.Owner.OwnerID != winnerID || complete.Owner.Version == "" || complete.Owner.HandoffVersion != pins.Version || !reflect.DeepEqual(complete.Owner.Handoff, want) || len(complete.Grants) != 2 {
					t.Fatal("export lost original complete owner binding")
				}
				var value, version, user string
				var read, write int
				if f.db.QueryRowContext(t.Context(), "SELECT value::text,version,user_id::text,read,write FROM storage WHERE collection=$1 AND key=$2", allocatoradmission.RecoveryOwnerCollection, allocatoradmission.RecoveryOwnerKey("generation-1")).Scan(&value, &version, &user, &read, &write) != nil || version != complete.Owner.Version || user != zeroOwner || read != 0 || write != 0 {
					t.Fatal("complete result lost actual private owner ACK")
				}
				stored, e := allocatoradmission.DecodeRecoveryOwner(value)
				stored.Version = version
				if e != nil || !reflect.DeepEqual(stored, complete.Owner) {
					t.Fatal("complete result changed acknowledged owner inventory")
				}
				for i, grant := range complete.Grants {
					original := a
					if grant.Name == "zone-b" {
						original = b
					}
					outcome := gameservercommit.Uncommitted
					if scenario == "mixed" && grant.Name == "zone-b" {
						outcome = gameservercommit.Allocated
					}
					actual, e := api.Get(t.Context(), original.Name, metav1.GetOptions{})
					if e != nil || grant.ActorUID != want.Journal.Grants[i].ActorUID || grant.AttemptID != want.Journal.Grants[i].AttemptID || grant.Name != original.Name || grant.UID != string(original.UID) || grant.SourceVersion != original.ResourceVersion || grant.BarrierVersion != actual.ResourceVersion || grant.Outcome != outcome || actual.Annotations[capabilityBarrier] == "" {
						t.Fatal("complete barrier result lost exact target outcome")
					}
				}
			} else {
				select {
				case <-results:
					t.Fatal("partial or dead recovery exported complete proof")
				default:
				}
			}
			// Settle old writes BEFORE restart controls to preserve their 10s holds.
			if scenario == "mixed" {
				settlePairWrite(t, traffic, api, a, 409)
			} else {
				settlePairWrite(t, traffic, api, first, 409)
				code := 200
				if expectedBarriers == 2 {
					code = 409
				}
				settlePairWrite(t, traffic, api, second, code)
			}
			if success {
				port := "7350"
				if winnerID == "b" {
					port = "7360"
				}
				awaitFenceReady(t, recoverer, port, publication)
				killJoinedSource(t, recoverer)
			}
			if publication && success {
				// Only the joined publisher's independently retained ACK pins are
				// input. SQL/visible proof rows never supply or repair those pins.
				raw, e := json.Marshal(retainedPublication)
				if e != nil {
					t.Fatal(e)
				}
				readerEnv := map[string]string{"WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_ENABLED": "true", "WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_ID": winnerID, "WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_SCENARIO": "read", "WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_CONTROL": control.URL, "WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_PUBLICATION_PINS": string(raw)}
				reader := f.launch(readerEnv, filepath.Join(*bundle, "modules"), 10, true)
				if !strings.Contains(reader.log.String(), "NAKAMA RECOVERY PUBLICATION PROBE PASS: owner="+winnerID) {
					t.Fatal("fresh pinned reader did not validate complete proof")
				}
				killJoinedSource(t, reader)
			}
			for _, id := range []string{"a", "b"} {
				stages[id+"-before-write"].allow()
				rejected := f.start(envFor(id), filepath.Join(*bundle, "modules"), 10)
				assertFenceRefused(t, rejected, "reservation")
			}
			select {
			case <-results:
				t.Fatal("restart restored complete export")
			default:
			}
			if publication {
				select {
				case <-publications:
					t.Fatal("uncertain or restarted publisher exported proof pins")
				default:
				}
				var count int
				want := 1
				if scenario == "crash-before-proof-submit" {
					want = 0
				}
				if f.db.QueryRowContext(t.Context(), "SELECT count(*) FROM storage WHERE collection=$1", gameservercommit.RecoveryProofCollection).Scan(&count) != nil || count != want {
					t.Fatalf("proof row inventory=%d want=%d", count, want)
				}
				t.Logf("RECOVERY PUBLICATION JOIN PASS: scenario=%s targets=2 proof_rows=%d independent_pin_export=%t source_joined=1 publisher_joined=1 restart_refusals=2", scenario, count, success)
			}
			if traffic.allocations.Load() != 2 || traffic.barriers.Load() != int32(expectedBarriers) {
				t.Fatal("restart replayed original allocation/barrier")
			}
			var ownerCount int
			if f.db.QueryRowContext(t.Context(), "SELECT count(*) FROM storage WHERE collection=$1", allocatoradmission.RecoveryOwnerCollection).Scan(&ownerCount) != nil || ownerCount != 1 {
				t.Fatal("recovery stole or removed permanent exclusion")
			}
			t.Logf("RECOVERY FENCE JOIN PASS: scenario=%s targets=2 barrier_puts=%d complete_export=%t source_joined=1 recovery_joined=1 restart_refusals=2", scenario, expectedBarriers, success)
		})
	}
}

// runPublicationCut kills and joins the actual native publisher at each owned
// storage seam, or joins its exact uncertainty refusal after a real reply cut.
func runPublicationCut(t *testing.T, f *fixture, p *nativeProcess, stages map[string]*capabilityStage, scenario, id string, success bool) {
	t.Helper()
	seam := ""
	switch scenario {
	case "crash-before-proof-submit":
		seam = "before-proof-submit"
	case "crash-after-proof-commit":
		seam = "proof-written"
	case "crash-after-proof-ack":
		seam = "before-proof-readback"
	case "crash-before-proof-export":
		seam = "proof-complete"
	}
	if seam != "" {
		stageReached(t, stages[id+"-"+seam])
		killJoinedSource(t, p)
		stages[id+"-"+seam].allow()
		return
	}
	if scenario == "omitted-proof" || scenario == "changed-proof" {
		stageReached(t, stages[id+"-proof-written"])
		var before string
		key := gameservercommit.RecoveryProofKey("generation-1")
		if f.db.QueryRowContext(t.Context(), "SELECT version FROM storage WHERE collection=$1 AND key=$2", gameservercommit.RecoveryProofCollection, key).Scan(&before) != nil || before == "" {
			t.Fatal("proof mutation control lacks actual committed row")
		}
		query := "UPDATE storage SET value=jsonb_set(value,'{grants}',(value->'grants') - 1) WHERE collection=$1 AND key=$2"
		if scenario == "changed-proof" {
			query = "UPDATE storage SET value=jsonb_set(value,'{grants,0,outcome}','\"allocated-before-barrier\"'::jsonb) WHERE collection=$1 AND key=$2"
		}
		if _, err := f.db.ExecContext(t.Context(), query, gameservercommit.RecoveryProofCollection, key); err != nil {
			t.Fatal("proof mutation control failed", err)
		}
		var value, after string
		if f.db.QueryRowContext(t.Context(), "SELECT value::text,version FROM storage WHERE collection=$1 AND key=$2", gameservercommit.RecoveryProofCollection, key).Scan(&value, &after) != nil || after != before {
			t.Fatal("proof mutation control changed the storage version")
		}
		got, err := gameservercommit.DecodeRecoveryProof(value)
		if scenario == "omitted-proof" && !errors.Is(err, gameservercommit.ErrUnknown) {
			t.Fatal("omitted actual proof remained complete")
		}
		if scenario == "changed-proof" && (err != nil || got.Grants[0].Outcome != gameservercommit.Allocated) {
			t.Fatal("changed valid proof control did not change its complete outcome")
		}
		stages[id+"-proof-written"].allow()
	}
	if !success {
		assertRecoveryRefused(t, p, "publication", "publication")
	}
}

// assertPublishedPair independently joins retained live ACK pins with the exact
// actual private PostgreSQL row; the row supplies evidence, never trusted input.
func assertPublishedPair(t *testing.T, f *fixture, pins gameservercommit.PublicationPins, id string) {
	t.Helper()
	var value, version, user string
	var read, write, count int
	key := gameservercommit.RecoveryProofKey("generation-1")
	if pins.Version == "" || pins.Recovery.Owner.OwnerID != id || len(pins.Recovery.Grants) != 2 || f.db.QueryRowContext(t.Context(), "SELECT value::text,version,user_id::text,read,write FROM storage WHERE collection=$1 AND key=$2", gameservercommit.RecoveryProofCollection, key).Scan(&value, &version, &user, &read, &write) != nil || version != pins.Version || user != zeroOwner || read != 0 || write != 0 {
		t.Fatal("publication lacks exact private actual ACK row")
	}
	got, err := gameservercommit.DecodeRecoveryProof(value)
	if err != nil || !reflect.DeepEqual(got, pins.Recovery) {
		t.Fatal("actual proof row lost complete originating recovery")
	}
	if f.db.QueryRowContext(t.Context(), "SELECT count(*) FROM storage WHERE collection=$1", gameservercommit.RecoveryProofCollection).Scan(&count) != nil || count != 1 {
		t.Fatal("competing publisher created multiple proofs")
	}
}
