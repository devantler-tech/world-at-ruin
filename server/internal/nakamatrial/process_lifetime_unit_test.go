//go:build !war_native_trial

package nakamatrial

import (
	"bufio"
	"context"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestStoppedChildCleanup catches shutdown that leaves a stopped child unable
// to consume its cooperative termination signal.
func TestStoppedChildCleanup(t *testing.T) {
	// A TERM handler must execute in userspace; default kernel termination
	// can terminate a stopped process on macOS without proving resumption.
	// Stay in userspace rather than Bash's blocking read builtin, whose
	// interrupted-read/trap handling makes this signal test timing-dependent.
	cmd := exec.CommandContext(t.Context(), "bash", "-c", "trap 'exit 0' TERM; printf 'ready\\n'; while :; do :; done")
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	t.Cleanup(func() {
		if err := stopOwnedProcess(cmd.Process, done, time.Second, time.Second); err != nil {
			t.Error(err)
		}
	})
	ready := make(chan bool, 1)
	go func() { ready <- bufio.NewScanner(output).Scan() }()
	select {
	case ok := <-ready:
		if !ok {
			t.Fatal("child did not install its cooperative handler")
		}
	case <-time.After(time.Second):
		t.Fatal("cooperative child startup exceeded its bound")
	}
	if err := cmd.Process.Signal(syscall.SIGSTOP); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	for {
		// Keep command arguments literal; select only the exact owned PID
		// from the returned kernel process-state inventory.
		states, err := exec.CommandContext(ctx, "ps", "-axo", "pid=,state=").Output()
		if err != nil {
			t.Fatal("observe exact stopped child", err)
		}
		stopped := false
		for line := range strings.SplitSeq(string(states), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 2 && fields[0] == strconv.Itoa(cmd.Process.Pid) {
				stopped = strings.HasPrefix(fields[1], "T")
				break
			}
		}
		if stopped {
			break
		}
		if ctx.Err() != nil {
			t.Fatal("child did not enter stopped state")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := stopOwnedProcess(cmd.Process, done, 200*time.Millisecond, time.Second); err != nil {
		t.Fatal(err)
	}
	if !cmd.ProcessState.Success() {
		t.Fatal("stopped child could not consume cooperative shutdown")
	}
}
