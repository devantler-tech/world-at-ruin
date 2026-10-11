//go:build war_native_trial

package nakamatrial

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/zonecustody"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
)

const custodyPass = "NAKAMA ZONE CUSTODY PROBE PASS:"

// These are explicit diagnostic inputs, never a native claim response or an
// issuer-attested owner. Only storage ACK versions originate from this trial.
func custodyInput() (agones.ClaimBinding, zoneclaim.Receipt) {
	b := agones.ClaimBinding{Namespace: "trial", LeaseObjectID: strings.Repeat("a", 64), AttemptDigest: strings.Repeat("a", 52), AllocationID: "zone-a", GameServerUID: "uid-a"}
	r := zoneclaim.Receipt{Namespace: "trial", Observer: 7, Fence: nakamalease.SessionFence{LeaseObjectID: b.LeaseObjectID, AttemptDigest: b.AttemptDigest, AllocationID: b.AllocationID, GameServerUID: b.GameServerUID, LeaseVersion: "diagnostic-version", Generation: time.Unix(123, 456).UTC()}}
	return b, r
}
func custodyEnv(t *testing.T, scenario, owner, child, control string) map[string]string {
	t.Helper()
	b, r := custodyInput()
	raw, err := json.Marshal(struct {
		Binding                   agones.ClaimBinding
		Receipt                   zoneclaim.Receipt
		OwnerID, ChildIncarnation string
	}{b, r, owner, child})
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{"WAR_ZONE_CUSTODY_PROBE_ENABLED": "true", "WAR_ZONE_CUSTODY_PROBE_SCENARIO": scenario, "WAR_ZONE_CUSTODY_PROBE_INPUT": string(raw), "WAR_ZONE_CUSTODY_PROBE_CONTROL": control}
}
func custodyReadEnv(t *testing.T, pins zonecustody.Pins) map[string]string {
	t.Helper()
	raw, err := json.Marshal(pins)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{"WAR_ZONE_CUSTODY_PROBE_ENABLED": "true", "WAR_ZONE_CUSTODY_PROBE_SCENARIO": "read", "WAR_ZONE_CUSTODY_PROBE_PINS": string(raw)}
}
func custodyRefused(t *testing.T, p *nativeProcess, reason string) {
	t.Helper()
	select {
	case <-p.done:
	case <-time.After(20 * time.Second):
		p.stop(t)
		t.Fatal("custody refusal did not join")
	}
	var exit *exec.ExitError
	if !errors.As(p.err, &exit) || exit.ExitCode() != 1 || !strings.Contains(p.log.String(), "zone custody probe: "+reason) || strings.Contains(p.log.String(), custodyPass) {
		t.Fatalf("specific custody refusal missing: %s", p.log.String())
	}
}

type custodyRow struct {
	Value, Version, Owner string
	Read, Write           int
}

func custodyRows(t *testing.T, f *fixture, enrollment, custody int) map[string]custodyRow {
	t.Helper()
	b, r := custodyInput()
	result := map[string]custodyRow{}
	for collection, want := range map[string]int{zonecustody.EnrollmentCollection: enrollment, zonecustody.CustodyCollection: custody} {
		var count int
		if f.db.QueryRowContext(t.Context(), "SELECT count(*) FROM storage WHERE collection=$1 AND user_id=$2::uuid", collection, zeroOwner).Scan(&count) != nil || count != want {
			t.Fatal("native custody row count changed", collection, count, want)
		}
		if want == 0 {
			continue
		}
		var row custodyRow
		if f.db.QueryRowContext(t.Context(), "SELECT value::text,version,user_id::text,read,write FROM storage WHERE collection=$1 AND key=$2 AND user_id=$3::uuid", collection, zonecustody.LifetimeKey(b), zeroOwner).Scan(&row.Value, &row.Version, &row.Owner, &row.Read, &row.Write) != nil || row.Version == "" || row.Version == "*" || row.Owner != zeroOwner || row.Read != 0 || row.Write != 0 {
			t.Fatal("native custody row identity/permissions changed")
		}
		if collection == zonecustody.EnrollmentCollection {
			o, err := zonecustody.DecodeEnrollment(row.Value)
			if err != nil || o.Lifetime != (zonecustody.Lifetime{Namespace: "trial", LeaseObjectID: strings.Repeat("a", 64), AttemptDigest: strings.Repeat("a", 52), AllocationID: "zone-a", GameServerUID: "uid-a"}) || (o.OwnerID != "a" && o.OwnerID != "b") || (o.ChildIncarnation != "child-a" && o.ChildIncarnation != "child-b") {
				t.Fatal("native enrollment lost original lifetime/correlation")
			}
		} else {
			p, err := zonecustody.DecodeCustody(row.Value)
			if err != nil || !p.Receipt.Equal(r) {
				t.Fatal("native custody changed complete diagnostic receipt")
			}
		}
		result[collection] = row
	}
	if allocations, requests := f.counts(); allocations != 0 || requests != 0 {
		t.Fatal("custody persistence issued provider side effects")
	}
	return result
}

