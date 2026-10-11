//go:build war_spire_trial && linux

package spiretrial

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

type ownedProcess struct {
	cmd    *exec.Cmd
	done   chan error
	joined bool
	log    *os.File
}
type nativeFixture struct {
	t      *testing.T
	ctx    context.Context
	dir    string
	owned  []*ownedProcess
	closed bool
}
type nativeIssuer struct{ api, bundle, private string }
type nativeWorker struct {
	f       *nativeFixture
	process *ownedProcess
	cmd     *exec.Cmd
	input   io.WriteCloser
	output  *json.Decoder
	ready   response
}

func newNativeFixture(t *testing.T, ctx context.Context) *nativeFixture {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "war-spire-")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	f := &nativeFixture{t: t, ctx: ctx, dir: dir}
	t.Cleanup(f.close)
	return f
}
func (f *nativeFixture) write(path, body string, mode os.FileMode) {
	f.t.Helper()
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		f.t.Fatal(err)
	}
}
func (f *nativeFixture) start(cmd *exec.Cmd) *ownedProcess {
	f.t.Helper()
	log, err := os.CreateTemp(f.dir, "process-log-")
	if err != nil {
		f.t.Fatal(err)
	}
	if err = log.Chmod(0600); err != nil {
		_ = log.Close()
		f.t.Fatal(err)
	}
	cmd.Stderr = log
	if cmd.Stdout == nil {
		cmd.Stdout = log
	}
	if err = cmd.Start(); err != nil {
		_ = log.Close()
		f.t.Fatal("owned process failed to start:", filepath.Base(cmd.Path), err)
	}
	p := &ownedProcess{cmd: cmd, done: make(chan error, 1), log: log}
	f.owned = append(f.owned, p)
	go func() { p.done <- cmd.Wait() }()
	return p
}
func (f *nativeFixture) stop(p *ownedProcess) {
	f.t.Helper()
	if p.joined {
		if p.log != nil {
			if err := p.log.Close(); err != nil {
				f.t.Error(err)
			}
			p.log = nil
		}
		return
	}
	select {
	case <-p.done:
		p.joined = true
	default:
		// Only the retained handle returned by this invocation's Cmd.Start.
		if err := p.cmd.Process.Signal(syscall.SIGTERM); err != nil && !errors.Is(err, os.ErrProcessDone) {
			f.t.Error("owned SIGTERM failed:", err)
		}
		timer := time.NewTimer(3 * time.Second)
		select {
		case <-p.done:
			p.joined = true
		case <-timer.C:
			if err := p.cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
				f.t.Error("owned kill failed:", err)
			}
			select {
			case <-p.done:
				p.joined = true
			case <-time.After(5 * time.Second):
				f.t.Error("owned process did not join")
			}
		}
		timer.Stop()
	}
	if p.joined {
		if err := p.log.Close(); err != nil {
			f.t.Error(err)
		}
		p.log = nil
	}
}
func (f *nativeFixture) close() {
	if f.closed {
		return
	}
	f.closed = true
	// Bound retirement for the whole owned set, not eight seconds per child.
	// Each process has exactly one Wait owner and one stop/join consumer.
	var joins sync.WaitGroup
	for _, p := range f.owned {
		joins.Go(func() { f.stop(p) })
	}
	joins.Wait()
	for _, p := range f.owned {
		if !p.joined {
			f.t.Error("retaining state after failed retirement")
			return
		}
	}
	if err := os.RemoveAll(f.dir); err != nil {
		f.t.Error(err)
	}
}
func (f *nativeFixture) cli(args ...string) []byte {
	f.t.Helper()
	ctx, cancel := context.WithTimeout(f.ctx, 5*time.Second)
	defer cancel()
	data, err := runCLI(ctx, args...)
	if err != nil {
		f.t.Fatal("private SPIRE administrative operation failed")
	}
	return data
}
func (f *nativeFixture) startIssuer(name string, port int) nativeIssuer {
	f.t.Helper()
	private := filepath.Join(f.dir, name+"-private")
	public := filepath.Join(f.dir, name+"-public")
	for _, d := range []struct {
		path string
		mode os.FileMode
	}{{private, 0700}, {public, 0755}, {filepath.Join(private, "server"), 0700}, {filepath.Join(private, "agent"), 0700}} {
		if err := os.Mkdir(d.path, d.mode); err != nil {
			f.t.Fatal(err)
		}
	}
	socket := filepath.Join(private, "server", "api.sock")
	serverConf := filepath.Join(private, "server.conf")
	f.write(serverConf, fmt.Sprintf(`server {
 bind_address="127.0.0.1"
 bind_port=%d
 socket_path=%q
 trust_domain="war-fixture.test"
 data_dir=%q
 log_level="ERROR"
}
plugins {
 DataStore "sql" { plugin_data { database_type="sqlite3" connection_string=%q } }
 NodeAttestor "join_token" { plugin_data {} }
 KeyManager "memory" { plugin_data {} }
}
`, port, socket, filepath.Join(private, "server"), filepath.Join(private, "server", "store.sqlite3")), 0600)
	server := f.start(exec.CommandContext(f.ctx, "/opt/spire/bin/spire-server", "run", "-config", serverConf))
	readyCtx, cancel := context.WithTimeout(f.ctx, 30*time.Second)
	defer cancel()
	for {
		select {
		case <-server.done:
			server.joined = true
			f.t.Fatal("SPIRE server exited before readiness")
		default:
		}
		attempt, stop := context.WithTimeout(readyCtx, time.Second)
		_, err := runCLI(attempt, "healthcheck", "-socketPath", socket)
		stop()
		if err == nil {
			break
		}
		select {
		case <-readyCtx.Done():
			f.t.Fatal("bounded SPIRE server startup failed")
		case <-time.After(100 * time.Millisecond):
		}
	}
	bundle := filepath.Join(public, "bundle.pem")
	f.write(bundle, string(f.cli("bundle", "show", "-socketPath", socket, "-format", "pem")), 0644)
	tokenData := f.cli("token", "generate", "-socketPath", socket, "-ttl", "60", "-output", "json")
	var token struct {
		Value   string `json:"value"`
		Expires string `json:"expires_at"`
	}
	if privateJSON(tokenData, &token) != nil || token.Value == "" {
		f.t.Fatal("missing private bootstrap token")
	}
	expires, err := strconv.ParseInt(token.Expires, 10, 64)
	if err != nil || expires <= time.Now().Unix() || len(token.Value) < 16 || strings.ContainsAny(token.Value, " \r\n\t/") {
		f.t.Fatal("invalid private bootstrap token")
	}
	tokenFile := filepath.Join(private, "join-token")
	f.write(tokenFile, token.Value, 0600)
	for _, role := range []string{"supervisor", "custodian", "child"} {
		_ = f.cli("entry", "create", "-socketPath", socket, "-parentID", "spiffe://war-fixture.test/spire/agent/join_token/"+token.Value, "-spiffeID", roleID(role).String(), "-selector", fmt.Sprintf("unix:uid:%d", roleUID(role)), "-x509SVIDTTL", "300")
	}
	api := filepath.Join(public, "api.sock")
	agentConf := filepath.Join(private, "agent.conf")
	f.write(agentConf, fmt.Sprintf(`agent {
 data_dir=%q
 server_address="127.0.0.1"
 server_port=%d
 socket_path=%q
 trust_bundle_path=%q
 trust_domain="war-fixture.test"
 join_token_file=%q
 disable_sds_api=true
 log_level="ERROR"
}
plugins {
 NodeAttestor "join_token" { plugin_data {} }
 KeyManager "disk" { plugin_data { directory=%q } }
 WorkloadAttestor "unix" { plugin_data { discover_workload_path=false } }
}
`, filepath.Join(private, "agent"), port, api, bundle, tokenFile, filepath.Join(private, "agent")), 0600)
	agent := f.start(exec.CommandContext(f.ctx, "/opt/spire/bin/spire-agent", "run", "-config", agentConf))
	for {
		if info, err := os.Stat(api); err == nil && info.Mode()&os.ModeSocket != 0 {
			break
		}
		select {
		case <-agent.done:
			agent.joined = true
			f.t.Fatal("SPIRE agent exited before Workload API readiness")
		case <-readyCtx.Done():
			f.t.Fatal("bounded SPIRE Workload API startup failed")
		case <-time.After(100 * time.Millisecond):
		}
	}
	return nativeIssuer{api: api, bundle: bundle, private: private}
}
func (f *nativeFixture) startWorker(role string, issuer nativeIssuer) *nativeWorker {
	f.t.Helper()
	binary, err := os.Executable()
	if err != nil {
		f.t.Fatal(err)
	}
	cmd := exec.CommandContext(f.ctx, binary, "-war-experimental", "-war-role="+role, "-war-api="+issuer.api, "-war-issuer-state="+issuer.private)
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: roleUID(role), Gid: roleUID(role), Groups: []uint32{}}}
	input, err := cmd.StdinPipe()
	if err != nil {
		f.t.Fatal(err)
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		f.t.Fatal(err)
	}
	w := &nativeWorker{f: f, cmd: cmd, input: input, output: json.NewDecoder(output)}
	w.process = f.start(cmd)
	if role == "unregistered" {
		// Consume the mandatory refusal only after its process has fully exited.
		// The controller must still own the unread stdout bytes after Cmd.Wait.
		select {
		case err := <-w.process.done:
			w.process.joined = true
			var exited *exec.ExitError
			if !errors.As(err, &exited) || exited.ExitCode() != 1 {
				f.t.Fatal("unregistered role did not exit with its refusal")
			}
		case <-time.After(10 * time.Second):
			f.t.Fatal("unregistered role did not exit within its bound")
		}
	}
	w.ready = w.receive()
	if role != "unregistered" && (w.ready.Error != "" || w.ready.ID != roleID(role).String() || w.ready.Address == "") {
		f.t.Fatal("attested worker startup failed:", role, w.ready.Error)
	}
	return w
}
func (w *nativeWorker) receive() response {
	w.f.t.Helper()
	result := make(chan response, 1)
	go func() {
		var r response
		if err := w.output.Decode(&r); err != nil {
			r.Error = "private worker reply failed"
		}
		result <- r
	}()
	select {
	case r := <-result:
		return r
	case <-w.f.ctx.Done():
		w.f.t.Fatal("trial deadline exceeded")
	case <-time.After(10 * time.Second):
		w.f.t.Fatal("bounded worker reply deadline exceeded")
	}
	return response{}
}
func (w *nativeWorker) exchange(c command) response {
	w.f.t.Helper()
	if err := json.NewEncoder(w.input).Encode(c); err != nil {
		w.f.t.Fatal("private worker command failed")
	}
	return w.receive()
}

func statusFields() (map[string]string, error) {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return nil, err
	}
	fields := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		parts := strings.SplitN(line, ":", 2)
		if len(parts) == 2 {
			fields[parts[0]] = strings.TrimSpace(parts[1])
		}
	}
	return fields, nil
}
func verifyController() error {
	fields, err := statusFields()
	if err != nil {
		return err
	}
	if os.Geteuid() != 0 || fields["NoNewPrivs"] != "1" || fields["CapEff"] != "00000000000000e0" || fields["CapPrm"] != "00000000000000e0" || fields["CapInh"] != "0000000000000000" || fields["CapAmb"] != "0000000000000000" {
		return fmt.Errorf("controller requires only SETUID, SETGID, KILL and no-new-privileges")
	}
	return nil
}
