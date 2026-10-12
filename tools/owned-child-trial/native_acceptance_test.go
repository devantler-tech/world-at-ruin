//go:build war_child_trial && linux

package ownedchild

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// requireReply verifies a successful command and returns its observed outcome.
func requireReply(t *testing.T, p *owned, command string) reply {
	t.Helper()
	r, err := p.command(command)
	if err != nil {
		t.Fatalf("%s: %v", command, err)
	}
	return r
}

// own launches one helper and registers bounded exact cleanup before assertions.
func own(t *testing.T, mode, address string, extra []*os.File) *owned {
	t.Helper()
	p, err := launch(mode, address, extra)
	if p != nil {
		t.Cleanup(func() {
			if stopErr := p.stop(); stopErr != nil {
				t.Errorf("owned cleanup: %v", stopErr)
			}
		})
	}
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// requireReady establishes observed sender identities for every helper.
func requireReady(t *testing.T, p *owned) reply {
	t.Helper()
	r, err := p.next("ready")
	if err != nil {
		t.Fatal(err)
	}
	if err := validateIdentity(r); err != nil {
		t.Fatal(err)
	}
	return r
}

// pair creates an invocation-owned seqpacket channel with close-on-exec.
func pair(t *testing.T) [2]*os.File {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_SEQPACKET|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	files := [2]*os.File{os.NewFile(uintptr(fds[0]), "controller-transfer"), os.NewFile(uintptr(fds[1]), "worker-transfer")}
	t.Cleanup(func() { _ = files[0].Close(); _ = files[1].Close() })
	return files
}

// connected launches the original child into a private listener and enables
// per-message credentials before the controller sends its first command.
func connected(t *testing.T, mode string) (*owned, int, [2]*os.File) {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "war-child-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(directory); err != nil {
			t.Errorf("socket cleanup: %v", err)
		}
	})
	// Only disposable socket paths are traversable; no issuer or secret state.
	if err := os.Chmod(directory, 0755); err != nil {
		t.Fatal(err)
	}
	address := filepath.Join(directory, "control.sock")
	listener, err := unix.Socket(unix.AF_UNIX, unix.SOCK_SEQPACKET|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := unix.Close(listener); err != nil {
			t.Errorf("listener close: %v", err)
		}
	}()
	if err := unix.SetsockoptInt(listener, unix.SOL_SOCKET, unix.SO_PASSCRED, 1); err != nil {
		t.Fatal(err)
	}
	if err := unix.Bind(listener, &unix.SockaddrUnix{Name: address}); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(address, 0666); err != nil {
		t.Fatal(err)
	}
	if err := unix.Listen(listener, 1); err != nil {
		t.Fatal(err)
	}
	transfer := pair(t)
	p := own(t, mode, address, []*os.File{transfer[1]})
	if err := readyRead(listener); err != nil {
		t.Fatal(err)
	}
	fd, _, err := unix.Accept4(listener, unix.SOCK_CLOEXEC)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = unix.Close(fd) })
	if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_PASSCRED, 1); err != nil {
		t.Fatal(err)
	}
	requireReady(t, p)
	return p, fd, transfer
}

// requirePacket observes the real complete frame rather than the helper's claim.
func requirePacket(t *testing.T, p *owned, fd int) (packet, bool) {
	t.Helper()
	frame, accepted, err := p.evaluate(fd)
	if err != nil {
		t.Fatal(err)
	}
	return frame, accepted
}

