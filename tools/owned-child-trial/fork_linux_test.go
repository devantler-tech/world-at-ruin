//go:build war_child_trial && linux

package ownedchild

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// forkArgs has a fixed 64-bit layout checked by the native assembly layout test.
// Every pointer refers to preallocated memory retained through the synchronous call.
type forkArgs struct {
	Socket, ReadFD, WriteFD                    int64
	Path                                       *byte
	Message                                    *unix.Msghdr
	Record                                     *[forkRecordSize]byte
	Pidfd                                      int32
	Pad                                        int32
	Flags                                      uint64
	Result                                     int64
	Saved, Blocked, Restored                   uint64
	BlockResult, RestoreResult, ReadbackResult int64
	Mode                                       uint64
	Sleep                                      unix.Timespec
}

// rawFork contains both parent mask handling and the non-returning raw child.
func rawFork(args *forkArgs)

// waitFork performs only a nonblocking exact P_PIDFD terminal wait.
func waitFork(fd int64, info *[128]byte) int64

// forkEvidence never confers authority from a worker's reported PID.
type forkEvidence struct {
	PID                                       int64
	Status                                    map[string]string
	Send                                      int64
	Complete, Joined, Closed, Killed, Refused bool
	TerminalCode, TerminalStatus              int32
	SavedMask, RestoredMask                   uint64
	CloneResult                               int64
	Existing                                  []int
	Bounding                                  string
}

// forkOwned belongs only to the original worker that performed clone.
type forkOwned struct {
	fd         int
	reader     int
	proof      *forkEvidence
	closed     bool
	cleanupErr error
}

// startFork establishes actual multithreaded fork and observes its private pipe.
func startFork(socket int, mode string) (child *forkOwned, proof *forkEvidence, err error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	var tasks []*lockedTask
	defer func() { err = errors.Join(err, closeTasks(tasks)) }()
	for range 2 {
		task, taskErr := retainTask()
		if taskErr != nil {
			return nil, nil, taskErr
		}
		tasks = append(tasks, task)
	}
	ids, err := taskIDs()
	if err != nil {
		return nil, nil, err
	}
	parentStatus, err := statusEvidence()
	if err != nil {
		return nil, nil, err
	}
	installer := unix.Gettid()
	if tasks[0].tid == tasks[1].tid || tasks[0].tid == installer || tasks[1].tid == installer ||
		!slices.Contains(ids, tasks[0].tid) || !slices.Contains(ids, tasks[1].tid) {
		return nil, nil, errors.New("fork lacks retained distinct threads")
	}
	var pipe [2]int
	if err = unix.Pipe2(pipe[:], unix.O_CLOEXEC|unix.O_NONBLOCK); err != nil {
		return nil, nil, err
	}
	path := []byte("/proc/self/status\x00")
	if mode == "status-error" {
		path = []byte("/proc/war-missing-status\x00")
	}
	data := []byte(diagnostic)
	iov := unix.Iovec{Base: &data[0], Len: uint64(len(data))}
	message := unix.Msghdr{Iov: &iov, Iovlen: 1}
	var record [forkRecordSize]byte
	args := forkArgs{Socket: int64(socket), ReadFD: int64(pipe[0]), WriteFD: int64(pipe[1]),
		Path: &path[0], Message: &message, Record: &record, Pidfd: -1,
		Flags: unix.CLONE_PIDFD | uint64(unix.SIGCHLD), Blocked: ^uint64(0), Sleep: unix.Timespec{Sec: 5}}
	switch mode {
	case "resistant", "orphan":
		args.Mode = 1
	case "delayed":
		args.Mode = 2
	case "clone-error":
		args.Flags |= unix.CLONE_PARENT_SETTID
	case "send-error":
		args.Socket = -1
	case "short-record":
		args.Mode = 3
	}
	rawFork(&args)
	runtime.KeepAlive(args)
	runtime.KeepAlive(path)
	runtime.KeepAlive(data)
	runtime.KeepAlive(iov)
	runtime.KeepAlive(message)
	runtime.KeepAlive(record)
	proof = &forkEvidence{SavedMask: args.Saved, RestoredMask: args.Restored, CloneResult: args.Result,
		Existing: []int{installer, tasks[0].tid, tasks[1].tid}, Bounding: parentStatus["CapBnd"]}
	if closeErr := unix.Close(pipe[1]); closeErr != nil {
		err = closeErr
	}
	if args.BlockResult != 0 || args.RestoreResult != 0 || args.ReadbackResult != 0 || args.Saved != args.Restored {
		_ = unix.Close(pipe[0])
		return nil, proof, errors.New("parent signal mask was not exactly restored")
	}
	if args.Result < 0 {
		proof.Refused = true
		return nil, proof, errors.Join(err, unix.Close(pipe[0]))
	}
	child = &forkOwned{fd: int(args.Pidfd), reader: pipe[0], proof: proof}
	if args.Result <= 0 || args.Pidfd < 0 {
		proof.Refused = true
		return child, proof, errors.New("clone capture missing; containment retained")
	}
	proof.PID = args.Result
	if mode == "delayed" {
		proof.Refused = true
		return child, proof, err
	}
	if readErr := readyRead(pipe[0]); readErr != nil {
		proof.Refused = true
		return child, proof, errors.Join(err, readErr)
	}
	n, readErr := unix.Read(pipe[0], record[:])
	if readErr != nil {
		proof.Refused = true
		return child, proof, errors.Join(err, readErr)
	}
	r, status, decodeErr := decodeFork(record[:n])
	proof.Status, proof.Send = status, r.Send
	if decodeErr != nil || r.PID != args.Result || validateIdentity(reply{Status: status}) != nil ||
		status["Tgid"] != strconv.FormatInt(args.Result, 10) || status["Pid"] != status["Tgid"] {
		proof.Refused = true
	} else {
		proof.Complete = r.Send == int64(len(diagnostic))
		proof.Refused = !proof.Complete
	}
	return child, proof, err
}

