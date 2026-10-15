//go:build !war_native_trial

package nakamatrial

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// A prerequisite's spent budget cannot be renewed by the subsequent health wait.
func TestStartupHealthSharesTheOriginalContext(t *testing.T) {
	for _, name := range []string{"ready", "expired-before-health", "expires-in-health", "exits-in-health", "never-ready"} {
		t.Run(name, func(t *testing.T) {
			budget := 2 * time.Second
			if name == "never-ready" {
				budget = 25 * time.Millisecond
			}
			ctx, cancel := context.WithTimeout(t.Context(), budget)
			defer cancel()
			done := make(chan struct{})
			if name == "expired-before-health" {
				cancel()
			}
			calls := 0
			got := awaitNativeStartupCondition(ctx, done, func(request context.Context) bool {
				calls++
				if request != ctx {
					t.Fatal("health received a replacement startup window")
				}
				switch name {
				case "expires-in-health":
					cancel()
				case "exits-in-health":
					close(done)
				}
				return name != "never-ready"
			})
			want := "startup-deadline"
			switch name {
			case "ready":
				want = "ready"
			case "exits-in-health":
				want = "process-exited"
			}
			if got != want || (name == "expired-before-health" && calls != 0) || (name != "expired-before-health" && calls == 0) {
				t.Fatalf("startup condition=%s calls=%d, want %s", got, calls, want)
			}
		})
	}
}

// Wait must drain the real child's captured output before it is classified.
func TestStartupEvidenceJoinedChild(t *testing.T) {
	var captured bytes.Buffer
	// The executable and complete script are fixed; no input chooses either.
	command := exec.CommandContext(t.Context(), "/bin/sh", "-c", `printf '%s\n' '{"level":"info","msg":"child starting","private":"never-publish"}' '{"level":"fatal","msg":"Error returned by InitModule function in Go module","error":"issued claims WorkloadAPI request refused","path":"never-publish"}'; exit 1`)
	command.Stdout, command.Stderr = &captured, &captured
	err := command.Run()
	var exited *exec.ExitError
	if !errors.As(err, &exited) || exited.ExitCode() != 1 {
		t.Fatal("the owned child did not produce the expected joined failure")
	}
	if got := observeNativeStartup("process-exited", captured.String()).publicText(); got != "condition=process-exited class=issued-workload-api-refused snapshot=none" {
		t.Fatalf("unexpected joined public observation: %s", got)
	}
}

// Classification consumes private records but returns only fixed public values.
func TestStartupEvidenceRequiresAnExactFatalRecord(t *testing.T) {
	const refusal = `{"level":"fatal","msg":"Error returned by InitModule function in Go module","error":"issued claims WorkloadAPI request refused","path":"private-sentinel"}`
	for _, test := range []struct {
		name, log, class string
	}{
		{"workload-api", refusal, "issued-workload-api-refused"},
		{"ordinary-message", strings.Replace(refusal, `"fatal"`, `"info"`, 1), "unclassified"},
		{"other-fatal", strings.Replace(refusal, "Error returned by InitModule function in Go module", "unknown private-sentinel", 1), "unclassified"},
		{"unknown-error", strings.Replace(refusal, "issued claims WorkloadAPI request refused", "private-sentinel", 1), "module-init-other"},
		{"substring-is-not-proof", strings.Replace(refusal, "issued claims WorkloadAPI request refused", "private-sentinel issued claims WorkloadAPI request refused", 1), "module-init-other"},
		{"two-fatals", refusal + "\n" + refusal, "unclassified"},
		{"malformed", refusal + "\nprivate-sentinel", "unclassified"},
		{"duplicate-key", strings.Replace(refusal, `"level":"fatal"`, `"level":"info","level":"fatal"`, 1), "unclassified"},
		{"trailing-data", refusal + `{}`, "unclassified"},
		{"oversized-record", refusal + strings.Repeat(" ", 65536), "unclassified"},
		{"empty", "", "unclassified"},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := observeNativeStartup("process-exited", test.log)
			wantSnapshot := "none"
			if test.name == "malformed" || test.name == "duplicate-key" || test.name == "trailing-data" || test.name == "oversized-record" {
				wantSnapshot = "unclassified"
			}
			if got.Class != test.class || got.Condition != "process-exited" || got.Snapshot != wantSnapshot {
				t.Fatalf("unexpected bounded classification: %+v", got)
			}
			data, err := json.Marshal(got)
			if err != nil || strings.Contains(string(data), "private-sentinel") {
				t.Fatal("private record escaped the fixed diagnostic")
			}
		})
	}
}

// Every supported refusal retains its fixed class across the worker JSON seam.
func TestStartupEvidenceRefusalsRoundTripWithoutPrivateFields(t *testing.T) {
	for _, test := range []struct{ reason, class string }{
		{"issued claims credential selection refused", "issued-selection-refused"},
		{"issued claims identity refused", "issued-identity-refused"},
		{"issued claims trust bundle refused", "issued-bundle-refused"},
		{"issued claims SDK construction refused", "issued-sdk-refused"},
		{"issued claims SDK cleanup unknown", "issued-cleanup-unknown"},
	} {
		data, err := json.Marshal(map[string]string{"level": "fatal", "msg": "Error returned by InitModule function in Go module", "error": test.reason, "private": "never-publish"})
		if err != nil {
			t.Fatal(err)
		}
		observation := observeNativeStartup("process-exited", string(data))
		wire, err := json.Marshal(observation)
		if err != nil || strings.Contains(string(wire), "never-publish") {
			t.Fatal("private value escaped worker observation")
		}
		var decoded nativeStartupObservation
		if json.Unmarshal(wire, &decoded) != nil || decoded.Class != test.class || decoded.publicText() != "condition=process-exited class="+test.class+" snapshot=none" {
			t.Fatal("bounded refusal did not survive worker protocol")
		}
	}
}

// A decoded worker cannot inject arbitrary text into the controller's report.
func TestStartupEvidenceReportAllowlistsEveryField(t *testing.T) {
	got := nativeStartupObservation{Condition: "private-condition", Class: "private-class", Snapshot: "private-snapshot"}.publicText()
	if got != "condition=unclassified class=unclassified snapshot=unclassified" {
		t.Fatalf("unexpected public diagnostic: %q", got)
	}
	for _, test := range []struct{ log, want string }{
		{`{"level":"info","msg":"ISSUED CLAIMS SNAPSHOT FETCHED"}`, "one"},
		{`{"level":"info","msg":"ISSUED CLAIMS SNAPSHOT FETCHED"}` + "\n" + `{"level":"info","msg":"ISSUED CLAIMS SNAPSHOT FETCHED"}`, "multiple"},
		{`{"level":"info","msg":"private ISSUED CLAIMS SNAPSHOT FETCHED"}`, "none"},
	} {
		got := observeNativeStartup("startup-deadline", test.log)
		if got.Snapshot != test.want {
			t.Fatalf("snapshot observation = %q, want %q", got.Snapshot, test.want)
		}
	}
}
