//go:build !war_native_trial

package nakamatrial

import (
	"context"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// A readiness line cannot substitute for successful SDK cleanup and process join.
func TestIssuedReadinessPrerequisiteRequiresCleanJoinedChild(t *testing.T) {
	for _, test := range []struct {
		name, output string
		accepted     bool
	}{
		{"complete", issuedReadinessMarker, true},
		{"delayed", issuedReadinessMarker, true},
		{"missing", "", false},
		{"wrong", "unrelated-role-ready", false},
		{"partial", issuedReadinessMarker, false},
		{"duplicate", issuedReadinessMarker, false},
		{"failed-after-ready", issuedReadinessMarker, false},
		{"stderr-is-not-ready", issuedReadinessMarker, false},
		{"oversized", strings.Repeat("x", 65536) + issuedReadinessMarker, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
			defer cancel()
			err := awaitIssuedReadinessProcess(ctx, func(request context.Context) *exec.Cmd {
				// Every executable and shell program is fixed in source; test
				// values are stdin data, never command text or arguments.
				var command *exec.Cmd
				switch test.name {
				case "complete":
					command = exec.CommandContext(request, "/bin/sh", "-c", `/bin/cat; printf '\nPASS\n'`)
				case "delayed":
					command = exec.CommandContext(request, "/bin/sh", "-c", `/bin/sleep 0.01; /bin/cat; printf '\n'`)
				case "missing":
					command = exec.CommandContext(request, "/usr/bin/printf", "PASS\n")
				case "wrong", "oversized":
					command = exec.CommandContext(request, "/bin/sh", "-c", `/bin/cat; printf '\n'`)
				case "partial":
					command = exec.CommandContext(request, "/bin/cat")
				case "duplicate":
					command = exec.CommandContext(request, "/bin/sh", "-c", `value=$(/bin/cat); printf '%s\n%s\n' "$value" "$value"`)
				case "failed-after-ready":
					command = exec.CommandContext(request, "/bin/sh", "-c", `/bin/cat; printf '\n'; printf 'private-sentinel\n' >&2; exit 1`)
				case "stderr-is-not-ready":
					command = exec.CommandContext(request, "/bin/sh", "-c", `/bin/cat >&2; printf '\n' >&2`)
				default:
					t.Fatal("unknown owned readiness control")
					return nil
				}
				command.Stdin = strings.NewReader(test.output)
				return command
			})
			if (err == nil) != test.accepted {
				t.Fatalf("readiness accepted=%t, want %t", err == nil, test.accepted)
			}
			if err != nil && strings.Contains(err.Error(), "private-sentinel") {
				t.Fatal("private helper output escaped the fixed failure")
			}
		})
	}
}

// Even a complete readiness line is refused while its process remains alive.
func TestIssuedReadinessPrerequisiteDoesNotRenewStartupBudget(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
	defer cancel()
	started := time.Now()
	err := awaitIssuedReadinessProcess(ctx, func(request context.Context) *exec.Cmd {
		return exec.CommandContext(request, "/bin/sh", "-c", `printf '%s\n' "$1"; exec /bin/sleep 60`, "owned-readiness-control", issuedReadinessMarker)
	})
	if err == nil || ctx.Err() == nil || time.Since(started) > 2*time.Second {
		t.Fatal("unjoined readiness producer escaped the original startup bound")
	}
	err = awaitIssuedReadinessProcess(ctx, func(request context.Context) *exec.Cmd {
		return exec.CommandContext(request, "/bin/sh", "-c", `printf '%s\n' "$1"`, "owned-readiness-control", issuedReadinessMarker)
	})
	if err == nil {
		t.Fatal("an expired startup window admitted another prerequisite")
	}
}
