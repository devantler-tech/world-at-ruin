//go:build linux

// Package spire supplies disposable issuer bootstrap for native test fixtures.
// It owns no process handle, runtime credential, or production authority.
package spire

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Entry is caller-owned fixture registration policy, never recovered authority.
type Entry struct {
	ID  string
	UID uint32
	DNS string
}

// Issuer exposes only a public socket/bundle and the private-state refusal path.
type Issuer struct{ API, Bundle, Private string }

// Program selects one of the caller's pinned fixture executables.
type Program uint8

const (
	Server Program = iota
	Agent
)

// Launch must register the started process with the caller's stop/join owner
// before returning. Its observer reports a completed Wait, without losing that
// owner's knowledge that the process has been joined.
type Launch func(Program, string) (exited func() bool)

// Runner keeps executable selection and private CLI execution with the caller.
type Runner struct {
	Launch Launch
	Admin  func(context.Context, ...string) ([]byte, error)
}

// Start creates a fresh Server/Agent pair under the caller's owned scratch root.
// Socket readiness is transport evidence only; each workload must fetch its own
// exact SVID. The caller retains its existing process and whole-fixture deadline.
func Start(t *testing.T, ctx context.Context, directory, name string, port int, entries []Entry, runner Runner) Issuer {
	t.Helper()
	private := filepath.Join(directory, name+"-private")
	public := filepath.Join(directory, name+"-public")
	for _, d := range []struct {
		path string
		mode os.FileMode
	}{{private, 0700}, {public, 0755}, {filepath.Join(private, "server"), 0700}, {filepath.Join(private, "agent"), 0700}} {
		if err := os.Mkdir(d.path, d.mode); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path, body string, mode os.FileMode) {
		t.Helper()
		if err := os.WriteFile(path, []byte(body), mode); err != nil {
			t.Fatal(err)
		}
	}
	cli := func(args ...string) []byte {
		t.Helper()
		request, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		data, err := runner.Admin(request, args...)
		if err != nil {
			t.Fatal("private SPIRE administrative operation failed")
		}
		return data
	}
	socket := filepath.Join(private, "server", "api.sock")
	serverConf := filepath.Join(private, "server.conf")
	write(serverConf, fmt.Sprintf(`server {
 bind_address="127.0.0.1"
 bind_port=%d
 socket_path=%q
 trust_domain="war-fixture.test"
 data_dir=%q
 log_level="ERROR"
 experimental { cache_reload_interval="1s" }
}
plugins {
 DataStore "sql" { plugin_data { database_type="sqlite3" connection_string=%q } }
 NodeAttestor "join_token" { plugin_data {} }
 KeyManager "memory" { plugin_data {} }
}
`, port, socket, filepath.Join(private, "server"), filepath.Join(private, "server", "store.sqlite3")), 0600)
	serverExited := runner.Launch(Server, serverConf)
	readyCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	for {
		if serverExited() {
			t.Fatal("SPIRE server exited before readiness")
		}
		attempt, stop := context.WithTimeout(readyCtx, time.Second)
		_, err := runner.Admin(attempt, "healthcheck", "-socketPath", socket)
		stop()
		if err == nil {
			break
		}
		select {
		case <-readyCtx.Done():
			t.Fatal("bounded SPIRE server startup failed")
		case <-time.After(100 * time.Millisecond):
		}
	}
	bundle := filepath.Join(public, "bundle.pem")
	write(bundle, string(cli("bundle", "show", "-socketPath", socket, "-format", "pem")), 0644)
	tokenData := cli("token", "generate", "-socketPath", socket, "-ttl", "60", "-output", "json")
	var token struct {
		Value   string `json:"value"`
		Expires string `json:"expires_at"`
	}
	if json.Unmarshal(tokenData, &token) != nil || token.Value == "" {
		t.Fatal("missing private bootstrap token")
	}
	expires, err := strconv.ParseInt(token.Expires, 10, 64)
	if err != nil || expires <= time.Now().Unix() || len(token.Value) < 16 || strings.ContainsAny(token.Value, " \r\n\t/") {
		t.Fatal("invalid private bootstrap token")
	}
	tokenFile := filepath.Join(private, "join-token")
	write(tokenFile, token.Value, 0600)
	for _, entry := range entries {
		args := []string{"entry", "create", "-socketPath", socket, "-parentID", "spiffe://war-fixture.test/spire/agent/join_token/" + token.Value, "-spiffeID", entry.ID, "-selector", fmt.Sprintf("unix:uid:%d", entry.UID), "-x509SVIDTTL", "300"}
		if entry.DNS != "" {
			args = append(args, "-dns", entry.DNS)
		}
		_ = cli(args...)
	}
	api := filepath.Join(public, "api.sock")
	agentConf := filepath.Join(private, "agent.conf")
	write(agentConf, fmt.Sprintf(`agent {
 data_dir=%q
 server_address="127.0.0.1"
 server_port=%d
 socket_path=%q
 trust_bundle_path=%q
 trust_domain="war-fixture.test"
 join_token_file=%q
 disable_sds_api=true
 log_level="ERROR"
 experimental { sync_interval="1s" }
}
plugins {
 NodeAttestor "join_token" { plugin_data {} }
 KeyManager "disk" { plugin_data { directory=%q } }
 WorkloadAttestor "unix" { plugin_data { discover_workload_path=false } }
}
`, filepath.Join(private, "agent"), port, api, bundle, tokenFile, filepath.Join(private, "agent")), 0600)
	agentExited := runner.Launch(Agent, agentConf)
	for {
		if info, err := os.Stat(api); err == nil && info.Mode()&os.ModeSocket != 0 {
			break
		}
		if agentExited() {
			t.Fatal("SPIRE agent exited before Workload API readiness")
		}
		select {
		case <-readyCtx.Done():
			t.Fatal("bounded SPIRE Workload API startup failed")
		case <-time.After(100 * time.Millisecond):
		}
	}
	return Issuer{API: api, Bundle: bundle, Private: private}
}
