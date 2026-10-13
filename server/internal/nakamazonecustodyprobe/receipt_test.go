//go:build war_native_trial

package nakamazonecustodyprobe

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/zonecustody"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
	"github.com/heroiclabs/nakama-common/runtime"
)

// controlInputs deliberately removes the diagnostic receipt: the new mode must
// consume only the one separately delivered response after enrollment acceptance.
func controlInputs(t *testing.T, scenario, control string) (map[string]string, zoneclaim.Receipt) {
	t.Helper()
	var original input
	if json.Unmarshal([]byte(inputs(t)), &original) != nil {
		t.Fatal("diagnostic test baseline unavailable")
	}
	raw, err := json.Marshal(map[string]any{"Binding": original.Binding, "Observer": original.Receipt.Observer, "OwnerID": original.OwnerID, "ChildIncarnation": original.ChildIncarnation})
	if err != nil {
		t.Fatal(err)
	}
	env := enabled(t, scenario, control)
	env["WAR_ZONE_CUSTODY_PROBE_INPUT"] = string(raw)
	env["WAR_ZONE_CUSTODY_PROBE_RECEIPT_SOURCE"] = "control"
	return env, original.Receipt
}

// Cancellation after the response request arrives must retain enrollment while
// refusing custody, even when the server can later supply a complete receipt.
func TestCanceledForwardingNeverAcceptsLaterReceipt(t *testing.T) {
	s := nakamastoragetest.New()
	arrived, release := make(chan struct{}), make(chan struct{})
	allow := sync.OnceFunc(func() { close(release) })
	_, original := controlInputs(t, "complete", "")
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/receipt" {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		calls.Add(1)
		close(arrived)
		<-release
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(original)
	}))
	t.Cleanup(server.Close)
	t.Cleanup(allow)
	env, _ := controlInputs(t, "complete", server.URL)
	ctx, cancel := context.WithCancel(context.WithValue(t.Context(), runtime.RUNTIME_CTX_ENV, env))
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Run(ctx, s, func(Report) { t.Error("canceled forwarding reported success") }) }()
	select {
	case <-arrived:
	case <-time.After(5 * time.Second):
		t.Fatal("receipt request never reached control")
	}
	cancel()
	select {
	case err := <-done:
		if err == nil || calls.Load() != 1 || len(s.Objects()) != 1 || len(s.WrittenValues()) != 1 || s.ReadCalls != 0 {
			t.Fatal("canceled original receipt accepted custody or retried")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("canceled original response did not join")
	}
	allow()
}

// Unknown source modes and ambiguous control inputs must refuse before the
// original create. A supplied diagnostic receipt is never a control fallback.
func TestOriginalReceiptInputRefusesBeforeEnrollment(t *testing.T) {
	for _, change := range []string{"source", "diagnostic-fallback", "duplicate-observer", "null-observer", "zero-observer", "missing-observer", "duplicate-binding", "unknown-binding"} {
		t.Run(change, func(t *testing.T) {
			s := nakamastoragetest.New()
			env, _ := controlInputs(t, "complete", "http://127.0.0.1:1")
			raw := env["WAR_ZONE_CUSTODY_PROBE_INPUT"]
			switch change {
			case "source":
				env["WAR_ZONE_CUSTODY_PROBE_RECEIPT_SOURCE"] = "storage"
			case "diagnostic-fallback":
				raw = inputs(t)
			case "duplicate-observer":
				raw = strings.Replace(raw, "{", `{"Observer":7,`, 1)
			case "null-observer":
				raw = strings.Replace(raw, `"Observer":7`, `"Observer":null`, 1)
			case "zero-observer":
				raw = strings.Replace(raw, `"Observer":7`, `"Observer":0`, 1)
			case "missing-observer":
				raw = strings.Replace(raw, `"Observer":7,`, "", 1)
			case "duplicate-binding":
				raw = strings.Replace(raw, `"Binding":{`, `"Binding":{"Namespace":"trial",`, 1)
			case "unknown-binding":
				raw = strings.Replace(raw, `"Binding":{`, `"Binding":{"Other":1,`, 1)
			}
			env["WAR_ZONE_CUSTODY_PROBE_INPUT"] = raw
			if run(t, env, s, func(Report) { t.Error("ambiguous control input ran") }) == nil || len(s.Objects()) != 0 || len(s.WrittenValues()) != 0 || s.ReadCalls != 0 {
				t.Fatal("ambiguous control configuration reached enrollment")
			}
		})
	}
}