// TestNativeOwnedChild proves real socket transfer cannot adopt original authority.
func TestNativeOwnedChild(t *testing.T) {
	canary := own(t, "canary", "", nil)
	requireReady(t, canary)
	original, receiver, transfer := connected(t, "original")
	peer, err := unix.GetsockoptUcred(receiver, unix.SOL_SOCKET, unix.SO_PEERCRED)
	if err != nil || peer.Pid != original.boundary.original.pid {
		t.Fatal("connection peer is not original child")
	}
	requireReply(t, original, "send")
	first, accepted := requirePacket(t, original, receiver)
	if !accepted {
		t.Fatal("original positive refused")
	}

	// Get the already-connected endpoint from the original via SCM_RIGHTS.
	requireReply(t, original, "give")
	if err := readyRead(int(transfer[0].Fd())); err != nil {
		t.Fatal(err)
	}
	data, oob := make([]byte, 1), make([]byte, unix.CmsgSpace(4))
	n, controlN, flags, _, err := unix.Recvmsg(int(transfer[0].Fd()), data, oob, unix.MSG_CMSG_CLOEXEC)
	if err != nil || n != 1 || data[0] != 'F' || flags&(unix.MSG_CTRUNC|unix.MSG_TRUNC) != 0 {
		t.Fatal("original endpoint transfer incomplete")
	}
	messages, err := unix.ParseSocketControlMessage(oob[:controlN])
	if err != nil || len(messages) != 1 {
		t.Fatal("original endpoint transfer malformed")
	}
	fds, err := unix.ParseUnixRights(&messages[0])
	if err != nil || len(fds) != 1 {
		t.Fatal("original endpoint not transferred")
	}
	endpoint := os.NewFile(uintptr(fds[0]), "original-connected-endpoint")
	defer func() {
		if err := endpoint.Close(); err != nil {
			t.Errorf("transferred endpoint close: %v", err)
		}
	}()
	var inode unix.Stat_t
	if err := unix.Fstat(fds[0], &inode); err != nil {
		t.Fatal(err)
	}

	// A second real SCM_RIGHTS hop makes a separately launched same-UID sender
	// receive that exact endpoint, instead of opening another connection.
	replacementTransfer := pair(t)
	received := own(t, "received", "", []*os.File{replacementTransfer[1]})
	if err := unix.Sendmsg(int(replacementTransfer[0].Fd()), []byte("F"), unix.UnixRights(fds[0]), nil, 0); err != nil {
		t.Fatal(err)
	}
	receivedReady := requireReady(t, received)
	inherited := own(t, "inherited", "", []*os.File{endpoint})
	inheritedReady := requireReady(t, inherited)
	if receivedReady.Inode != inode.Ino || inheritedReady.Inode != inode.Ino {
		t.Fatal("replacement did not obtain the original socket")
	}
	comparisonEffects := 0
	for _, replacement := range []*owned{received, inherited} {
		requireReply(t, replacement, "send")
		p, accepted := requirePacket(t, original, receiver)
		alive, probeErr := original.live()
		if probeErr != nil || !alive || !p.valid || p.sender.pid != replacement.boundary.original.pid || p.sender == first.sender {
			t.Fatal("replacement did not send a valid packet while original lived")
		}
		if p.sender.uid != first.sender.uid || p.sender.gid != first.sender.gid {
			t.Fatal("replacement is not same UID/GID")
		}
		if accepted {
			t.Fatal("same-user socket replacement adopted original authority")
		}
		// This intentionally isolated comparison reads only connection identity.
		connection, err := unix.GetsockoptUcred(receiver, unix.SOL_SOCKET, unix.SO_PEERCRED)
		if err != nil {
			t.Fatal(err)
		}
		if p.valid && connection.Pid == first.sender.pid {
			comparisonEffects++
		}
	}
	if comparisonEffects != 2 || original.boundary.count() != 1 {
		t.Fatal("replacement comparison or secured effects are vacuous")
	}
	requireReply(t, original, "send")
	_, accepted = requirePacket(t, original, receiver)
	if !accepted || original.boundary.count() != 2 {
		t.Fatal("original stopped working after replacement refusal")
	}

	for _, command := range []string{"malformed", "large", "rights", "many-rights"} {
		requireReply(t, original, command)
		p, accepted := requirePacket(t, original, receiver)
		if p.valid || accepted {
			t.Fatalf("accepted %s packet", command)
		}
		if command == "large" && p.flags&unix.MSG_TRUNC == 0 {
			t.Fatal("data truncation control did not reach recvmsg")
		}
		if command == "rights" && p.rights != 1 {
			t.Fatal("unexpected descriptor was not received and closed")
		}
		if command == "many-rights" && (p.flags&unix.MSG_CTRUNC == 0 || p.rights == 0) {
			t.Fatal("control truncation did not exercise received descriptor cleanup")
		}
	}
	if original.boundary.count() != 2 {
		t.Fatal("invalid frames changed effects")
	}
	if err := unix.SetsockoptInt(receiver, unix.SOL_SOCKET, unix.SO_PASSCRED, 0); err != nil {
		t.Fatal(err)
	}
	requireReply(t, original, "send")
	missing, accepted := requirePacket(t, original, receiver)
	if accepted || missing.valid || missing.sender.pid != 0 {
		t.Fatal("missing kernel credentials accepted")
	}
	if err := unix.SetsockoptInt(receiver, unix.SOL_SOCKET, unix.SO_PASSCRED, 1); err != nil {
		t.Fatal(err)
	}

	// A valid packet queued before stop is examined after irreversible retirement.
	requireReply(t, original, "send")
	if err := original.stop(); err != nil {
		t.Fatal(err)
	}
	queued, accepted := requirePacket(t, original, receiver)
	if !queued.valid || accepted {
		t.Fatal("queued message reopened retired authority")
	}
	if err := original.stop(); err != nil || !original.joined || !original.closed {
		t.Fatal("duplicate stop or exact join failed")
	}
	requireReply(t, canary, "ping")
	if err := received.stop(); err != nil {
		t.Fatal(err)
	}
	if err := inherited.stop(); err != nil {
		t.Fatal(err)
	}
	if err := canary.stop(); err != nil {
		t.Fatal(err)
	}
	fmt.Printf("OWNED CHILD NATIVE PASS: %s launch-time pidfd; original effects=2; transferred/inherited effects=0; connection-only comparison=2; five frame refusals; exact joined cleanup\n", runtime.GOARCH)
}

