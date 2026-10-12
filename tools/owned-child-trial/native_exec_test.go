//go:build war_child_trial && linux

package ownedchild

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// lockedTask retains one actually observed OS thread through its last probe.
type lockedTask struct {
	tid      int
	commands chan func() uint64
	results  chan uint64
	done     chan struct{}
}

// retainTask starts a bounded locked thread; returning destroys the locked M.
// Never unlock a thread whose irreversible filter may differ from its siblings.
func retainTask() (*lockedTask, error) {
	return retainTaskUntil(time.Now().Add(time.Second))
}

// retainTaskUntil shares the future search's deadline rather than adding a wait.
func retainTaskUntil(deadline time.Time) (*lockedTask, error) {
	if !time.Now().Before(deadline) {
		return nil, errors.New("locked-thread startup deadline")
	}
	t := &lockedTask{commands: make(chan func() uint64), results: make(chan uint64, 1), done: make(chan struct{})}
	ready := make(chan int, 1)
	go func() {
		runtime.LockOSThread()
		defer close(t.done)
		ready <- unix.Gettid()
		for command := range t.commands {
			t.results <- command()
		}
	}()
	select {
	case t.tid = <-ready:
		if !time.Now().Before(deadline) {
			return nil, errors.New("locked-thread startup deadline")
		}
		return t, nil
	case <-time.After(time.Until(deadline)):
		return nil, errors.New("locked-thread startup deadline")
	}
}

// call runs one fixed fixture operation on the retained thread, with a deadline.
func (t *lockedTask) call(fn func() uint64) (uint64, error) {
	select {
	case t.commands <- fn:
	case <-time.After(time.Second):
		return 0, errors.New("locked-thread command deadline")
	}
	select {
	case result := <-t.results:
		return result, nil
	case <-time.After(time.Second):
		return 0, errors.New("locked-thread result deadline")
	}
}

// closeTasks acknowledges every retained thread before the owned process exits.
func closeTasks(tasks []*lockedTask) error {
	for _, task := range tasks {
		close(task.commands)
	}
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	for _, task := range tasks {
		select {
		case <-task.done:
		case <-deadline.C:
			return errors.New("locked-thread cleanup deadline")
		}
	}
	return nil
}

// execProbe pre-opens the immutable static ELF and prepares fixed argv/envp.
type execProbe struct {
	fd    int
	path  *byte
	empty *byte
	argv  []*byte
	envp  []*byte
}