// terminal consumes one exact terminal state; ECHILD never counts as a join.
func (c *forkOwned) terminal(deadline time.Time) (bool, error) {
	for {
		var info [128]byte
		result := waitFork(int64(c.fd), &info)
		if result != 0 {
			return false, fmt.Errorf("exact fork wait failed: %d", result)
		}
		var state struct {
			Signo, Errno, Code, Pad, PID int32
			UID                          uint32
			Status, Pad2                 int32
		}
		if err := binary.Read(bytes.NewReader(info[:32]), binary.LittleEndian, &state); err != nil {
			return false, err
		}
		if state.PID != 0 {
			if state.Signo != int32(unix.SIGCHLD) || state.Errno != 0 || int64(state.PID) != c.proof.PID || state.UID != 10001 ||
				(state.Code != 1 && state.Code != 2 && state.Code != 3) {
				return false, errors.New("fork terminal state mismatched; containment retained")
			}
			c.proof.Joined = true
			c.proof.TerminalCode, c.proof.TerminalStatus = state.Code, state.Status
			return true, nil
		}
		if !time.Now().Before(deadline) {
			return false, nil
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// stop signals only the captured handle and closes it after the sole exact join.
func (c *forkOwned) stop() error {
	if c.closed {
		return c.cleanupErr
	}
	if c.fd < 0 {
		return errors.New("fork capture missing; ownership retained")
	}
	if err := unix.PidfdSendSignal(c.fd, unix.SIGTERM, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
		return err
	}
	joined, err := c.terminal(time.Now().Add(300 * time.Millisecond))
	if err != nil {
		return err
	}
	if !joined {
		if err = unix.PidfdSendSignal(c.fd, unix.SIGKILL, nil, 0); err != nil {
			return err
		}
		c.proof.Killed = true
		joined, err = c.terminal(time.Now().Add(3 * time.Second))
		if err != nil || !joined {
			return errors.Join(err, errors.New("fork join deadline; ownership retained"))
		}
	}
	// Only the exact terminal wait establishes EOF is now meaningful.
	var extra [1]byte
	n, readErr := unix.Read(c.reader, extra[:])
	if n != 0 || readErr != nil {
		c.cleanupErr = errors.New("fork record has excess or unread bytes")
	}
	c.cleanupErr = errors.Join(c.cleanupErr, unix.Close(c.fd), unix.Close(c.reader))
	c.fd = -1
	c.closed = true
	c.proof.Closed = true
	return c.cleanupErr
}

// forkCommand keeps descendant launch and reaping in the original worker.
func forkCommand(command string, socket int, current *forkOwned) (*forkOwned, *forkEvidence, error) {
	mode := strings.TrimPrefix(command, "fork:")
	if mode == "fault-capture" || mode == "fault-wait" {
		if current == nil || current.closed {
			return current, nil, errors.New("no live fault-owned fork")
		}
		captured := current.fd
		current.fd = -1
		var faultErr error
		if mode == "fault-capture" {
			faultErr = current.stop()
		} else {
			_, faultErr = current.terminal(time.Now())
		}
		current.fd = captured
		if faultErr == nil || current.closed || current.proof.Joined {
			return current, current.proof, errors.New("ownership fault accepted")
		}
		current.proof.Refused = true
		return current, current.proof, nil
	}
	if mode == "join" || mode == "join-again" {
		if current == nil {
			return nil, nil, errors.New("no owned fork")
		}
		err := current.stop()
		return current, current.proof, err
	}
	if current != nil {
		return current, current.proof, errors.New("fork already owned")
	}
	return startFork(socket, mode)
}
