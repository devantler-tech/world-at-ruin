//go:build war_native_trial

package nakamatrial

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func ownerEnv(t *testing.T, pins retainedHandoffPins, id, scenario, control string) map[string]string {
	t.Helper()
	raw, err := json.Marshal(pins)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{"WAR_DURABLE_RECOVERY_OWNER_PROBE_ENABLED": "true", "WAR_DURABLE_RECOVERY_OWNER_PROBE_PINS": string(raw), "WAR_DURABLE_RECOVERY_OWNER_PROBE_ID": id, "WAR_DURABLE_RECOVERY_OWNER_PROBE_SCENARIO": scenario, "WAR_DURABLE_RECOVERY_OWNER_PROBE_CONTROL": control}
}

// startRecoveryPeer owns a second live Nakama process in the same disposable
// database, with separate node/port/config identity. start would stop its rival.
func startRecoveryPeer(t *testing.T, f *fixture, env map[string]string) *nativeProcess {
	t.Helper()
	f.writeConfig(env, filepath.Join(*bundle, "modules"), 10)
	raw, err := os.ReadFile(filepath.Join(f.dir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	if json.Unmarshal(raw, &cfg) != nil {
		t.Fatal("peer config unavailable")
	}
	cfg["name"] = "war-owner-peer"
	cfg["socket"].(map[string]any)["port"] = 7360
	cfg["console"].(map[string]any)["port"] = 7361
	raw, err = json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(f.dir, "peer-config.json")
	if os.WriteFile(path, raw, 0600) != nil {
		t.Fatal("private peer config unavailable")
	}
	p := &nativeProcess{cmd: exec.Command(filepath.Join(*bundle, "nakama"), "--config", path), done: make(chan struct{}), log: &lockedLog{}}
	p.cmd.Env = append(os.Environ(), "NAKAMA_TELEMETRY=0")
	p.cmd.Stdout, p.cmd.Stderr = p.log, p.log
	if err = p.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.stop(t) })
	go func() { p.err = p.cmd.Wait(); close(p.done) }()
	return p
}

func assertOwnerRefused(t *testing.T, p *nativeProcess) {
	t.Helper()
	select {
	case <-p.done:
	case <-time.After(20 * time.Second):
		p.stop(t)
		t.Fatal("refused owner not joined")
	}
	var exit *exec.ExitError
	if !errors.As(p.err, &exit) || exit.ExitCode() != 1 || !strings.Contains(p.log.String(), "recovery owner probe: reservation unknown") || strings.Contains(p.log.String(), "NAKAMA RECOVERY OWNER PROBE PASS") {
		t.Fatal("owner did not produce its specific fail-closed refusal")
	}
}
func awaitOwnerReady(t *testing.T, p *nativeProcess, port string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-p.done:
			t.Fatalf("winning owner failed native startup: %s", p.log.String())
		case <-ctx.Done():
			t.Fatal("winning native owner did not become ready")
		default:
		}
		response, err := (&http.Client{Timeout: 200 * time.Millisecond}).Get("http://127.0.0.1:" + port + "/healthcheck")
		if err == nil {
			_ = response.Body.Close()
			if response.StatusCode == 200 && strings.Contains(p.log.String(), "NAKAMA RECOVERY OWNER PROBE PASS: owner=") {
				return
			}
		}
		select {
		case <-ticker.C:
		case <-ctx.Done():
			t.Fatal("winning native owner startup timed out")
		}
	}
}

func assertOwnerRows(t *testing.T, f *fixture, original *agonesv1.GameServer, pins retainedHandoffPins, id string, ack *allocatoradmission.RecoveryOwnerObservation) {
	t.Helper()
	assertHandoffRows(t, f, original, pins)
	var value, version, user string
	var read, write, count int
	if f.db.QueryRowContext(t.Context(), "SELECT count(*) FROM storage WHERE collection=$1", allocatoradmission.RecoveryOwnerCollection).Scan(&count) != nil || count != 1 {
		t.Fatal("recovery did not persist exactly one generation owner")
	}
	if f.db.QueryRowContext(t.Context(), "SELECT value::text,version,user_id::text,read,write FROM storage WHERE collection=$1 AND key=$2", allocatoradmission.RecoveryOwnerCollection, allocatoradmission.RecoveryOwnerKey("generation-1")).Scan(&value, &version, &user, &read, &write) != nil || version == "" || version == "*" || user != zeroOwner || read != 0 || write != 0 {
		t.Fatal("owner row is not private with an exact acknowledged version")
	}
	got, err := allocatoradmission.DecodeRecoveryOwner(value)
	if err != nil || got.OwnerID != id || got.HandoffVersion != pins.Version || !reflect.DeepEqual(got.Handoff, handoffExpected(t, original, pins)) {
		t.Fatal("owner lost original complete frozen inventory")
	}
	if ack != nil {
		got.Version = version
		if !reflect.DeepEqual(got, *ack) {
			t.Fatal("independently retained owner ACK does not match actual private row")
		}
	}
}
func assertOwnerRowsAbsent(t *testing.T, f *fixture) {
	t.Helper()
	var count int
	if f.db.QueryRowContext(t.Context(), "SELECT count(*) FROM storage WHERE collection=$1", allocatoradmission.RecoveryOwnerCollection).Scan(&count) != nil || count != 0 {
		t.Fatal("unacknowledged original pins manufactured owner")
	}
}

