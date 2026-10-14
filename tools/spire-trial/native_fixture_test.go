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
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/testfixture/spire"
)

type ownedProcess struct {
	cmd    *exec.Cmd
	done   chan error
	joined bool
	log    *os.File
	output *os.File
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

// newControllerFixture preserves the same controller profile and proof deadline
// for each independent native acceptance case, including cleanup on early failure.
func newControllerFixture(t *testing.T) *nativeFixture {
	t.Helper()
	if err := verifyController(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	f := newNativeFixture(t, ctx)
	t.Cleanup(cancel)
	return f
}

// newNativeFixture owns one scratch tree and registers retirement before launch.
// Its traversable root contains separate private issuer state and public sockets.
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

// start retains only a process this fixture actually started, with one Wait
// owner and a private log that never reaches public CI diagnostics.
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

// stop signals the retained owned handle and bounds TERM, KILL and exact join.
// Joined processes release their private log and explicitly owned stdout reader.
func (f *nativeFixture) stop(p *ownedProcess) {
	f.t.Helper()
	if p.joined {
		if p.log != nil {
			if err := p.log.Close(); err != nil {
				f.t.Error(err)
			}
			p.log = nil
		}
		if p.output != nil {
			if err := p.output.Close(); err != nil {
				f.t.Error(err)
			}
			p.output = nil
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
		if p.output != nil {
			if err := p.output.Close(); err != nil {
				f.t.Error(err)
			}
			p.output = nil
		}
	}
}

// close retires the entire owned set concurrently before removing private state.
// Failed join retains that state and fails the experiment rather than claiming cleanup.
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

// startIssuer starts a fresh real Server/Agent pair with private bootstrap
// state, UID registrations and bounded transport readiness. Role readiness still
// requires each worker's own exact SVID fetch.
func (f *nativeFixture) startIssuer(name string, port int) nativeIssuer {
	f.t.Helper()
	var entries []spire.Entry
	for _, role := range []string{"supervisor", "custodian", "child", "zone", "wrong-zone", "claims", "URI-only-claims", "wrong-claims"} {
		entry := spire.Entry{ID: roleID(role).String(), UID: roleUID(role)}
		if role == "claims" || role == "wrong-claims" {
			entry.DNS = claimsFixtureDNS
		}
		entries = append(entries, entry)
	}
	issuer := spire.Start(f.t, f.ctx, f.dir, name, port, entries, func(cmd *exec.Cmd) func() bool {
		p := f.start(cmd)
		return func() bool {
			select {
			case <-p.done:
				p.joined = true
			default:
			}
			return p.joined
		}
	})
	return nativeIssuer{api: issuer.API, bundle: issuer.Bundle, private: issuer.Private}
}

// startWorker changes to a distinct unprivileged UID/GID before exec and retains
// its private response pipe independently of process reaping. The unregistered
// control must preserve its actual refusal even when decoded after joined exit.
func (f *nativeFixture) startWorker(role string, issuer nativeIssuer) *nativeWorker {
	f.t.Helper()
	binary, err := os.Executable()
	if err != nil {
		f.t.Fatal(err)
	}
	cmd := exec.CommandContext(f.ctx, binary, "-war-experimental", "-war-role", role, "-war-api", issuer.api, "-war-issuer-state", issuer.private)
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: roleUID(role), Gid: roleUID(role), Groups: []uint32{}}}
	input, err := cmd.StdinPipe()
	if err != nil {
		f.t.Fatal(err)
	}
	output, childOutput, err := os.Pipe()
	if err != nil {
		f.t.Fatal(err)
	}
	started := false
	defer func() {
		if err := childOutput.Close(); err != nil && !errors.Is(err, os.ErrClosed) {
			f.t.Error(err)
		}
		if !started {
			if err := output.Close(); err != nil {
				f.t.Error(err)
			}
		}
	}()
	// Cmd.Wait must not close the controller's unread response bytes. The
	// parent's pipe endpoints have an explicit lifetime independent of Wait.
	cmd.Stdout = childOutput
	w := &nativeWorker{f: f, cmd: cmd, input: input, output: json.NewDecoder(output)}
	w.process = f.start(cmd)
	w.process.output = output
	started = true
	if err := childOutput.Close(); err != nil {
		f.t.Fatal(err)
	}
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
	callerOnly := role == "zone" || role == "wrong-zone"
	if role != "unregistered" && (w.ready.Error != "" || w.ready.ID != roleID(role).String() || (!callerOnly && w.ready.Address == "")) {
		f.t.Fatal("attested worker startup failed:", role, w.ready.Error)
	}
	return w
}

// receive bounds one private reply; owned retirement closes the pipe on a
// deadline failure so the decoder cannot keep the child lifetime alive.
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

// exchange sends one diagnostic instruction over the controller-owned pipe.
// This test protocol carries no private keys or production authority.
func (w *nativeWorker) exchange(c command) response {
	w.f.t.Helper()
	if err := json.NewEncoder(w.input).Encode(c); err != nil {
		w.f.t.Fatal("private worker command failed")
	}
	return w.receive()
}

// statusFields reads actual kernel credentials and capabilities of this process.
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

// verifyController permits only root with SETUID/SETGID/KILL, no inherited or
// ambient capabilities, and enforced no-new-privileges.
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
