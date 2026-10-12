//go:build war_child_trial && linux

package ownedchild

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const diagnostic = "WAR1diag"

var workerAddress = flag.String("war-address", "", "private controller-created fixture socket")

// nativeEnabled makes the separately built native executable default-off.
func nativeEnabled() bool { return true }

// packet carries actual recvmsg observations, including retired received rights.
type packet struct {
	sender        sender
	valid         bool
	flags, rights int
}

// readyRead bounds each native socket operation using kernel readiness.
func readyRead(fd int, timeout time.Duration) error {
	if fd < 0 || fd > math.MaxInt32 {
		return errors.New("descriptor outside kernel poll range")
	}
	poll := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	deadline := time.Now().Add(timeout)
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return errors.New("socket readiness deadline")
		}
		n, err := unix.Poll(poll, int(remaining.Milliseconds())+1)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return err
		}
		if n == 0 {
			return errors.New("socket readiness deadline")
		}
		if poll[0].Revents&unix.POLLNVAL != 0 {
			return errors.New("invalid owned descriptor")
		}
		return nil
	}
}

// receive validates a complete packet and closes every received descriptor.
func receive(fd int) (packet, error) {
	if err := readyRead(fd, 3*time.Second); err != nil {
		return packet{}, err
	}
	data := make([]byte, len(diagnostic)+1)
	oob := make([]byte, unix.CmsgSpace(unix.SizeofUcred)+unix.CmsgSpace(16*4))
	n, controlN, flags, _, err := unix.Recvmsg(fd, data, oob, unix.MSG_DONTWAIT|unix.MSG_CMSG_CLOEXEC)
	if err != nil {
		return packet{}, err
	}
	p := packet{flags: flags}
	messages, err := unix.ParseSocketControlMessage(oob[:controlN])
	if err != nil {
		return p, err
	}
	credentials := 0
	unknown := false
	var controlErr error
	for _, message := range messages {
		if message.Header.Level != unix.SOL_SOCKET {
			unknown = true
			continue
		}
		switch message.Header.Type {
		case unix.SCM_RIGHTS:
			fds, parseErr := unix.ParseUnixRights(&message)
			if parseErr != nil {
				controlErr = errors.Join(controlErr, parseErr)
				continue
			}
			for _, received := range fds {
				p.rights++
				if closeErr := unix.Close(received); closeErr != nil {
					controlErr = errors.Join(controlErr, closeErr)
				}
			}
		case unix.SCM_CREDENTIALS:
			credentials++
			if len(message.Data) != unix.SizeofUcred {
				unknown = true
				continue
			}
			cred, parseErr := unix.ParseUnixCredentials(&message)
			if parseErr != nil {
				controlErr = errors.Join(controlErr, parseErr)
				continue
			}
			p.sender = sender{pid: cred.Pid, uid: cred.Uid, gid: cred.Gid}
		default:
			unknown = true
		}
	}
	if controlErr != nil {
		return p, controlErr
	}
	// Zero-data packets can still deliver rights. Retire them only after closing
	// all delivered descriptors, just as for a lost connection.
	if n == 0 {
		return p, io.EOF
	}
	p.valid = credentials == 1 && p.sender.pid > 0 && !unknown && p.rights == 0 &&
		flags&(unix.MSG_TRUNC|unix.MSG_CTRUNC) == 0 && bytes.Equal(data[:n], []byte(diagnostic))
	return p, nil
}

// evaluate is the actual diagnostic controller path: incomplete observations
// retire control before any subsequent packet can be considered.
func (p *owned) evaluate(fd int) (packet, bool, error) {
	frame, err := receive(fd)
	if err != nil {
		p.boundary.retire()
		return frame, false, err
	}
	accepted := p.boundary.authorize(frame.sender, frame.valid, p.live)
	return frame, accepted, nil
}

// owned retains an explicit pidfd, the sole Cmd.Wait owner and private pipes.
type owned struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	pidfd      int
	input      io.WriteCloser
	output     *os.File
	replies    chan reply
	readerDone chan struct{}
	readerErr  error
	waitDone   chan struct{}
	waitErr    error
	joined     bool
	closed     bool
	cleanupErr error
	boundary   *boundary
}

// reply is diagnostic worker evidence; it never constructs process authority.
type reply struct {
	Event  string
	PID    int
	Status map[string]string
	Inode  uint64
}

