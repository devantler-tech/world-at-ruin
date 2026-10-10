//go:build war_native_trial

package nakamatrial

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type retainedHandoffPins struct {
	Binding allocatorjournal.JournalBinding `json:"binding"`
	Version string                          `json:"version"`
}

// A missing PASS is insufficient: an unrelated startup failure never proves
// the reader examined and refused the supplied recovery expectations.
func assertHandoffRefused(t *testing.T, p *nativeProcess) {
	t.Helper()
	var exit *exec.ExitError
	if !errors.As(p.err, &exit) || exit.ExitCode() != 1 || !strings.Contains(p.log.String(), "handoff probe: pinned readback unknown") || strings.Contains(p.log.String(), "NAKAMA HANDOFF PROBE PASS") {
		t.Fatal("native reader did not produce its specific fail-closed refusal")
	}
}

func killJoinedSource(t *testing.T, p *nativeProcess) {
	t.Helper()
	if err := p.cmd.Process.Kill(); err != nil {
		t.Fatal("owned source kill failed")
	}
	select {
	case <-p.done:
	case <-time.After(5 * time.Second):
		t.Fatal("owned source not joined")
	}
}
func handoffReadEnv(t *testing.T, pins retainedHandoffPins) map[string]string {
	t.Helper()
	raw, e := json.Marshal(pins)
	if e != nil {
		t.Fatal(e)
	}
	return map[string]string{"WAR_DURABLE_RECOVERY_HANDOFF_PROBE_ENABLED": "true", "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_SCENARIO": "read", "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_PINS": string(raw)}
}
func handoffExpected(t *testing.T, original *agonesv1.GameServer, pins retainedHandoffPins) allocatoradmission.Observation {
	t.Helper()
	grants := []allocatorjournal.JournalGrant{{ActorUID: "pod-a", AttemptID: "attempt-original", Name: original.Name, UID: string(original.UID), SourceVersion: original.ResourceVersion}}
	raw, e := json.Marshal(grants)
	if e != nil {
		t.Fatal(e)
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-issued-grants/v1\n"), raw...))
	b := pins.Binding
	if b.GenerationID != "generation-1" || b.GenerationVersion != "source-version-1" || b.IncarnationID != "native-incarnation" || b.Namespace != "trial" || b.Fleet != "fleet" || b.MemberSetDigest != "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d" || !reflect.DeepEqual(b.MemberPodUIDs, []string{"pod-a", "pod-b"}) || b.IssuedCount != 1 || b.IssuedDigest != hex.EncodeToString(digest[:]) || b.Version == "" || pins.Version == "" {
		t.Fatal("acknowledged pins changed original complete binding")
	}
	return allocatoradmission.Observation{Phase: "draining", Journal: allocatorjournal.JournalObservation{Binding: b, Grants: grants}}
}
func assertHandoffRows(t *testing.T, f *fixture, original *agonesv1.GameServer, pins retainedHandoffPins) {
	t.Helper()
	want := handoffExpected(t, original, pins)
	var value, version, owner string
	var read, write, count int
	if f.db.QueryRowContext(t.Context(), "SELECT value::text,version,user_id::text,read,write FROM storage WHERE collection=$1 AND key=$2", allocatoradmission.HandoffCollection, allocatoradmission.HandoffKey("generation-1")).Scan(&value, &version, &owner, &read, &write) != nil || version != pins.Version || owner != zeroOwner || read != 0 || write != 0 {
		t.Fatal("acknowledged handoff lacks private exact row")
	}
	if f.db.QueryRowContext(t.Context(), "SELECT count(*) FROM storage WHERE collection=$1", allocatoradmission.HandoffCollection).Scan(&count) != nil || count != 1 {
		t.Fatal("more than one generation handoff")
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
		t.Fatal("native handoff lost acknowledged root")
	}
	j, e := allocatorjournal.DecodeJournal(string(doc.Admission.Journal))
	j.Binding.Version = doc.AdmissionVersion
	if e != nil || !reflect.DeepEqual(j, want.Journal) {
		t.Fatal("native handoff lost original complete inventory")
	}
	var rootVersion string
	if f.db.QueryRowContext(t.Context(), "SELECT version FROM storage WHERE collection=$1 AND key=$2", allocatoradmission.Collection, admissionObjectID).Scan(&rootVersion) != nil || rootVersion != pins.Binding.Version {
		t.Fatal("handoff refreshed original drain version")
	}
}
func assertNoHandoffAuthority(t *testing.T, f *fixture, expectedRows int, traffic *capabilityTraffic) {
	t.Helper()
	var rows int
	if f.db.QueryRowContext(t.Context(), "SELECT count(*) FROM storage WHERE collection=$1", allocatoradmission.HandoffCollection).Scan(&rows) != nil || rows != expectedRows || traffic.barriers.Load() != 0 {
		t.Fatal("uncertain handoff changed publication or issued barrier")
	}
}

// The source actually acknowledges Nakama transactions. The supervisor retains
// only pins delivered AFTER publication validation; SQL is independent evidence,
// never an alternate source of trusted recovery input.
func TestNativeRecoveryHandoff(t *testing.T) {
	verifyJournalArtifact(t)
	for _, scenario := range []string{"held-put", "late-ack", "lost-drain-ack", "lost-handoff-ack", "cancel-handoff-ack", "crash-after-drain", "competing-handoff"} {
		t.Run(scenario, func(t *testing.T) {
			cfg := ownedControlPlane(t)
			api, original := actualReadyServer(t, cfg)
			material, held, traffic, status := heldActualAPI(t, cfg)
			f := newFixture(t)
			stages := map[string]*capabilityStage{}
			for _, stage := range []string{"registered", "closing", "exposed", "close", "drained", "published", "before-publish", "handoff", "unknown"} {
				stages[stage] = newStage()
			}
			pinsReceived := make(chan retainedHandoffPins, 1)
			control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPost && r.URL.Path == "/pins" {
					var pins retainedHandoffPins
					decoder := json.NewDecoder(io.LimitReader(r.Body, 64<<10))
					decoder.DisallowUnknownFields()
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
					return
				}
				stage := stages[strings.TrimPrefix(r.URL.Path, "/")]
				if r.Method != http.MethodGet || stage == nil {
					w.WriteHeader(404)
					return
				}
				stage.arrival.Do(func() { close(stage.entered) })
				select {
				case <-stage.release:
					w.WriteHeader(204)
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
			value, e := json.Marshal(material)
			if e != nil {
				t.Fatal(e)
			}
			path := filepath.Join(f.dir, "handoff-material.json")
			if os.WriteFile(path, value, 0600) != nil {
				t.Fatal("private fixture material unavailable")
			}
			env := map[string]string{"WAR_DURABLE_RECOVERY_HANDOFF_PROBE_ENABLED": "true", "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_SCENARIO": scenario, "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_CONTROL": control.URL, "WAR_DURABLE_RECOVERY_HANDOFF_PROBE_MATERIAL": path}
			source := f.start(env, filepath.Join(*bundle, "modules"), 10)
			stageReached(t, stages["registered"])
			assertCapabilityRow(t, f, original, "open")
			if traffic.gets.Load() != 1 || traffic.allocations.Load() != 0 {
				t.Fatal("mutation escaped before registration acknowledgment")
			}
			if scenario == "late-ack" {
				stageReached(t, stages["closing"])
				stages["closing"].allow()
			}
			stages["registered"].allow()
			if scenario == "held-put" {
				stageReached(t, stages["exposed"])
				stages["exposed"].allow()
				stageReached(t, held)
				captured := <-traffic.frozen
				attempt, e := agones.CorrelationLabel("attempt-original")
				if e != nil || captured.UID != original.UID || captured.ResourceVersion != original.ResourceVersion || captured.Namespace != original.Namespace || captured.Name != original.Name || captured.Labels[agones.AttemptLabel] != attempt || captured.Annotations[capabilityBarrier] != "" || !reflect.DeepEqual(captured.Spec, original.Spec) {
					t.Fatal("held write changed original frozen target")
				}
				stageReached(t, stages["close"])
				stages["close"].allow()
			}
			stageReached(t, stages["drained"])
			assertCapabilityRow(t, f, original, "draining")
			assertNoHandoffAuthority(t, f, 0, traffic)
			if scenario == "competing-handoff" {
				if _, e = f.db.ExecContext(t.Context(), "INSERT INTO storage(collection,key,user_id,value,version,read,write,create_time,update_time) VALUES($1,$2,$3::uuid,'{}'::jsonb,'competing',0,0,now(),now())", allocatoradmission.HandoffCollection, allocatoradmission.HandoffKey("generation-1"), zeroOwner); e != nil {
					t.Fatal("competing private handoff setup failed")
				}
			}
			stages["drained"].allow()
			if scenario == "crash-after-drain" {
				stageReached(t, stages["before-publish"])
				assertNoHandoffAuthority(t, f, 0, traffic)
				killJoinedSource(t, source)
				stages["before-publish"].allow()
				rejected := f.launch(handoffReadEnv(t, retainedHandoffPins{}), filepath.Join(*bundle, "modules"), 10, false)
				assertHandoffRefused(t, rejected)
				assertNoHandoffAuthority(t, f, 0, traffic)
				t.Log("HANDOFF JOIN PASS: scenario=crash-after-drain retained_pins=0 restored_authority=0")
				return
			}
			if scenario != "lost-drain-ack" && scenario != "competing-handoff" {
				stageReached(t, stages["published"])
				stages["published"].allow()
			}
			if scenario == "lost-drain-ack" || scenario == "lost-handoff-ack" || scenario == "cancel-handoff-ack" || scenario == "competing-handoff" {
				stageReached(t, stages["unknown"])
				select {
				case <-pinsReceived:
					t.Fatal("unknown acknowledgment exported pins")
				default:
				}
				rows := 1
				if scenario == "lost-drain-ack" {
					rows = 0
				}
				assertNoHandoffAuthority(t, f, rows, traffic)
				if scenario == "competing-handoff" {
					var version string
					if f.db.QueryRowContext(t.Context(), "SELECT version FROM storage WHERE collection=$1", allocatoradmission.HandoffCollection).Scan(&version) != nil || version != "competing" {
						t.Fatal("create-only handoff replaced competing publication")
					}
				}
				stages["unknown"].allow()
				source = f.awaitStartup(source, true)
				if !strings.Contains(source.log.String(), "NAKAMA HANDOFF PROBE PASS: scenario="+scenario) {
					t.Fatal("unknown reply control incomplete")
				}
				source.stop(t)
				rejected := f.launch(handoffReadEnv(t, retainedHandoffPins{}), filepath.Join(*bundle, "modules"), 10, false)
				assertHandoffRefused(t, rejected)
				assertNoHandoffAuthority(t, f, rows, traffic)
				t.Logf("HANDOFF JOIN PASS: scenario=%s committed_handoff=%d retained_pins=0 restored_authority=0", scenario, rows)
				return
			}
			stageReached(t, stages["handoff"])
			var pins retainedHandoffPins
			select {
			case pins = <-pinsReceived:
			default:
				t.Fatal("independent supervisor did not retain acknowledged pins")
			}
			assertHandoffRows(t, f, original, pins)
			before, e := api.Get(context.Background(), original.Name, metav1.GetOptions{})
			if e != nil || before.ResourceVersion != original.ResourceVersion || before.Annotations[capabilityBarrier] != "" || traffic.barriers.Load() != 0 {
				t.Fatal("handoff created a barrier")
			}
			killJoinedSource(t, source)
			stages["handoff"].allow()
			reader := f.launch(handoffReadEnv(t, pins), filepath.Join(*bundle, "modules"), 10, true)
			want := handoffExpected(t, original, pins)
			raw, e := json.Marshal(want)
			if e != nil {
				t.Fatal(e)
			}
			digest := sha256.Sum256(raw)
			if !strings.Contains(reader.log.String(), "NAKAMA HANDOFF PROBE PASS: scenario=read observation_sha256="+hex.EncodeToString(digest[:])) {
				t.Fatal("fresh packaged reader lost complete original observation")
			}
			assertHandoffRows(t, f, original, pins)
			if scenario == "held-put" {
				held.allow()
				select {
				case code := <-status:
					if code != 200 {
						t.Fatalf("unfenced original PUT status %d", code)
					}
				case <-time.After(5 * time.Second):
					t.Fatal("held original write did not settle")
				}
				after, e := api.Get(context.Background(), original.Name, metav1.GetOptions{})
				if e != nil || after.UID != original.UID || after.ResourceVersion == original.ResourceVersion || after.Status.State != agonesv1.GameServerStateAllocated || after.Annotations[capabilityBarrier] != "" || traffic.allocations.Load() != 1 || traffic.barriers.Load() != 0 {
					t.Fatal("handoff-only positive control did not allocate")
				}
				t.Log("HANDOFF JOIN PASS: scenario=held-put fresh_process_read=1 original_put_http=200 barrier_puts=0 restored_authority=0")
			} else {
				if traffic.allocations.Load() != 0 || traffic.barriers.Load() != 0 {
					t.Fatal("late unexposed registration acquired authority")
				}
				reader.stop(t)
				// Independent pins stay fixed through refused rows. Restore the disposable
				// row between controls; no expected version is obtained from replacement.
				var originalValue, rootValue string
				if f.db.QueryRowContext(t.Context(), "SELECT value::text FROM storage WHERE collection=$1", allocatoradmission.HandoffCollection).Scan(&originalValue) != nil || f.db.QueryRowContext(t.Context(), "SELECT value::text FROM storage WHERE collection=$1", allocatoradmission.Collection).Scan(&rootValue) != nil {
					t.Fatal("private fixture unavailable")
				}
				for _, fault := range []string{"stale-handoff", "changed-root", "omitted-inventory", "public-handoff", "missing-handoff"} {
					switch fault {
					case "stale-handoff":
						_, e = f.db.ExecContext(t.Context(), "UPDATE storage SET version='changed' WHERE collection=$1", allocatoradmission.HandoffCollection)
					case "changed-root":
						_, e = f.db.ExecContext(t.Context(), "UPDATE storage SET version='changed' WHERE collection=$1", allocatoradmission.Collection)
					case "omitted-inventory":
						_, e = f.db.ExecContext(t.Context(), "UPDATE storage SET value=jsonb_set(value,'{admission,journal,grants}','[]'::jsonb) WHERE collection=$1", allocatoradmission.HandoffCollection)
					case "public-handoff":
						_, e = f.db.ExecContext(t.Context(), "UPDATE storage SET read=1 WHERE collection=$1", allocatoradmission.HandoffCollection)
					case "missing-handoff":
						_, e = f.db.ExecContext(t.Context(), "DELETE FROM storage WHERE collection=$1", allocatoradmission.HandoffCollection)
					}
					if e != nil {
						t.Fatal("disposable refusal control failed")
					}
					rejected := f.launch(handoffReadEnv(t, pins), filepath.Join(*bundle, "modules"), 10, false)
					assertHandoffRefused(t, rejected)
					if fault != "missing-handoff" {
						if _, e = f.db.ExecContext(t.Context(), "UPDATE storage SET value=$1::text::jsonb,version=$2,read=0 WHERE collection=$3", originalValue, pins.Version, allocatoradmission.HandoffCollection); e != nil {
							t.Fatal(e)
						}
					}
					if _, e = f.db.ExecContext(t.Context(), "UPDATE storage SET value=$1::text::jsonb,version=$2 WHERE collection=$3", rootValue, pins.Binding.Version, allocatoradmission.Collection); e != nil {
						t.Fatal(e)
					}
				}
				if traffic.allocations.Load() != 0 || traffic.barriers.Load() != 0 {
					t.Fatal("refused readback acquired mutation authority")
				}
				t.Log("HANDOFF JOIN PASS: scenario=late-ack registered_unexposed=1 fresh_process_read=1 changed_reads_refused=5 barrier_puts=0")
			}
		})
	}
}