// No SQL seed elects a winner. Two actual fresh native writers compete through
// Nakama create-only storage. SQL observes their results, never supplies pins.
// Held original PUTs remain a positive allocation control: election is no fence.
func TestNativeRecoveryOwner(t *testing.T) {
	verifyJournalArtifact(t)
	for _, scenario := range []string{"race", "lost-owner-ack", "cancel-owner-ack", "crash-before-write", "crash-after-write", "crash-after-ack", "changed-handoff"} {
		t.Run(scenario, func(t *testing.T) {
			cfg := ownedControlPlane(t)
			api, original := actualReadyServer(t, cfg)
			material, held, traffic, status := heldActualAPI(t, cfg)
			f := newFixture(t)
			stages := map[string]*capabilityStage{}
			for _, name := range []string{"registered", "exposed", "close", "drained", "published", "handoff", "a-before-write", "a-written", "a-accepted", "b-before-write", "b-written", "b-accepted"} {
				stages[name] = newStage()
			}
			pinsReceived := make(chan retainedHandoffPins, 1)
			ownersReceived := make(chan allocatoradmission.RecoveryOwnerObservation, 2)
			written := make(chan string, 2)
			control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPost {
					decoder := json.NewDecoder(io.LimitReader(r.Body, 64<<10))
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
					case "/owner-pins":
						var ack allocatoradmission.RecoveryOwnerObservation
						if decoder.Decode(&ack) != nil || decoder.Decode(&struct{}{}) != io.EOF {
							w.WriteHeader(400)
							return
						}
						select {
						case ownersReceived <- ack:
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
					if strings.HasSuffix(name, "-written") {
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
			raw, err := json.Marshal(material)
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(f.dir, "owner-material.json")
			if os.WriteFile(path, raw, 0600) != nil {
				t.Fatal("private source material unavailable")
			}
			source := f.start(map[string]string{"WAR_DURABLE_RECOVERY_HANDOFF_PROBE_ENABLED": "true", "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_SCENARIO": "held-put", "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_CONTROL": control.URL, "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_MATERIAL": path}, filepath.Join(*bundle, "modules"), 10)
			stageReached(t, stages["registered"])
			stages["registered"].allow()
			stageReached(t, stages["exposed"])
			stages["exposed"].allow()
			stageReached(t, held)
			captured := <-traffic.frozen
			if captured.UID != original.UID || captured.ResourceVersion != original.ResourceVersion {
				t.Fatal("original PUT target changed")
			}
			stageReached(t, stages["close"])
			stages["close"].allow()
			stageReached(t, stages["drained"])
			stages["drained"].allow()
			stageReached(t, stages["published"])
			stages["published"].allow()
			stageReached(t, stages["handoff"])
			var pins retainedHandoffPins
			select {
			case pins = <-pinsReceived:
			default:
				t.Fatal("supervisor did not retain original acknowledged pins")
			}
			assertHandoffRows(t, f, original, pins)
			killJoinedSource(t, source)
			stages["handoff"].allow()
			assertOwnerRowsAbsent(t, f)
			if scenario == "changed-handoff" {
				var base, root string
				if f.db.QueryRowContext(t.Context(), "SELECT value::text FROM storage WHERE collection=$1", allocatoradmission.HandoffCollection).Scan(&base) != nil || f.db.QueryRowContext(t.Context(), "SELECT value::text FROM storage WHERE collection=$1", allocatoradmission.Collection).Scan(&root) != nil {
					t.Fatal("disposable original rows unavailable")
				}
				for _, fault := range []string{"stale-handoff", "changed-root", "omitted-inventory", "public-handoff", "missing-handoff"} {
					switch fault {
					case "stale-handoff":
						_, err = f.db.ExecContext(t.Context(), "UPDATE storage SET version='changed' WHERE collection=$1", allocatoradmission.HandoffCollection)
					case "changed-root":
						_, err = f.db.ExecContext(t.Context(), "UPDATE storage SET version='changed' WHERE collection=$1", allocatoradmission.Collection)
					case "omitted-inventory":
						_, err = f.db.ExecContext(t.Context(), "UPDATE storage SET value=jsonb_set(value,'{admission,journal,grants}','[]'::jsonb) WHERE collection=$1", allocatoradmission.HandoffCollection)
					case "public-handoff":
						_, err = f.db.ExecContext(t.Context(), "UPDATE storage SET read=1 WHERE collection=$1", allocatoradmission.HandoffCollection)
					case "missing-handoff":
						_, err = f.db.ExecContext(t.Context(), "DELETE FROM storage WHERE collection=$1", allocatoradmission.HandoffCollection)
					}
					if err != nil {
						t.Fatal("disposable refusal control failed")
					}
					rejected := f.start(ownerEnv(t, pins, "a", "reserve", control.URL), filepath.Join(*bundle, "modules"), 10)
					assertOwnerRefused(t, rejected)
					assertOwnerRowsAbsent(t, f)
					if fault != "missing-handoff" {
						if _, err = f.db.ExecContext(t.Context(), "UPDATE storage SET value=$1::text::jsonb,version=$2,read=0 WHERE collection=$3", base, pins.Version, allocatoradmission.HandoffCollection); err != nil {
							t.Fatal(err)
						}
					}
					if _, err = f.db.ExecContext(t.Context(), "UPDATE storage SET value=$1::text::jsonb,version=$2 WHERE collection=$3", root, pins.Binding.Version, allocatoradmission.Collection); err != nil {
						t.Fatal(err)
					}
				}
			} else {
				mode := "reserve"
				if scenario == "lost-owner-ack" || scenario == "cancel-owner-ack" {
					mode = scenario
				}
				a := f.start(ownerEnv(t, pins, "a", mode, control.URL), filepath.Join(*bundle, "modules"), 10)
				stageReached(t, stages["a-before-write"])
				if scenario == "crash-before-write" {
					assertOwnerRowsAbsent(t, f)
					killJoinedSource(t, a)
					stages["a-before-write"].allow()
					b := f.start(ownerEnv(t, pins, "b", "reserve", control.URL), filepath.Join(*bundle, "modules"), 10)
					stageReached(t, stages["b-before-write"])
					stages["b-before-write"].allow()
					stageReached(t, stages["b-written"])
					stages["b-written"].allow()
					stageReached(t, stages["b-accepted"])
					stages["b-accepted"].allow()
					awaitOwnerReady(t, b, "7350")
					ack := <-ownersReceived
					assertOwnerRows(t, f, original, pins, "b", &ack)
					killJoinedSource(t, b)
				} else if scenario == "race" {
					b := startRecoveryPeer(t, f, ownerEnv(t, pins, "b", "reserve", control.URL))
					stageReached(t, stages["b-before-write"])
					stages["a-before-write"].allow()
					stages["b-before-write"].allow()
					var id string
					select {
					case id = <-written:
					case <-time.After(5 * time.Second):
						t.Fatal("two native writers did not elect an owner")
					}
					winner, loser, port := a, b, "7350"
					if id == "b" {
						winner, loser, port = b, a, "7360"
					}
					assertOwnerRows(t, f, original, pins, id, nil)
					stages[id+"-written"].allow()
					stageReached(t, stages[id+"-accepted"])
					stages[id+"-accepted"].allow()
					assertOwnerRefused(t, loser)
					awaitOwnerReady(t, winner, port)
					ack := <-ownersReceived
					assertOwnerRows(t, f, original, pins, id, &ack)
					select {
					case <-written:
						t.Fatal("second live writer also acknowledged create")
					default:
					}
					select {
					case <-ownersReceived:
						t.Fatal("two processes exported owner reservations")
					default:
					}
					killJoinedSource(t, winner)
				} else {
					stages["a-before-write"].allow()
					stageReached(t, stages["a-written"])
					assertOwnerRows(t, f, original, pins, "a", nil)
					if scenario == "crash-after-write" {
						killJoinedSource(t, a)
						stages["a-written"].allow()
					} else {
						stages["a-written"].allow()
						if scenario == "crash-after-ack" {
							stageReached(t, stages["a-accepted"])
							killJoinedSource(t, a)
							stages["a-accepted"].allow()
						} else {
							assertOwnerRefused(t, a)
						}
					}
					select {
					case <-ownersReceived:
						t.Fatal("ambiguous or dead owner exported usable pins")
					default:
					}
				}
				// A new process with the SAME owner ID cannot resume even a visible exact
				// row. A different ID also competes on the same generation-wide key.
				for _, id := range []string{"a", "b"} {
					stages[id+"-before-write"].allow()
					rejected := f.start(ownerEnv(t, pins, id, "reserve", control.URL), filepath.Join(*bundle, "modules"), 10)
					assertOwnerRefused(t, rejected)
				}
			}
			// Election has issued no Kubernetes request. Release the exact old write
			// after both the source and reservation owner have died: it still allocates.
			if traffic.barriers.Load() != 0 || traffic.allocations.Load() != 1 || traffic.gets.Load() != 1 {
				t.Fatal("reservation issued an allocation or barrier")
			}
			held.allow()
			select {
			case code := <-status:
				if code != 200 {
					t.Fatalf("unfenced original PUT status %d", code)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("held old write did not settle")
			}
			after, err := api.Get(context.Background(), original.Name, metav1.GetOptions{})
			if err != nil || after.UID != original.UID || after.ResourceVersion == original.ResourceVersion || after.Status.State != agonesv1.GameServerStateAllocated || after.Annotations[capabilityBarrier] != "" || traffic.allocations.Load() != 1 || traffic.barriers.Load() != 0 {
				t.Fatal("owner-only positive control did not allocate without a fence")
			}
			t.Logf("RECOVERY OWNER JOIN PASS: scenario=%s original_put_http=200 barrier_puts=0 restored_authority=0", scenario)
		})
	}
}
