package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A corrupt vendor report must not turn unchecked links into a successful gate.
func TestValidatorReportsFailClosed(t *testing.T) {
	valid := `{"total":1,"unique":1,"successful":1,"errors":0,"unknown":0,"timeouts":0,"excludes":0,"error_map":{},"success_map":{"README.md":[{"url":"https://example.com/","status":{"text":"200 OK","code":200}}]},"timeout_map":{},"excluded_map":{},"detailed_stats":true}`
	for _, test := range []struct {
		name, body string
		wantError  bool
	}{
		{"complete success", valid, false},
		{"missing fields", `{}`, true},
		{"malformed", `not-json`, true},
		{"unchecked link", strings.Replace(valid, `"successful":1`, `"successful":0`, 1), true},
		{"negative counts", strings.Replace(valid, `"total":1`, `"total":-1`, 1), true},
		{"empty success map", strings.Replace(valid, `"README.md":[{"url":"https://example.com/","status":{"text":"200 OK","code":200}}]`, ``, 1), true},
		{"hidden failure", strings.Replace(valid, `"error_map":{}`, `"error_map":{"README.md":[{"url":"https://example.com/missing","status":{"text":"404 Not Found","code":404}}]}`, 1), true},
		{"unknown observation", strings.Replace(valid, `"unknown":0`, `"unknown":1`, 1), true},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			// Only the vendor report boundary is replaced. The adapter's command,
			// decoding and readiness decision are real production code.
			if err := os.WriteFile(filepath.Join(dir, "lychee"), []byte("#!/bin/sh\ncat <<'REPORT'\n"+test.body+"\nREPORT\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
			if _, err := check(nil, []string{"README.md"}); (err != nil) != test.wantError {
				t.Fatalf("report accepted=%t, want=%t: %v", err == nil, !test.wantError, err)
			}
		})
	}
}

func TestMissingValidatorFailsClosed(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	if _, err := check(nil, []string{"README.md"}); err == nil {
		t.Fatal("unavailable validator was accepted")
	}
}

// Dump mode can return zero while warning that extraction skipped an input.
func TestExtractionWarningFailsClosed(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "lychee"), []byte("#!/bin/sh\nprintf '%s\\n' 'https://example.com/'\nprintf '%s\\n' 'WARN: skipped a broken input' >&2\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if _, err := extract(nil, []string{"README.md"}); err == nil {
		t.Fatal("incomplete extraction was accepted")
	}
}

func TestRetrySuccessMustNameRequestedURL(t *testing.T) {
	for _, target := range []string{"https://example.com/", "https://example.com/different"} {
		t.Run(target, func(t *testing.T) {
			dir := t.TempDir()
			config := filepath.Join(dir, "lychee.toml")
			if err := os.WriteFile(config, []byte("max_retries = 1\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			first := `{"total":1,"unique":1,"successful":0,"errors":1,"unknown":0,"timeouts":0,"excludes":0,"error_map":{"links.md":[{"url":"https://example.com/","status":{"text":"503 Service Unavailable","code":503}}]},"success_map":{},"timeout_map":{},"excluded_map":{},"detailed_stats":true}`
			second := `{"total":1,"unique":1,"successful":1,"errors":0,"unknown":0,"timeouts":0,"excludes":0,"error_map":{},"success_map":{"links.md":[{"url":"` + target + `","status":{"text":"200 OK","code":200}}]},"timeout_map":{},"excluded_map":{},"detailed_stats":true}`
			marker := filepath.Join(dir, "first-pass")
			script := "#!/bin/sh\ncase \" $* \" in *' --dump '*) printf '%s\\n' 'https://example.com/'; exit 0;; esac\nif [ -f '" + marker + "' ]; then\ncat <<'REPORT'\n" + second + "\nREPORT\nelse\ntouch '" + marker + "'\ncat <<'REPORT'\n" + first + "\nREPORT\nexit 2\nfi\n"
			if err := os.WriteFile(filepath.Join(dir, "lychee"), []byte(script), 0o700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
			err := run([]string{"--config", config, "--format", "detailed", "links.md"})
			if (err == nil) != (target == "https://example.com/") {
				t.Fatalf("retry accepted=%t for %s: %v", err == nil, target, err)
			}
		})
	}
}