// prepareExec fails before any filter if the fixed marker cannot be opened.
func prepareExec() (*execProbe, error) {
	fd, err := unix.Open("/out/owned-child.test", unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	p := &execProbe{fd: fd}
	p.path, err = unix.BytePtrFromString("/out/owned-child.test")
	if err != nil {
		_ = unix.Close(fd)
		return nil, err
	}
	p.empty, err = unix.BytePtrFromString("")
	if err != nil {
		_ = unix.Close(fd)
		return nil, err
	}
	for _, argument := range []string{"/out/owned-child.test", "-war-experimental", "-war-worker=exec:marker"} {
		pointer, pointerErr := unix.BytePtrFromString(argument)
		if pointerErr != nil {
			_ = unix.Close(fd)
			return nil, pointerErr
		}
		p.argv = append(p.argv, pointer)
	}
	p.argv = append(p.argv, nil)
	p.envp = []*byte{nil}
	return p, nil
}

// invoke performs a real same-process exec syscall, never a newly launched child.
// Positive exec destroys this disposable process's other threads. This raw fixture
// is not a general Go exec API or a production exec/clone coordination proof.
func (p *execProbe) invoke(kind string) uint64 {
	var errno syscall.Errno
	if kind == "execve" {
		_, _, errno = unix.RawSyscall(unix.SYS_EXECVE, uintptr(unsafe.Pointer(p.path)), uintptr(unsafe.Pointer(&p.argv[0])), uintptr(unsafe.Pointer(&p.envp[0])))
	} else {
		_, _, errno = unix.RawSyscall6(unix.SYS_EXECVEAT, uintptr(p.fd), uintptr(unsafe.Pointer(p.empty)), uintptr(unsafe.Pointer(&p.argv[0])), uintptr(unsafe.Pointer(&p.envp[0])), unix.AT_EMPTY_PATH, 0)
	}
	runtime.KeepAlive(p)
	return uint64(errno)
}

// futureTask retains a TID absent from both complete installation snapshots.
func futureTask(tasks *[]*lockedTask, before, after []int) (*lockedTask, error) {
	deadline := time.Now().Add(2 * time.Second)
	for range 32 {
		if time.Now().After(deadline) {
			break
		}
		task, err := retainTaskUntil(deadline)
		if err != nil {
			return nil, err
		}
		*tasks = append(*tasks, task)
		if !slices.Contains(before, task.tid) && !slices.Contains(after, task.tid) {
			return task, nil
		}
	}
	return nil, errors.New("no proven future thread within fixed bound")
}

// execWorker runs only fixed native controls inside one launch-owned process.
func execWorker(mode string) (code int) {
	encoder := json.NewEncoder(os.Stdout)
	if mode == "exec:marker" {
		if encoder.Encode(reply{Event: "exec-marker", PID: os.Getpid()}) != nil {
			return 1
		}
		return 0
	}
	parts := strings.Split(mode, ":")
	if len(parts) != 4 || !slices.Contains([]string{"unsealed", "unsynced", "synced", "divergent", "error", "wrong-arch", "x32"}, parts[1]) ||
		!slices.Contains([]string{"existing", "future"}, parts[2]) || !slices.Contains([]string{"execve", "execveat"}, parts[3]) {
		return 2
	}
	status, err := statusEvidence()
	if err != nil || validateIdentity(reply{Status: status}) != nil {
		return 1
	}
	// LockOSThread establishes the Go 1.27.2 template before changing seccomp.
	runtime.LockOSThread()
	probe, err := prepareExec()
	if err != nil {
		return 1
	}
	defer func() { _ = unix.Close(probe.fd) }()
	var tasks []*lockedTask
	defer func() {
		if closeErr := closeTasks(tasks); closeErr != nil {
			code = 1
		}
	}()
	for range 2 {
		task, startErr := retainTask()
		if startErr != nil {
			return 1
		}
		tasks = append(tasks, task)
	}
	before, err := taskIDs()
	if err != nil {
		return 1
	}
	evidence := &sealEvidence{Installer: unix.Gettid(), Existing: []int{tasks[0].tid, tasks[1].tid}, Before: before}
	evidence.BeforeFilters, err = taskFilters(before)
	if err != nil {
		return 1
	}
	filter := execFilter(nativeAuditArch())
	var flags uintptr
	switch parts[1] {
	case "synced", "divergent", "x32":
		flags = unix.SECCOMP_FILTER_FLAG_TSYNC
		evidence.Synchronized = true
	case "error":
		flags = 1 << 31 // Real kernel EINVAL, not a simulated error return.
	}
	if parts[1] == "divergent" {
		evidence.Divergent = tasks[1].tid
		value, callErr := tasks[1].call(func() uint64 {
			result := installFilter([]unix.SockFilter{{Code: unix.BPF_RET | unix.BPF_K, K: unix.SECCOMP_RET_ALLOW}}, 0)
			if result.Value != 0 {
				return ^uint64(0)
			}
			return result.Errno
		})
		if callErr != nil || value != 0 {
			return 1
		}
	}
	if parts[1] == "x32" {
		if runtime.GOARCH != "amd64" {
			return 2
		}
		evidence.X32Before, err = x32Probes(tasks[0])
		if err != nil {
			return 1
		}
	}
	if parts[1] != "unsealed" && parts[1] != "wrong-arch" {
		evidence.Result = installFilter(filter, flags)
	}
	// The success snapshot is taken before starting any future-thread search.
	evidence.After, err = taskIDs()
	if err != nil {
		return 1
	}
	evidence.AfterFilters, err = taskFilters(evidence.After)
	if err != nil {
		return 1
	}
	if parts[1] == "unsynced" {
		// The installer must deny the same valid exec the peer can still run.
		evidence.InstallerProbeErrno = probe.invoke(parts[3])
	}
	target := tasks[0]
	if parts[2] == "future" {
		target, err = futureTask(&tasks, evidence.Before, evidence.After)
		if err != nil {
			return 1
		}
		evidence.Future = target.tid
	}
	evidence.ProbeTID = target.tid
	probeFilters, err := taskFilters([]int{target.tid})
	if err != nil {
		return 1
	}
	evidence.ProbeFilters = probeFilters[target.tid]
	if encoder.Encode(reply{Event: "ready", PID: os.Getpid(), Status: status, Seal: evidence}) != nil {
		return 1
	}
	scanner := bufio.NewScanner(os.Stdin)
	if !scanner.Scan() || scanner.Text() != "probe" {
		return 1
	}
	if parts[1] == "wrong-arch" {
		// A real native syscall with a deliberately wrong architecture policy
		// must kill this owned process; it is not a foreign-ABI execution claim.
		wrong := uint32(unix.AUDIT_ARCH_AARCH64)
		if runtime.GOARCH == "arm64" {
			wrong = unix.AUDIT_ARCH_X86_64
		}
		result := installFilter(execFilter(wrong), unix.SECCOMP_FILTER_FLAG_TSYNC)
		if result != (sealResult{}) {
			return 1
		}
		_, _, _ = unix.RawSyscall(unix.SYS_GETPID, 0, 0, 0)
		return 1
	}
	if parts[1] == "x32" {
		evidence.X32After, err = x32Probes(target)
		if err != nil || encoder.Encode(reply{Event: "probe", PID: os.Getpid(), Seal: evidence}) != nil {
			return 1
		}
		if !scanner.Scan() || scanner.Text() != "exit" {
			return 1
		}
		return 0
	}
	value, err := target.call(func() uint64 { return probe.invoke(parts[3]) })
	if err != nil {
		return 1
	}
	evidence.ProbeErrno = value
	if encoder.Encode(reply{Event: "probe", PID: os.Getpid(), Seal: evidence}) != nil {
		return 1
	}
	// Keep the original process alive until the controller checks the gate.
	if !scanner.Scan() || scanner.Text() != "exit" {
		return 1
	}
	return 0
}

// x32Probes uses the x32 exec numbers, never native exec numbers ORed with a bit.
// Null arguments probe number denial; they do not prove successful x32 execution.
func x32Probes(task *lockedTask) ([]uint64, error) {
	var result []uint64
	for _, number := range []uintptr{0x40000000 | 520, 0x40000000 | 545} {
		value, err := task.call(func() uint64 {
			_, _, errno := unix.RawSyscall6(number, 0, 0, 0, 0, 0, 0)
			return uint64(errno)
		})
		if err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	return result, nil
}

// execReady requires actual retained-thread observations before any probe.
func execReady(t *testing.T, p *owned, policy, target string) *sealEvidence {
	t.Helper()
	if p.boundary.authorize(p.boundary.original, true, p.live) || p.boundary.count() != 0 {
		t.Fatal("pre-seal effect admitted")
	}
	r, err := p.next("ready")
	if err != nil || validateIdentity(r) != nil || r.Seal == nil {
		t.Fatalf("native startup incomplete: %v", err)
	}
	s := r.Seal
	if s.Installer <= 0 || len(s.Existing) != 2 || s.Existing[0] == s.Existing[1] || slices.Contains(s.Existing, s.Installer) {
		t.Fatal("installer and existing threads are not distinct")
	}
	for _, tid := range append(slices.Clone(s.Existing), s.Installer) {
		if !slices.Contains(s.Before, tid) || !slices.Contains(s.After, tid) {
			t.Fatal("retained thread absent from complete snapshots")
		}
	}
	if target == "future" {
		if s.Future <= 0 || s.ProbeTID != s.Future || slices.Contains(s.Before, s.Future) || slices.Contains(s.After, s.Future) {
			t.Fatal("future probe is not a post-installation OS thread")
		}
	} else if s.ProbeTID != s.Existing[0] {
		t.Fatal("existing probe changed OS thread")
	}
	if policy == "synced" {
		if !s.Synchronized || s.Result != (sealResult{}) || !p.boundary.completeSeal(s.Result.Value, s.Result.Errno) {
			t.Fatal("synchronized installation did not return exact success")
		}
		for _, tid := range s.Before {
			if s.BeforeFilters[tid] <= 0 || s.AfterFilters[tid] != s.BeforeFilters[tid]+1 {
				t.Fatal("existing/template thread lost its inherited filter or synchronized addition")
			}
		}
		if s.ProbeFilters != s.BeforeFilters[s.Existing[0]]+1 {
			t.Fatal("probe thread lacks the inherited synchronized filter chain")
		}
	} else {
		switch policy {
		case "unsynced":
			if s.Synchronized || s.Result != (sealResult{}) || s.InstallerProbeErrno != uint64(unix.EPERM) ||
				s.AfterFilters[s.Installer] != s.BeforeFilters[s.Installer]+1 || s.ProbeFilters != s.BeforeFilters[s.Existing[0]] {
				t.Fatal("unsynchronized control lacks installed installer denial and unchanged peer filter")
			}
			for _, tid := range s.Before {
				if tid != s.Installer && s.AfterFilters[tid] != s.BeforeFilters[tid] {
					t.Fatal("unsynchronized control changed a non-installer filter")
				}
			}
			p.boundary.retire()
		case "divergent":
			divergent := s.Divergent
			if divergent <= 0 || !s.Synchronized || s.Result.Errno != 0 || s.Result.Value != uint64(divergent) || divergent != s.Existing[1] {
				t.Fatal("TSYNC did not expose the actual divergent thread ID")
			}
			if p.boundary.completeSeal(s.Result.Value, s.Result.Errno) {
				t.Fatal("positive TSYNC return admitted effects")
			}
		case "error":
			if s.Result.Errno != uint64(unix.EINVAL) || p.boundary.completeSeal(s.Result.Value, s.Result.Errno) {
				t.Fatal("ordinary syscall error accepted")
			}
		default:
			p.boundary.retire() // Non-TSYNC controls grant no seal observation.
		}
		if p.boundary.authorize(p.boundary.original, true, p.live) || p.boundary.count() != 0 || p.boundary.completeSeal(0, 0) {
			t.Fatal("refused or absent seal reopened")
		}
	}
	return s
}

// TestNativeExecSeal proves actual same-process exec on existing and new threads.
func TestNativeExecSeal(t *testing.T) {
	canary := own(t, "canary", "", nil)
	requireReady(t, canary)
	for _, policy := range []string{"unsealed", "unsynced", "synced", "divergent", "error"} {
		for _, target := range []string{"existing", "future"} {
			for _, kind := range []string{"execve", "execveat"} {
				t.Run(policy+"/"+target+"/"+kind, func(t *testing.T) {
					p := own(t, "exec:"+policy+":"+target+":"+kind, "", nil)
					s := execReady(t, p, policy, target)
					if policy == "synced" {
						r := requireReply(t, p, "probe")
						if r.Seal == nil || r.Seal.ProbeErrno != uint64(unix.EPERM) || r.Seal.ProbeTID != s.ProbeTID {
							t.Fatal("sealed exec did not return EPERM on the retained thread")
						}
						if !p.boundary.authorize(p.boundary.original, true, p.live) || p.boundary.count() != 1 {
							t.Fatal("successful sealing did not open the live diagnostic gate")
						}
					} else {
						if _, err := fmt.Fprintln(p.input, "probe"); err != nil {
							t.Fatal(err)
						}
						if _, err := p.next("exec-marker"); err != nil {
							t.Fatalf("positive control did not execute the fixed marker: %v", err)
						}
						select {
						case <-p.waitDone:
						case <-time.After(3 * time.Second):
							t.Fatal("exec marker did not terminate")
						}
						if p.cmd.ProcessState == nil || !p.cmd.ProcessState.Success() || p.boundary.count() != 0 {
							t.Fatal("positive exec control failed or changed diagnostic effects")
						}
					}
					if err := p.stop(); err != nil || !p.joined || !p.closed || p.boundary.authorize(p.boundary.original, true, p.live) {
						t.Fatal("exec control failed exact joined retirement")
					}
				})
			}
		}
	}
	requireReply(t, canary, "ping")
	fmt.Printf("EXEC SEAL NATIVE PASS: %s; both syscalls; existing and proven future threads; synchronized EPERM; unsealed/unsynchronized marker positives; divergent TID and syscall-error refusal; zero pre-seal/refused effects; canary alive\n", runtime.GOARCH)
}

// TestNativeExecSealArchitectureMismatch exercises a real native wrong-policy call.
func TestNativeExecSealArchitectureMismatch(t *testing.T) {
	p := own(t, "exec:wrong-arch:existing:execve", "", nil)
	execReady(t, p, "wrong-arch", "existing")
	if _, err := fmt.Fprintln(p.input, "probe"); err != nil {
		t.Fatal(err)
	}
	select {
	case <-p.waitDone:
	case <-time.After(3 * time.Second):
		t.Fatal("native architecture mismatch did not terminate")
	}
	if p.cmd.ProcessState == nil {
		t.Fatal("architecture mismatch lacks a terminal state")
	}
	status, ok := p.cmd.ProcessState.Sys().(syscall.WaitStatus)
	if !ok || !status.Signaled() || status.Signal() != syscall.SIGSYS || p.boundary.count() != 0 {
		t.Fatal("real architecture-policy mismatch was not SIGSYS with zero effects")
	}
	fmt.Println("ARCHITECTURE CONTROL PASS: real native syscall with wrong policy killed; actual foreign ABI execution remains unproved")
}

// TestNativeExecSealABIReports keeps number-denial evidence separate from ABI execution.
func TestNativeExecSealABIReports(t *testing.T) {
	if runtime.GOARCH == "amd64" {
		p := own(t, "exec:x32:existing:execve", "", nil)
		s := execReady(t, p, "synced", "existing")
		r := requireReply(t, p, "probe")
		if r.Seal == nil || len(s.X32Before) != 2 || len(r.Seal.X32After) != 2 {
			t.Fatal("incomplete x32 number observations")
		}
		for i, errno := range r.Seal.X32After {
			if errno != uint64(unix.EACCES) {
				t.Fatal("added x32 number filter did not deny")
			}
			if s.X32Before[i] == errno {
				fmt.Printf("ABI EVIDENCE: x32 number %d attribution unproved; inherited and added denial identical\n", i)
			} else {
				fmt.Printf("ABI EVIDENCE: x32 number %d added denial attributed; before=%d after=%d\n", i, s.X32Before[i], errno)
			}
		}
		if err := p.stop(); err != nil || p.boundary.count() != 0 {
			t.Fatal("x32 probe cleanup or zero-effect floor failed")
		}
	}
	fmt.Printf("ABI LIMIT: %s foreign-ABI executable control unproved; native calls and modeled audit fields do not establish compat execution\n", runtime.GOARCH)
}
