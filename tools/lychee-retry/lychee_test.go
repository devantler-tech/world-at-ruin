// These tests run the same lychee executable and configuration as MegaLinter.
// Only the upstream HTTP responses are controlled; no request goes to Godot.
package lycheeretry_test

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// Losing the additional retry budget must turn a recoverable rate limit into a
// failing link. Accepting 429 or excluding Godot must also fail the request trace.
func TestGodotLinksRecoverAfterRateLimit(t *testing.T) {
	t.Parallel()
	for _, page := range []string{"class_crypto.html", "class_cryptokey.html"} {
		t.Run(page, func(t *testing.T) {
			t.Parallel()
			checkLink(t, page, 4, http.StatusOK, []int{429, 429, 429, 429, 200}, true)
		})
	}
}

// A retry policy must never make a permanently missing page acceptable.
func TestDeadLinkStillFails(t *testing.T) {
	t.Parallel()
	checkLink(t, "missing.html", 0, http.StatusNotFound, []int{404}, false)
}

// A host that never recovers must exhaust the budget and remain a failed link.
func TestPersistentRateLimitStillFails(t *testing.T) {
	t.Parallel()
	checkLink(t, "limited.html", 0, http.StatusTooManyRequests, []int{429, 429, 429, 429, 429, 429}, false)
}

func checkLink(t *testing.T, page string, rateLimitedAttempts, terminalStatus int, wantStatuses []int, wantSuccess bool) {
	t.Helper()
	lychee, err := exec.LookPath("lychee")
	if err != nil {
		t.Fatalf("lychee is required: %v", err)
	}
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(root, "lychee.toml")
	if _, err := os.Stat(config); err != nil {
		t.Fatalf("production config is required: %v", err)
	}
	var mu sync.Mutex
	var statuses []int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		status := terminalStatus
		if len(statuses) < rateLimitedAttempts {
			status = http.StatusTooManyRequests
		}
		statuses = append(statuses, status)
		w.Header().Set("Content-Type", "text/html")
		w.WriteHeader(status)
	}))
	t.Cleanup(server.Close)
	url := "https://docs.godotengine.org/en/stable/classes/" + page
	input := filepath.Join(t.TempDir(), "links.md")
	if err := os.WriteFile(input, []byte(fmt.Sprintf("[Godot documentation](%s)\n", url)), 0o600); err != nil {
		t.Fatal(err)
	}
	// Remapping happens before exclusions. Prove that the original Godot URL is
	// still checked before remapping it, or a Godot exclusion could pass against
	// localhost while silently removing the real documentation from lint.
	dumpCtx, dumpCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer dumpCancel()
	dump := exec.CommandContext(dumpCtx, lychee, "--dump", "--config", config, "--", input)
	dump.Dir = root
	links, err := dump.CombinedOutput()
	if err != nil {
		t.Fatalf("extract links with production policy: %v\n%s", err, links)
	}
	if !strings.Contains(string(links), url) {
		t.Fatalf("production policy excluded the Godot URL before any HTTP check: %s\n%s", url, links)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, lychee,
		"--format", "detailed", "--no-progress", "--timeout", "45",
		"--config", config, "--remap", "^"+regexp.QuoteMeta(url)+"$ "+server.URL+"/"+page,
		"--", input)
	cmd.Dir = root
	output, commandErr := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("link check exceeded its regression deadline: %v\n%s", ctx.Err(), output)
	}
	mu.Lock()
	gotStatuses := append([]int(nil), statuses...)
	mu.Unlock()
	if !reflect.DeepEqual(gotStatuses, wantStatuses) {
		t.Errorf("HTTP responses observed by lychee = %v, want %v\n%s", gotStatuses, wantStatuses, output)
	}
	if (commandErr == nil) != wantSuccess {
		t.Errorf("link check success = %t, want %t (error: %v)\n%s", commandErr == nil, wantSuccess, commandErr, output)
	}
	if !wantSuccess && !strings.Contains(string(output), fmt.Sprintf("[%d]", wantStatuses[0])) {
		t.Errorf("link failed without the expected HTTP status; another error cannot satisfy this test:\n%s", output)
	}
	t.Logf("%s: HTTP responses %v; lychee success=%t", page, gotStatuses, commandErr == nil)
}