// A source ACK and supervisor-retained pins are distinct from visible committed
// rows. Every HTTP stage runs around real StorageWrite, never a storage fake.
func custodyControl(t *testing.T, hold string) (*httptest.Server, *capabilityStage, chan zonecustody.Pins) {
	t.Helper()
	stage := newStage()
	pins := make(chan zonecustody.Pins, 2)
	server := httptest.NewServer(custodyControlHandler(map[string]*capabilityStage{"/" + hold: stage}, pins))
	t.Cleanup(server.Close)
	t.Cleanup(stage.allow)
	return server, stage, pins
}

func custodyControlHandler(stages map[string]*capabilityStage, pins chan zonecustody.Pins) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/pins" {
			var p zonecustody.Pins
			d := json.NewDecoder(io.LimitReader(r.Body, 16385))
			d.DisallowUnknownFields()
			if r.Method != http.MethodPost || d.Decode(&p) != nil || d.Decode(&struct{}{}) != io.EOF {
				w.WriteHeader(400)
				return
			}
			select {
			case pins <- p:
				w.WriteHeader(204)
			default:
				w.WriteHeader(409)
			}
			return
		}
		if r.Method != http.MethodGet {
			w.WriteHeader(405)
			return
		}
		if stage := stages[r.URL.Path]; stage != nil {
			stage.arrival.Do(func() { close(stage.entered) })
			select {
			case <-stage.release:
			case <-r.Context().Done():
				return
			case <-time.After(10 * time.Second):
				w.WriteHeader(504)
				return
			}
		}
		w.WriteHeader(204)
	})
}

func TestNativeZoneCustodyDefaultOff(t *testing.T) {
	for _, flag := range []string{"", "false", "TRUE"} {
		t.Run("flag="+flag, func(t *testing.T) {
			f := newFixture(t)
			p := f.launch(map[string]string{"WAR_ZONE_CUSTODY_PROBE_ENABLED": flag, "WAR_ZONE_CUSTODY_PROBE_INPUT": "invalid", "WAR_ZONE_CUSTODY_PROBE_CONTROL": "invalid"}, filepath.Join(*bundle, "modules"), 10, flag != "TRUE")
			if flag == "TRUE" {
				custodyRefused(t, p, "invalid enablement")
			} else if strings.Contains(p.log.String(), custodyPass) {
				t.Fatal("disabled custody probe ran")
			}
			custodyRows(t, f, 0, 0)
		})
	}
}

