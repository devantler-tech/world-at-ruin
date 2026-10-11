//go:build war_native_trial

package nakamazonecustodyprobe

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/zonecustody"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
	"github.com/heroiclabs/nakama-common/runtime"
)

func inputs(t *testing.T) string {
	t.Helper()
	b := agones.ClaimBinding{Namespace: "trial", LeaseObjectID: strings.Repeat("a", 64), AttemptDigest: strings.Repeat("a", 52), AllocationID: "zone-a", GameServerUID: "uid-a"}
	r := zoneclaim.Receipt{Namespace: "trial", Observer: 7, Fence: nakamalease.SessionFence{LeaseObjectID: b.LeaseObjectID, AttemptDigest: b.AttemptDigest, AllocationID: b.AllocationID, GameServerUID: b.GameServerUID, LeaseVersion: "diagnostic-version", Generation: time.Unix(123, 456).UTC()}}
	raw, err := json.Marshal(struct {
		Binding                   agones.ClaimBinding
		Receipt                   zoneclaim.Receipt
		OwnerID, ChildIncarnation string
	}{b, r, "owner-a", "child-a"})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}
func enabled(t *testing.T, scenario, control string) map[string]string {
	t.Helper()
	return map[string]string{"WAR_ZONE_CUSTODY_PROBE_ENABLED": "true", "WAR_ZONE_CUSTODY_PROBE_SCENARIO": scenario, "WAR_ZONE_CUSTODY_PROBE_INPUT": inputs(t), "WAR_ZONE_CUSTODY_PROBE_CONTROL": control}
}
func run(t *testing.T, env map[string]string, s Storage, report func(Report)) error {
	t.Helper()
	return Run(context.WithValue(t.Context(), runtime.RUNTIME_CTX_ENV, env), s, report)
}

// A vacuous enabled probe cannot report storage acceptance. Both real owner
// writes and the complete retained original receipt must reach its consumer.
func TestEnabledProbeRetainsBothOriginatingStorageACKs(t *testing.T) {
	s := nakamastoragetest.New()
	var delivered zonecustody.Pins
	var posts atomic.Int32
	control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/pins" {
			if r.Method != http.MethodPost || json.NewDecoder(r.Body).Decode(&delivered) != nil {
				w.WriteHeader(400)
				return
			}
			posts.Add(1)
		}
		w.WriteHeader(204)
	}))
	defer control.Close()
	var got Report
	if err := run(t, enabled(t, "complete", control.URL), s, func(r Report) { got = r }); err != nil {
		t.Fatal(err)
	}
	if got.Scenario != "complete" || got.Writes != 2 || !got.Pins || posts.Load() != 1 || delivered.EnrollmentVersion != "v1" || delivered.CustodyVersion != "v2" || delivered.Receipt.Fence.LeaseVersion != "diagnostic-version" || len(s.Objects()) != 2 {
		t.Fatal("enabled probe failed to retain complete originating storage ACKs")
	}
}

func TestDisabledProbeNeverInspectsInputs(t *testing.T) {
	for _, flag := range []string{"", "false"} {
		if err := run(t, map[string]string{"WAR_ZONE_CUSTODY_PROBE_ENABLED": flag, "WAR_ZONE_CUSTODY_PROBE_INPUT": "invalid"}, nil, nil); err != nil {
			t.Fatal(err)
		}
	}
}

// Widening enablement, input or control scope must fail before storage effects.
func TestMalformedEnablementNeverWrites(t *testing.T) {
	for _, change := range []string{"flag", "scenario", "input", "unknown-field", "trailing", "oversize", "foreign-control", "nil-storage", "nil-report"} {
		t.Run(change, func(t *testing.T) {
			env := enabled(t, "complete", "http://127.0.0.1:1")
			s := nakamastoragetest.New()
			var storage Storage = s
			report := func(Report) { t.Fatal("invalid probe reported acceptance") }
			switch change {
			case "flag":
				env["WAR_ZONE_CUSTODY_PROBE_ENABLED"] = "TRUE"
			case "scenario":
				env["WAR_ZONE_CUSTODY_PROBE_SCENARIO"] = "resume"
			case "input":
				env["WAR_ZONE_CUSTODY_PROBE_INPUT"] = "{}"
			case "unknown-field":
				env["WAR_ZONE_CUSTODY_PROBE_INPUT"] = strings.Replace(inputs(t), "{", "{\"foreign\":1,", 1)
			case "trailing":
				env["WAR_ZONE_CUSTODY_PROBE_INPUT"] += " {}"
			case "oversize":
				env["WAR_ZONE_CUSTODY_PROBE_INPUT"] += strings.Repeat(" ", 16385)
			case "foreign-control":
				env["WAR_ZONE_CUSTODY_PROBE_CONTROL"] = "http://example.com:1"
			case "nil-storage":
				storage = nil
			case "nil-report":
				report = nil
			}
			if run(t, env, storage, report) == nil || len(s.WrittenValues()) != 0 || s.ReadCalls != 0 {
				t.Fatal("invalid experiment dispatched")
			}
		})
	}
}

// Post-commit reply faults must leave the persisted effects while withholding
// detached pins. Retries through copied handles may not dispatch more writes.
func TestCommittedReplyFaultsNeverDeliverPins(t *testing.T) {
	for _, scenario := range []string{"lost-enrollment-ack", "cancel-enrollment-ack", "lost-custody-ack", "cancel-custody-ack", "copied"} {
		t.Run(scenario, func(t *testing.T) {
			s := nakamastoragetest.New()
			var posts atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/pins" {
					posts.Add(1)
				}
				w.WriteHeader(204)
			}))
			defer server.Close()
			var got Report
			if err := run(t, enabled(t, scenario, server.URL), s, func(r Report) { got = r }); err != nil {
				t.Fatal(err)
			}
			want := int32(2)
			if strings.Contains(scenario, "enrollment") {
				want = 1
			}
			complete := scenario == "copied"
			if got.Writes != want || got.Pins != complete || len(s.Objects()) != int(want) || len(s.WrittenValues()) != int(want) || (posts.Load() == 1) != complete {
				t.Fatal("ambiguous reply retried or exported pins")
			}
		})
	}
}

// A redirect/error is an unavailable supervisor, never an accepted stage.
func TestControlTransportRefusesRedirectsAndErrors(t *testing.T) {
	var targetCalls atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { targetCalls.Add(1); w.WriteHeader(204) }))
	defer target.Close()
	for _, status := range []int{307, 500} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Location", target.URL)
			w.WriteHeader(status)
		}))
		s := nakamastoragetest.New()
		if run(t, enabled(t, "complete", server.URL), s, func(Report) { t.Fatal("refused supervisor reported success") }) == nil || len(s.Objects()) != 0 {
			t.Fatal("refused stage submitted enrollment")
		}
		server.Close()
	}
	if targetCalls.Load() != 0 {
		t.Fatal("control transport followed redirect")
	}
	for _, value := range []string{"http://localhost:12", "https://127.0.0.1:12", "http://user@127.0.0.1:12", "http://127.0.0.1:12/path", "http://127.0.0.1:12?next=other", "http://127.0.0.1:12#other"} {
		if localEndpoint(value) {
			t.Fatal("non-fixture endpoint accepted", value)
		}
	}
}