// TestNativeOwnedRetirement proves natural death, forced stop and lost connection.
func TestNativeOwnedRetirement(t *testing.T) {
	for _, scenario := range []string{"death", "resistant", "connection"} {
		t.Run(scenario, func(t *testing.T) {
			mode := "original"
			if scenario == "resistant" {
				mode = "resistant"
			}
			p, receiver, _ := connected(t, mode)
			requireReply(t, p, "send")
			first, accepted := requirePacket(t, p, receiver)
			if !accepted {
				t.Fatal("retirement positive refused")
			}
			switch scenario {
			case "death":
				requireReply(t, p, "send")
				if _, err := fmt.Fprintln(p.input, "exit"); err != nil {
					t.Fatal(err)
				}
				select {
				case <-p.waitDone:
				case <-time.After(3 * time.Second):
					t.Fatal("natural exit did not join")
				}
				_, accepted := requirePacket(t, p, receiver)
				if accepted {
					t.Fatal("observed death accepted an effect")
				}
			case "resistant":
				requireReply(t, p, "send")
				if err := p.stop(); err != nil {
					t.Fatal(err)
				}
				status, ok := p.cmd.ProcessState.Sys().(syscall.WaitStatus)
				if !ok || !status.Signaled() || status.Signal() != syscall.SIGKILL {
					t.Fatal("resistant worker was not joined after SIGKILL")
				}
				_, accepted := requirePacket(t, p, receiver)
				if accepted {
					t.Fatal("forced stop accepted queued effect")
				}
			case "connection":
				requireReply(t, p, "close")
				if _, accepted, err := p.evaluate(receiver); !errors.Is(err, io.EOF) || accepted {
					t.Fatalf("control loss=%v, want EOF", err)
				}
				if p.boundary.authorize(first.sender, true, p.live) {
					t.Fatal("lost control reopened")
				}
			}
			if err := p.stop(); err != nil || !p.joined || p.boundary.count() != 1 {
				t.Fatal("retirement failed to close and join")
			}
		})
	}
}

// TestNativeOwnedCleanupFaults catches stranded missing-capture workers and a
// reader whose error or full reply queue prevents repeatable exact retirement.
func TestNativeOwnedCleanupFaults(t *testing.T) {
	for _, fault := range []string{"missing capture", "bad-output", "flood"} {
		t.Run(fault, func(t *testing.T) {
			p, err := launch("canary", "", nil)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				_ = p.stop()
				if !p.closed || !p.joined {
					t.Error("fault left owned resources or unjoined worker")
				}
			})
			requireReady(t, p)
			if fault == "missing capture" {
				// The fault removes capture from the controller's interface before
				// any effect. The test retains the actual descriptor through join.
				captured := p.pidfd
				defer func() {
					if err := unix.Close(captured); err != nil {
						t.Errorf("fault-held descriptor close: %v", err)
					}
				}()
				p.pidfd = -1
				p.boundary.retire()
				if err := p.stop(); err != nil {
					t.Fatal(err)
				}
				if !p.cmd.ProcessState.Success() {
					t.Fatal("missing-capture cleanup signaled rather than using input EOF")
				}
			} else {
				if _, err := fmt.Fprintln(p.input, fault); err != nil {
					t.Fatal(err)
				}
				select {
				case <-p.waitDone:
				case <-time.After(3 * time.Second):
					t.Fatal("fault worker failed to exit")
				}
				first := p.stop()
				second := p.stop()
				if first == nil || second == nil || first.Error() != second.Error() || !strings.Contains(first.Error(), "owned output did not complete") {
					t.Fatal("incomplete output was accepted or repeat lost its evidence")
				}
			}
			if !p.closed || !p.joined || p.boundary.count() != 0 {
				t.Fatal("cleanup fault changed effects or lost join")
			}
		})
	}
}