// Removing latch consumption or accepting a post-commit lost reply changes
// exported pins or immutable rows; SQL only observes effects, never seeds pins.
func TestNativeZoneCustodyPersistence(t *testing.T) {
	for _, scenario := range []string{"complete", "copied", "lost-enrollment-ack", "cancel-enrollment-ack", "lost-custody-ack", "cancel-custody-ack"} {
		t.Run(scenario, func(t *testing.T) {
			f := newFixture(t)
			control, _, delivered := custodyControl(t, "")
			p := f.launch(custodyEnv(t, scenario, "a", "child-a", control.URL), filepath.Join(*bundle, "modules"), 10, true)
			complete := scenario == "complete" || scenario == "copied"
			writes, custody := 2, 1
			if strings.Contains(scenario, "enrollment") {
				writes, custody = 1, 0
			}
			if !strings.Contains(p.log.String(), custodyPass+" scenario="+scenario+" writes="+strconv.Itoa(writes)+" pins="+strconv.FormatBool(complete)) {
				t.Fatal("native custody scenario did not execute")
			}
			rows := custodyRows(t, f, 1, custody)
			if scenario == "complete" {
				custodyPublicIsolation(t, f, rows)
			}
			if complete {
				pins := <-delivered
				if pins.EnrollmentVersion != rows[zonecustody.EnrollmentCollection].Version || pins.CustodyVersion != rows[zonecustody.CustodyCollection].Version {
					t.Fatal("originating ACKs do not match actual versions")
				}
				killJoinedSource(t, p)
				reader := f.launch(custodyReadEnv(t, pins), filepath.Join(*bundle, "modules"), 10, true)
				if !strings.Contains(reader.log.String(), custodyPass+" scenario=read writes=0 pins=true") {
					t.Fatal("fresh diagnostic reader missing")
				}
				reader.stop(t)
			} else {
				if len(delivered) != 0 {
					t.Fatal("uncertain storage exported pins")
				}
				killJoinedSource(t, p)
			}
			for _, owner := range []string{"a", "b"} {
				restarted := f.launch(custodyEnv(t, "complete", owner, "child-b", control.URL), filepath.Join(*bundle, "modules"), 10, false)
				custodyRefused(t, restarted, "enrollment unknown")
				if !equalCustodyRows(rows, custodyRows(t, f, 1, custody)) {
					t.Fatal("restart changed original rows")
				}
			}
			t.Logf("CUSTODY PERSISTENCE PASS scenario=%s enrollment=1 custody=%d pins=%t restarts_refused=2 provider_effects=0", scenario, custody, complete)
		})
	}
}

// A player can create a same-key row under their own identity, but cannot read
// or change either system-owned document through native public storage APIs.
func custodyPublicIsolation(t *testing.T, f *fixture, original map[string]custodyRow) {
	t.Helper()
	token, uid := f.account("custody-public-isolation")
	b, _ := custodyInput()
	for _, collection := range []string{zonecustody.EnrollmentCollection, zonecustody.CustodyCollection} {
		// The native public API rejects an explicit nil UUID. An omitted
		// owner selects system-owned storage and reaches its permission filter.
		code, data := f.request("POST", "/v2/storage", token, fmt.Sprintf(`{"object_ids":[{"collection":"%s","key":"%s"}]}`, collection, zonecustody.LifetimeKey(b)))
		var response struct {
			Objects []json.RawMessage `json:"objects"`
		}
		if code != 200 || json.Unmarshal(data, &response) != nil || len(response.Objects) != 0 {
			t.Fatal("native public read exposed original custody")
		}
		code, _ = f.request("PUT", "/v2/storage", token, fmt.Sprintf(`{"objects":[{"collection":"%s","key":"%s","value":"{}"}]}`, collection, zonecustody.LifetimeKey(b)))
		if code != 200 {
			t.Fatal("native isolated player write failed")
		}
		code, data = f.request("POST", "/v2/storage", token, fmt.Sprintf(`{"object_ids":[{"collection":"%s","key":"%s","user_id":"%s"}]}`, collection, zonecustody.LifetimeKey(b), uid))
		var positive struct {
			Objects []struct {
				Collection, Key, Value string
				UserID                 string `json:"user_id"`
			} `json:"objects"`
		}
		if code != 200 || json.Unmarshal(data, &positive) != nil || len(positive.Objects) != 1 {
			t.Fatal("native player-owned read control missing")
		}
		object := positive.Objects[0]
		if object.Collection != collection || object.Key != zonecustody.LifetimeKey(b) || object.UserID != uid || object.Value != "{}" {
			t.Fatal("native read control selected another storage identity")
		}
	}
	if !equalCustodyRows(original, custodyRows(t, f, 1, 1)) {
		t.Fatal("public storage changed original system-owned custody")
	}
}