// Ignoring the new receipt source, using a diagnostic fallback or fetching before
// the originating enrollment ACK must break the real owner/custody effects here.
func TestForwardedReceiptReachesOriginalEnrollment(t *testing.T) {
	s := nakamastoragetest.New()
	var enrolled atomic.Bool
	var calls, posts atomic.Int32
	var got zonecustody.Pins
	_, original := controlInputs(t, "complete", "")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/owner-a-enrolled":
			enrolled.Store(true)
		case "/receipt":
			calls.Add(1)
			if !enrolled.Load() || len(s.Objects()) != 1 || r.Method != http.MethodGet {
				t.Error("receipt fetch preceded accepted enrollment")
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(original)
			return
		case "/pins":
			posts.Add(1)
			if json.NewDecoder(r.Body).Decode(&got) != nil {
				t.Error("complete pins not delivered")
			}
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	env, _ := controlInputs(t, "copied", server.URL)
	var report Report
	if err := run(t, env, s, func(r Report) { report = r }); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 || posts.Load() != 1 || !report.Pins || report.Writes != 2 || !got.Receipt.Equal(original) || got.EnrollmentVersion != "v1" || got.CustodyVersion != "v2" || len(s.Objects()) != 2 || s.ReadCalls != 0 {
		t.Fatal("forwarded original receipt was lost, reconstructed or retried")
	}
}

// A plausible partial response must never turn its successful prefix into an
// accepted receipt. Each fault keeps exactly enrollment and no custody/pins.
func TestForwardedReceiptRefusesIncompleteOrAmbiguousReplies(t *testing.T) {
	_, original := controlInputs(t, "complete", "")
	encoded, err := json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	raw := string(encoded)
	faults := map[string]string{
		"empty": "", "trailing": raw + " {}", "null": "null", "unknown": strings.Replace(raw, "{", `{"Other":1,`, 1),
		"duplicate":        strings.Replace(raw, "{", `{"Observer":7,`, 1),
		"missing":          strings.Replace(raw, `"Observer":7,`, "", 1),
		"null-field":       strings.Replace(raw, `"Observer":7`, `"Observer":null`, 1),
		"wrong-observer":   strings.Replace(raw, `"Observer":7`, `"Observer":8`, 1),
		"changed-binding":  strings.Replace(raw, `"uid-a"`, `"uid-b"`, 1),
		"nested-duplicate": strings.Replace(raw, `"Fence":{`, `"Fence":{"LeaseVersion":"other",`, 1),
		"nested-unknown":   strings.Replace(raw, `"Fence":{`, `"Fence":{"Other":1,`, 1),
		"oversize":         raw + strings.Repeat(" ", 16385),
	}
	for _, fault := range []string{"redirect", "error-status", "wrong-content-type", "truncated", "canceled"} {
		faults[fault] = raw
	}
	for name, reply := range faults {
		t.Run(name, func(t *testing.T) {
			s := nakamastoragetest.New()
			var calls, pins atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/pins" {
					pins.Add(1)
				}
				if r.URL.Path != "/receipt" {
					w.WriteHeader(http.StatusNoContent)
					return
				}
				calls.Add(1)
				w.Header().Set("Content-Type", "application/json")
				switch name {
				case "redirect":
					w.Header().Set("Location", "/receipt")
					w.WriteHeader(http.StatusTemporaryRedirect)
				case "error-status":
					w.WriteHeader(http.StatusBadGateway)
				case "wrong-content-type":
					w.Header().Set("Content-Type", "text/plain")
				case "truncated":
					w.Header().Set("Content-Length", fmt.Sprint(len(reply)+1))
				case "canceled":
					conn, _, err := w.(http.Hijacker).Hijack()
					if err == nil {
						_ = conn.Close()
					}
					return
				}
				_, _ = w.Write([]byte(reply))
			}))
			defer server.Close()
			env, _ := controlInputs(t, "complete", server.URL)
			if run(t, env, s, func(Report) { t.Error("ambiguous receipt reported success") }) == nil || calls.Load() != 1 || pins.Load() != 0 || len(s.Objects()) != 1 || len(s.WrittenValues()) != 1 || s.ReadCalls != 0 {
				t.Fatal("incomplete reply accepted custody, read back or retried")
			}
		})
	}
}
