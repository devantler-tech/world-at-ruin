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
			checkLink(t, page, 429, 4, http.StatusOK, []int{429, 429, 429, 429, 200}, true)
		})
	}
}

// A retry policy must never make a permanently missing page acceptable.
func TestDeadLinkStillFails(t *testing.T) {
	t.Parallel()
	checkLink(t, "missing.html", 404, 0, http.StatusNotFound, []int{404}, false)
}

// A host that never recovers must exhaust the budget and remain a failed link.
func TestPersistentRateLimitStillFails(t *testing.T) {
	t.Parallel()
	checkLink(t, "limited.html", 429, 0, http.StatusTooManyRequests, []int{429, 429, 429, 429, 429, 429}, false)
}

// Temporary server errors must use the retry budget rather than fail after one request.
func TestLinksRecoverAfterServerError(t *testing.T) {
	t.Parallel()
	for _, status := range []int{503, 504} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			t.Parallel()
			checkLink(t, fmt.Sprintf("temporary-%d.html", status), status, 2, http.StatusOK, []int{status, status, 200}, true)
		})
	}
}

// Retrying must never turn a permanent server error into a successful link.
func TestPersistentServerErrorStillFails(t *testing.T) {
	t.Parallel()
	for _, status := range []int{503, 504} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			t.Parallel()
			checkLink(t, fmt.Sprintf("persistent-%d.html", status), status, 0, status, []int{status, status, status, status, status, status}, false)
		})
	}
}

// A 429 followed by a server error must not start a second retry budget.
func TestRateLimitThenServerErrorSharesBudget(t *testing.T) {
	t.Parallel()
	checkLink(t, "mixed-status.html", 429, 2, 503, []int{429, 429, 503, 503, 503, 503}, false)
}

func TestHealthyLinkPassesWithoutRetry(t *testing.T) {
	t.Parallel()
	checkLink(t, "healthy.html", 200, 0, http.StatusOK, []int{200}, true)
}

// Duplicate citations share one budget; healthy and dead links are never rechecked.
func TestMixedDocumentsRetryOnlyAffectedLinks(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	counts := map[string]int{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		counts[r.URL.Path]++
		status := 200
		switch r.URL.Path {
		case "/persistent":
			status = 503
		case "/missing":
			status = 404
		}
		w.WriteHeader(status)
	}))
	defer server.Close()
	dir := t.TempDir()
	first, second := filepath.Join(dir, "first.md"), filepath.Join(dir, "second.md")
	if err := os.WriteFile(first, []byte(fmt.Sprintf("[Persistent](%s/persistent)\n[Healthy](%s/healthy)\n[Missing](%s/missing)\n", server.URL, server.URL, server.URL)), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, []byte(fmt.Sprintf("[Same persistent page](%s/persistent)\n", server.URL)), 0o600); err != nil {
		t.Fatal(err)
	}
	validator := os.Getenv("LYCHEE_VALIDATOR")
	if validator == "" {
		validator = "lychee"
	}
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, validator, "--config", filepath.Join(root, "lychee.toml"), "--format", "detailed", "--no-progress", "--", first, second)
	cmd.Dir = root
	output, commandErr := cmd.CombinedOutput()
	if ctx.Err() != nil || commandErr == nil {
		t.Fatalf("permanent failures must fail within the deadline: %v\n%s", commandErr, output)
	}
	mu.Lock()
	defer mu.Unlock()
	if !reflect.DeepEqual(counts, map[string]int{"/persistent": 6, "/healthy": 1, "/missing": 1}) {
		t.Errorf("requests = %v, want one shared six-request budget and one request per other URL\n%s", counts, output)
	}
	t.Logf("mixed document requests: %v", counts)
}

// checkLink verifies the production policy against a controlled HTTP response
// sequence and requires both the request trace and lychee's exit status to agree.
func checkLink(t *testing.T, page string, retryStatus, transientAttempts, terminalStatus int, wantStatuses []int, wantSuccess bool) {
	t.Helper()
	validator := os.Getenv("LYCHEE_VALIDATOR")
	if validator == "" {
		validator = "lychee"
	}
	lychee, err := exec.LookPath(validator)
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
		if len(statuses) < transientAttempts {
			status = retryStatus
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
	if !wantSuccess && !strings.Contains(string(output), fmt.Sprintf("[%d]", wantStatuses[len(wantStatuses)-1])) {
		t.Errorf("link failed without the expected HTTP status; another error cannot satisfy this test:\n%s", output)
	}
	t.Logf("%s: HTTP responses %v; lychee success=%t", page, gotStatuses, commandErr == nil)
}