// Two independent live native processes reach the same immutable create key
// before either reply. A second owner or child must never get a second ACK.
func TestNativeZoneCustodyCompetingProcesses(t *testing.T) {
	f := newFixture(t)
	a, b := newStage(), newStage()
	pins := make(chan zonecustody.Pins, 2)
	control := httptest.NewServer(custodyControlHandler(map[string]*capabilityStage{"/a-before-enrollment": a, "/b-before-enrollment": b}, pins))
	t.Cleanup(control.Close)
	t.Cleanup(a.allow)
	t.Cleanup(b.allow)
	source := f.start(custodyEnv(t, "complete", "a", "child-a", control.URL), filepath.Join(*bundle, "modules"), 10)
	stageReached(t, a)
	peer := startRecoveryPeer(t, f, custodyEnv(t, "complete", "b", "child-b", control.URL))
	stageReached(t, b)
	custodyRows(t, f, 0, 0)
	a.allow()
	b.allow()
	var retained zonecustody.Pins
	select {
	case retained = <-pins:
	case <-time.After(20 * time.Second):
		t.Fatal("native race had no acknowledged custody winner")
	}
	winner, loser := source, peer
	if retained.Enrollment.OwnerID == "b" {
		winner, loser = peer, source
	}
	custodyRefused(t, loser, "enrollment unknown")
	// The originating winner reaches health after complete independent delivery.
	port := "7350"
	if winner == peer {
		port = "7360"
	}
	awaitNativeProbeReady(t, winner, port, custodyPass+" scenario=complete writes=2 pins=true")
	if len(pins) != 0 {
		t.Fatal("native race produced multiple winners or no healthy winner")
	}
	rows := custodyRows(t, f, 1, 1)
	if retained.EnrollmentVersion != rows[zonecustody.EnrollmentCollection].Version || retained.CustodyVersion != rows[zonecustody.CustodyCollection].Version {
		t.Fatal("race ACK versions differ from committed original")
	}
	// Stop both exact owned children before occupying the original reader port.
	winner.stop(t)
	loser.stop(t)
	reader := f.launch(custodyReadEnv(t, retained), filepath.Join(*bundle, "modules"), 10, true)
	if !strings.Contains(reader.log.String(), custodyPass+" scenario=read writes=0 pins=true") || !equalCustodyRows(rows, custodyRows(t, f, 1, 1)) {
		t.Fatal("race readback mutated original custody")
	}
	t.Log("CUSTODY PROCESS RACE PASS independent_writers=2 acknowledged_winner=1 private_rows=2 reader_writes=0 provider_effects=0")
}

// A complete reader must examine both original records. Each fault changes
// actual PostgreSQL state after acknowledged pins were retained independently.
func TestNativeZoneCustodyReaderRefusals(t *testing.T) {
	for _, fault := range []string{"missing-enrollment", "missing-custody", "enrollment-version", "custody-version", "public-enrollment", "public-custody", "changed-owner", "changed-receipt", "supplied-version"} {
		t.Run(fault, func(t *testing.T) {
			f := newFixture(t)
			control, _, delivered := custodyControl(t, "")
			source := f.launch(custodyEnv(t, "complete", "a", "child-a", control.URL), filepath.Join(*bundle, "modules"), 10, true)
			pins := <-delivered
			before := custodyRows(t, f, 1, 1)
			killJoinedSource(t, source)
			collection := zonecustody.EnrollmentCollection
			if strings.Contains(fault, "custody") || fault == "changed-receipt" {
				collection = zonecustody.CustodyCollection
			}
			statement := ""
			switch fault {
			case "missing-enrollment", "missing-custody":
				statement = "DELETE FROM storage WHERE collection=$1"
			case "enrollment-version", "custody-version":
				statement = "UPDATE storage SET version='changed-version' WHERE collection=$1"
			case "public-enrollment", "public-custody":
				statement = "UPDATE storage SET read=2 WHERE collection=$1"
			case "changed-owner":
				statement = "UPDATE storage SET value=jsonb_set(value,'{owner_id}','\"b\"') WHERE collection=$1"
			case "changed-receipt":
				statement = "UPDATE storage SET value=jsonb_set(value,'{receipt,Fence,LeaseVersion}','\"changed-version\"') WHERE collection=$1"
			case "supplied-version":
				pins.CustodyVersion = "changed-version"
			}
			if statement != "" {
				result, err := f.db.ExecContext(t.Context(), statement, collection)
				if err != nil {
					t.Fatal(err)
				}
				if n, err := result.RowsAffected(); err != nil || n != 1 {
					t.Fatal("native reader fault not applied exactly once")
				}
			}
			// Snapshot all storage before both refusals; neither reader may
			// repair, refresh or replace an observed faulty document.
			var snapshot, again string
			query := "SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY collection,key)::text,'[]') FROM storage s"
			if f.db.QueryRowContext(t.Context(), query).Scan(&snapshot) != nil {
				t.Fatal("fault snapshot unavailable")
			}
			reader := f.launch(custodyReadEnv(t, pins), filepath.Join(*bundle, "modules"), 10, false)
			custodyRefused(t, reader, "pinned readback unknown")
			second := f.launch(custodyReadEnv(t, pins), filepath.Join(*bundle, "modules"), 10, false)
			custodyRefused(t, second, "pinned readback unknown")
			if f.db.QueryRowContext(t.Context(), query).Scan(&again) != nil || snapshot != again {
				t.Fatal("refused reader changed storage")
			}
			if len(before) != 2 {
				t.Fatal("original native complete positive missing")
			}
			if allocations, requests := f.counts(); allocations != 0 || requests != 0 {
				t.Fatal("reader issued provider effects")
			}
			t.Logf("CUSTODY READ REFUSAL PASS fault=%s specific_refusals=2 reader_writes=0 provider_effects=0", fault)
		})
	}
}

