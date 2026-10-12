//go:build war_child_trial && linux

package ownedchild

import (
	"errors"
	"fmt"
	"runtime"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// TestForkAssemblyLayout binds every assembly offset and syscall record size.
func TestForkAssemblyLayout(t *testing.T) {
	var a forkArgs
	offsets := []uintptr{unsafe.Offsetof(a.Socket), unsafe.Offsetof(a.ReadFD), unsafe.Offsetof(a.WriteFD),
		unsafe.Offsetof(a.Path), unsafe.Offsetof(a.Message), unsafe.Offsetof(a.Record), unsafe.Offsetof(a.Pidfd),
		unsafe.Offsetof(a.Flags), unsafe.Offsetof(a.Result), unsafe.Offsetof(a.Saved), unsafe.Offsetof(a.Blocked),
		unsafe.Offsetof(a.Restored), unsafe.Offsetof(a.BlockResult), unsafe.Offsetof(a.RestoreResult), unsafe.Offsetof(a.ReadbackResult),
		unsafe.Offsetof(a.Mode), unsafe.Offsetof(a.Sleep)}
	expected := []uintptr{0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128}
	for i, offset := range offsets {
		if offset != expected[i] {
			t.Fatal("assembly argument layout changed")
		}
	}
	if unsafe.Sizeof(a) != 144 || forkRecordSize != 3112 || forkRecordSize >= 4096 || len(diagnostic) != 8 {
		t.Fatal("assembly size contract changed")
	}
}

// forkReply refuses a missing or mismatched parent mask observation.
func forkReply(t *testing.T, p *owned, command string) *forkEvidence {
	t.Helper()
	r := requireReply(t, p, command)
	if r.Fork == nil || r.Fork.SavedMask != r.Fork.RestoredMask || len(r.Fork.Existing) != 3 {
		t.Fatal("incomplete fork or signal evidence")
	}
	return r.Fork
}

// TestNativeForkSender proves a real same-socket raw descendant cannot act as original.
func TestNativeForkSender(t *testing.T) {
	canary := own(t, "canary", "", nil)
	requireReady(t, canary)
	for _, mode := range []string{"normal", "resistant"} {
		t.Run(mode, func(t *testing.T) {
			original, receiver, _ := connected(t, "original")
			requireReply(t, original, "send")
			first, accepted := requirePacket(t, original, receiver)
			if !accepted {
				t.Fatal("original positive refused")
			}
			proof := forkReply(t, original, "fork:"+mode)
			if !proof.Complete || proof.Refused || proof.PID <= 0 || proof.PID == int64(first.sender.pid) || proof.Send != int64(len(diagnostic)) || validateIdentity(reply{Status: proof.Status}) != nil || proof.Bounding == "" || proof.Status["CapBnd"] != proof.Bounding || proof.Filters == "" || proof.Status["Seccomp_filters"] != proof.Filters || proof.Status["Seccomp"] != "2" {
				t.Fatal("real raw fork observation incomplete")
			}
			forkFrame, accepted := requirePacket(t, original, receiver)
			if accepted || !forkFrame.valid || int64(forkFrame.sender.pid) != proof.PID || forkFrame.sender.uid != first.sender.uid || forkFrame.sender.gid != first.sender.gid || original.boundary.count() != 1 {
				t.Fatal("fork frame adopted original authority")
			}
			peer, err := unix.GetsockoptUcred(receiver, unix.SOL_SOCKET, unix.SO_PEERCRED)
			if err != nil || peer.Pid != first.sender.pid || !forkFrame.valid {
				t.Fatal("connection-only comparison did not accept same fork packet")
			}
			joined := forkReply(t, original, "fork:join")
			if !joined.Joined || !joined.Closed || (mode == "resistant" && (!joined.Killed || joined.TerminalCode != 2 || joined.TerminalStatus != int32(unix.SIGKILL))) {
				t.Fatal("raw child not exactly joined and retired")
			}
			again := forkReply(t, original, "fork:join-again")
			if !again.Joined || !again.Closed || again.PID != joined.PID || again.TerminalCode != joined.TerminalCode || again.TerminalStatus != joined.TerminalStatus || again.Killed != joined.Killed {
				t.Fatal("duplicate cleanup changed terminal evidence")
			}
			requireReply(t, original, "send")
			_, accepted = requirePacket(t, original, receiver)
			if !accepted || original.boundary.count() != 2 {
				t.Fatal("original positive lost after fork cleanup")
			}
			requireReply(t, canary, "ping")
		})
	}
	fmt.Printf("FORK NATIVE PASS: %s; actual clone without exec; complete child status and pipe record; distinct kernel sender; zero fork effects; connection-only positive; exact join; TERM-resistant SIGKILL; original/canary alive\n", runtime.GOARCH)
}

// TestNativeForkFaults keeps real failed sends and incomplete records from proof.
func TestNativeForkFaults(t *testing.T) {
	for _, mode := range []string{"clone-error", "send-error", "status-error", "short-record", "delayed", "pipe-shutdown"} {
		t.Run(mode, func(t *testing.T) {
			p, receiver, _ := connected(t, "original")
			command := mode
			if mode == "pipe-shutdown" {
				if err := unix.Shutdown(receiver, unix.SHUT_RD); err != nil {
					t.Fatal(err)
				}
				command = "normal"
			}
			proof := forkReply(t, p, "fork:"+command)
			if proof.Complete || !proof.Refused || p.boundary.count() != 0 {
				t.Fatal("failed fork observation counted as success")
			}
			if mode == "clone-error" {
				if proof.CloneResult != -int64(unix.EINVAL) || proof.PID != 0 {
					t.Fatal("documented clone failure not observed")
				}
				return
			}
			if mode == "send-error" && proof.Send != -int64(unix.EBADF) {
				t.Fatal("native failed send not observed")
			}
			if mode == "pipe-shutdown" && proof.Send != -int64(unix.EPIPE) {
				t.Fatal("native EPIPE not observed")
			}
			joined := forkReply(t, p, "fork:join")
			if !joined.Joined || !joined.Closed || (mode == "delayed" && (!joined.Killed || joined.TerminalStatus != int32(unix.SIGKILL))) {
				t.Fatal("failed observation lost exact cleanup")
			}
			requireReply(t, p, "ping")
		})
	}
}

// TestNativeForkOwnershipFaults exercises missing capture and uncertain exact wait.
func TestNativeForkOwnershipFaults(t *testing.T) {
	for _, fault := range []string{"capture", "wait"} {
		t.Run(fault, func(t *testing.T) {
			// The canary worker forks under its observed unprivileged identity;
			// its absent socket also supplies a genuine failed-send control.
			p := own(t, "canary", "", nil)
			requireReady(t, p)
			proof := forkReply(t, p, "fork:resistant")
			if !proof.Refused || proof.Complete {
				t.Fatal("bad socket send accepted")
			}
			// Fault commands retain the actual handle privately; no reported PID
			// or pidfd_open reconstruction supplies cleanup authority.
			r := requireReply(t, p, "fork:fault-"+fault)
			if r.Fork == nil || !r.Fork.Refused || r.Fork.Joined || r.Fork.Closed {
				t.Fatal("uncertain ownership accepted")
			}
			joined := forkReply(t, p, "fork:join")
			if !joined.Joined || !joined.Closed || !joined.Killed {
				t.Fatal("fault-held handle not exactly joined")
			}
		})
	}
}

// orphanScenario intentionally leaves a raw grandchild unjoined in its own container.
func orphanScenario() int {
	p, err := launch("canary", "", nil)
	if err != nil {
		return 2
	}
	if _, err = p.next("ready"); err != nil {
		_ = p.stop()
		return 2
	}
	r, err := p.command("fork:orphan")
	if err != nil || r.Fork == nil || r.Fork.PID <= 0 {
		_ = p.stop()
		return 2
	}
	if err = unix.PidfdSendSignal(p.pidfd, unix.SIGKILL, nil, 0); err != nil {
		return 2
	}
	select {
	case <-p.waitDone:
	case <-time.After(3 * time.Second):
		return 2
	}
	if err = p.stop(); err == nil || !p.joined || p.closed || errors.Is(err, unix.ECHILD) {
		return 2
	}
	fmt.Println("EXPECTED FORK REFUSAL: original joined; descendant join unproved; containment retained")
	return 1
}