// launch captures the kernel process handle in this trusted start operation.
func launch(mode, address string, extra []*os.File) (*owned, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		return nil, err
	}
	// This fixed executable is built by the disposable image, never player input.
	cmd := exec.Command("/out/owned-child.test", "-war-experimental", "-war-worker="+mode, "-war-address="+address)
	cmd.ExtraFiles = extra
	cmd.Stderr = os.Stderr
	pidfd := -1
	cmd.SysProcAttr = &syscall.SysProcAttr{PidFD: &pidfd,
		Credential: &syscall.Credential{Uid: 10001, Gid: 10001, Groups: []uint32{}}}
	input, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		_ = input.Close()
		return nil, err
	}
	cmd.Stdout = writer
	if err = cmd.Start(); err != nil {
		_ = input.Close()
		_ = reader.Close()
		_ = writer.Close()
		return nil, err
	}
	_ = writer.Close()
	pid := cmd.Process.Pid
	var originalPID int32
	if pid > 0 && pid <= math.MaxInt32 {
		originalPID = int32(pid)
	}
	p := &owned{cmd: cmd, pidfd: pidfd, input: input, output: reader,
		replies: make(chan reply, 32), readerDone: make(chan struct{}), waitDone: make(chan struct{}),
		boundary: &boundary{original: sender{pid: originalPID, uid: 10001, gid: 10001}}}
	go func() { p.waitErr = cmd.Wait(); close(p.waitDone) }()
	go func() {
		defer close(p.readerDone)
		defer close(p.replies)
		decoder := json.NewDecoder(reader)
		for {
			var message reply
			if decodeErr := decoder.Decode(&message); decodeErr != nil {
				p.boundary.retire()
				p.readerErr = decodeErr
				return
			}
			select {
			case p.replies <- message:
			default:
				p.boundary.retire()
				p.readerErr = errors.New("excess unconsumed worker replies")
				return
			}
		}
	}()
	if pidfd < 0 || originalPID == 0 {
		// No process authority is returned. Retain the already-owned Cmd and
		// report uncertainty rather than inventing a PID-signaling fallback.
		p.boundary.retire()
		return p, errors.New("launch did not capture a process handle; ownership retained")
	}
	if alive, probeErr := p.live(); probeErr != nil || !alive {
		return p, errors.New("launch-time handle is not live")
	}
	return p, nil
}

// live observes this retained lifetime; descriptor/PID lookup cannot replace it.
func (p *owned) live() (bool, error) {
	fd := p.pidfd
	if fd < 0 || fd > math.MaxInt32 {
		return false, errors.New("no retained pidfd")
	}
	poll := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	n, err := unix.Poll(poll, 0)
	if err != nil {
		return false, err
	}
	if poll[0].Revents&(unix.POLLNVAL|unix.POLLERR) != 0 {
		return false, errors.New("lost process handle")
	}
	return n == 0, nil
}

// command drives only the fixture-owned helper protocol, with a bounded reply.
func (p *owned) command(value string) (reply, error) {
	if _, err := fmt.Fprintln(p.input, value); err != nil {
		return reply{}, err
	}
	return p.next(value)
}

// next requires the expected event from the process this launch owns.
func (p *owned) next(event string) (reply, error) {
	select {
	case r, ok := <-p.replies:
		if !ok || r.Event != event || r.PID != p.cmd.Process.Pid {
			return r, errors.New("missing or mismatched owned worker reply")
		}
		return r, nil
	case <-time.After(3 * time.Second):
		return reply{}, errors.New("owned worker reply deadline")
	}
}

// stop revokes first, signals only through the captured handle and joins once.
func (p *owned) stop() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.boundary.retire()
	if p.closed {
		return p.cleanupErr
	}
	if p.pidfd < 0 {
		// Missing capture grants no signaling authority. The trusted helper can
		// still finish through its owned input EOF; a failed bounded join retains
		// the Cmd and surrounding containment for cleanup, without PID fallback.
		_ = p.input.Close()
		select {
		case <-p.waitDone:
		case <-time.After(3 * time.Second):
			return errors.New("no captured handle and input EOF did not join; ownership retained")
		}
	} else if err := unix.PidfdSendSignal(p.pidfd, unix.SIGTERM, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
		return err
	}
	select {
	case <-p.waitDone:
	case <-time.After(300 * time.Millisecond):
		if err := unix.PidfdSendSignal(p.pidfd, unix.SIGKILL, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
			return err
		}
		select {
		case <-p.waitDone:
		case <-time.After(3 * time.Second):
			return errors.New("owned join deadline; ownership retained")
		}
	}
	state := p.cmd.ProcessState
	if state == nil {
		return errors.New("join has no terminal process state; ownership retained")
	}
	status, ok := state.Sys().(syscall.WaitStatus)
	if !ok || !(status.Exited() || status.Signaled()) {
		return errors.New("join is not terminal; ownership retained")
	}
	var exitErr *exec.ExitError
	if p.waitErr != nil && !errors.As(p.waitErr, &exitErr) {
		return fmt.Errorf("join failed: %w", p.waitErr)
	}
	p.joined = true
	select {
	case <-p.readerDone:
		if !errors.Is(p.readerErr, io.EOF) {
			p.cleanupErr = fmt.Errorf("owned output did not complete: %w", p.readerErr)
		}
	case <-time.After(3 * time.Second):
		return errors.New("owned output join deadline; ownership retained")
	}
	if p.pidfd >= 0 {
		if err := unix.Close(p.pidfd); err != nil {
			return err
		}
	}
	p.pidfd = -1
	p.closed = true
	_ = p.input.Close()
	p.cleanupErr = errors.Join(p.cleanupErr, p.output.Close())
	return p.cleanupErr
}