func equalCustodyRows(a, b map[string]custodyRow) bool {
	if len(a) != len(b) {
		return false
	}
	for key, value := range a {
		if other, ok := b[key]; !ok || value != other {
			return false
		}
	}
	return true
}

// Killing/joining the exact source does not erase its committed lifetime key.
// Neither restart may adopt a handle from independently visible database rows.
func TestNativeZoneCustodyCrashCuts(t *testing.T) {
	for _, cut := range []struct {
		stage               string
		enrollment, custody int
	}{
		{"before-enrollment", 0, 0}, {"enrollment-written", 1, 0}, {"enrolled", 1, 0},
		{"before-custody", 1, 0}, {"custody-written", 1, 1}, {"custodied", 1, 1},
	} {
		t.Run(cut.stage, func(t *testing.T) {
			f := newFixture(t)
			control, stage, delivered := custodyControl(t, "a-"+cut.stage)
			source := f.start(custodyEnv(t, "complete", "a", "child-a", control.URL), filepath.Join(*bundle, "modules"), 10)
			stageReached(t, stage)
			before := custodyRows(t, f, cut.enrollment, cut.custody)
			if len(delivered) != 0 || strings.Contains(source.log.String(), custodyPass) {
				t.Fatal("pending crash seam exported pins")
			}
			killJoinedSource(t, source)
			stage.allow()
			reader := f.launch(custodyReadEnv(t, zonecustody.Pins{}), filepath.Join(*bundle, "modules"), 10, false)
			custodyRefused(t, reader, "pinned readback unknown")
			if cut.enrollment != 0 {
				for _, owner := range []string{"a", "b"} {
					p := f.launch(custodyEnv(t, "complete", owner, "child-b", control.URL), filepath.Join(*bundle, "modules"), 10, false)
					custodyRefused(t, p, "enrollment unknown")
				}
				if !equalCustodyRows(before, custodyRows(t, f, cut.enrollment, cut.custody)) {
					t.Fatal("post-crash restart refreshed rows")
				}
			} else {
				p := f.launch(custodyEnv(t, "complete", "b", "child-b", control.URL), filepath.Join(*bundle, "modules"), 10, true)
				if !strings.Contains(p.log.String(), custodyPass) {
					t.Fatal("unsubmitted enrollment falsely established database exclusion")
				}
				custodyRows(t, f, 1, 1)
			}
			t.Logf("CUSTODY CRASH PASS cut=%s exact_source_joined=true enrollment=%d custody=%d original_pins=0", cut.stage, cut.enrollment, cut.custody)
		})
	}
}