// statusEvidence reads the sender's own kernel status before any helper effect.
func statusEvidence() (map[string]string, error) {
	data, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return nil, err
	}
	result := make(map[string]string)
	for _, line := range strings.Split(string(data), "\n") {
		name, value, found := strings.Cut(line, ":")
		if found {
			result[name] = strings.TrimSpace(value)
		}
	}
	return result, nil
}

// worker executes only the diagnostic commands used by the native fixture.
func worker(mode string) int {
	if mode == "resistant" {
		signal.Ignore(syscall.SIGTERM)
	}
	status, err := statusEvidence()
	if err != nil {
		return 1
	}
	fd := -1
	switch mode {
	case "original", "resistant":
		fd, err = unix.Socket(unix.AF_UNIX, unix.SOCK_SEQPACKET|unix.SOCK_CLOEXEC, 0)
		if err == nil {
			err = unix.Connect(fd, &unix.SockaddrUnix{Name: *workerAddress})
		}
	case "inherited":
		fd = 3
	case "received":
		if err = readyRead(3, 3*time.Second); err != nil {
			return 1
		}
		data, oob := make([]byte, 1), make([]byte, unix.CmsgSpace(4))
		var controlN, flags int
		_, controlN, flags, _, err = unix.Recvmsg(3, data, oob, unix.MSG_CMSG_CLOEXEC)
		if err == nil && flags&(unix.MSG_CTRUNC|unix.MSG_TRUNC) != 0 {
			err = errors.New("transfer truncated")
		}
		if err == nil {
			messages, parseErr := unix.ParseSocketControlMessage(oob[:controlN])
			if parseErr != nil || len(messages) != 1 {
				return 1
			}
			fds, parseErr := unix.ParseUnixRights(&messages[0])
			if parseErr != nil || len(fds) != 1 {
				return 1
			}
			fd = fds[0]
		}
	case "canary":
	default:
		return 2
	}
	if err != nil {
		return 1
	}
	defer func() {
		if fd >= 0 {
			_ = unix.Close(fd)
		}
	}()
	var socketStat unix.Stat_t
	if fd >= 0 && unix.Fstat(fd, &socketStat) != nil {
		return 1
	}
	encoder := json.NewEncoder(os.Stdout)
	if encoder.Encode(reply{Event: "ready", PID: os.Getpid(), Status: status, Inode: socketStat.Ino}) != nil {
		return 1
	}
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		command := scanner.Text()
		switch command {
		case "send":
			err = unix.Sendmsg(fd, []byte(diagnostic), nil, nil, 0)
		case "malformed":
			err = unix.Sendmsg(fd, []byte("WRONG"), nil, nil, 0)
		case "large":
			err = unix.Sendmsg(fd, []byte(diagnostic+"overflow"), nil, nil, 0)
		case "rights":
			err = unix.Sendmsg(fd, []byte(diagnostic), unix.UnixRights(3), nil, 0)
		case "many-rights":
			rights := make([]int, 64)
			for i := range rights {
				rights[i] = 3
			}
			err = unix.Sendmsg(fd, []byte(diagnostic), unix.UnixRights(rights...), nil, 0)
		case "give":
			err = unix.Sendmsg(3, []byte("F"), unix.UnixRights(fd), nil, 0)
		case "close":
			err = unix.Close(fd)
			fd = -1
		case "ping":
		case "bad-output":
			_, _ = fmt.Fprint(os.Stdout, "{not-json")
			return 0
		case "flood":
			for range 64 {
				if encoder.Encode(reply{Event: command, PID: os.Getpid()}) != nil {
					return 1
				}
			}
			return 0
		case "exit":
			return 0
		default:
			return 2
		}
		if err != nil || encoder.Encode(reply{Event: command, PID: os.Getpid()}) != nil {
			return 1
		}
	}
	if scanner.Err() != nil {
		return 1
	}
	return 0
}

// validateIdentity checks observed anti-forgery conditions rather than config.
func validateIdentity(r reply) error {
	for _, name := range []string{"Uid", "Gid"} {
		fields := strings.Fields(r.Status[name])
		if len(fields) != 4 {
			return errors.New("incomplete credential observation")
		}
		for _, field := range fields {
			value, err := strconv.ParseUint(field, 10, 32)
			if err != nil || value == 0 || field != fields[0] {
				return errors.New("real/effective/saved credentials differ or are privileged")
			}
		}
	}
	if r.Status["Groups"] != "" || r.Status["NoNewPrivs"] != "1" {
		return errors.New("groups or no-new-privileges floor missing")
	}
	for _, name := range []string{"CapEff", "CapPrm", "CapInh", "CapAmb"} {
		value, err := strconv.ParseUint(r.Status[name], 16, 64)
		if err != nil || value != 0 {
			return errors.New("sender has credential-forging or other capabilities")
		}
	}
	return nil
}
