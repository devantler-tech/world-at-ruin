//go:build war_child_trial && linux

package ownedchild

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"unsafe"

	"golang.org/x/sys/unix"
)

// sealResult retains both raw syscall values; errno alone loses TSYNC refusals.
type sealResult struct {
	Value uint64
	Errno uint64
}

// sealEvidence describes trusted startup observations, not independent attestation.
type sealEvidence struct {
	Result              sealResult
	Synchronized        bool
	Installer           int
	Existing            []int
	Before              []int
	After               []int
	Future              int
	Divergent           int
	ProbeTID            int
	ProbeErrno          uint64
	X32Before           []uint64
	X32After            []uint64
	BeforeFilters       map[int]int
	AfterFilters        map[int]int
	ProbeFilters        int
	InstallerProbeErrno uint64
}

// nativeAuditArch restricts the experiment to its two actually tested ABIs.
func nativeAuditArch() uint32 {
	switch runtime.GOARCH {
	case "amd64":
		return unix.AUDIT_ARCH_X86_64
	case "arm64":
		return unix.AUDIT_ARCH_AARCH64
	default:
		return 0
	}
}

// execFilter rejects foreign architectures before interpreting syscall numbers.
// The allow verdict only preserves the inherited filter; it cannot loosen it.
func execFilter(arch uint32) []unix.SockFilter {
	return []unix.SockFilter{
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 4},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: arch, Jt: 1},
		{Code: unix.BPF_RET | unix.BPF_K, K: unix.SECCOMP_RET_KILL_PROCESS},
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 0},
		{Code: unix.BPF_JMP | unix.BPF_JSET | unix.BPF_K, K: 0x40000000, Jt: 4},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: uint32(unix.SYS_EXECVE), Jt: 2},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: uint32(unix.SYS_EXECVEAT), Jt: 1},
		{Code: unix.BPF_RET | unix.BPF_K, K: unix.SECCOMP_RET_ALLOW},
		{Code: unix.BPF_RET | unix.BPF_K, K: unix.SECCOMP_RET_ERRNO | uint32(unix.EPERM)},
		// A distinct denying errno discriminates this branch from inherited EPERM.
		{Code: unix.BPF_RET | unix.BPF_K, K: unix.SECCOMP_RET_ERRNO | uint32(unix.EACCES)},
	}
}

// installFilter preserves positive TSYNC return values without converting them.
// Callers hold an OS-thread lock and retain that lock after changing its filter.
func installFilter(filter []unix.SockFilter, flags uintptr) sealResult {
	length := len(filter)
	if length <= 0 || length > 4096 {
		return sealResult{Value: ^uint64(0), Errno: uint64(unix.EINVAL)}
	}
	program := unix.SockFprog{Len: uint16(length), Filter: &filter[0]}
	value, _, errno := unix.RawSyscall(unix.SYS_SECCOMP, unix.SECCOMP_SET_MODE_FILTER, flags, uintptr(unsafe.Pointer(&program)))
	runtime.KeepAlive(filter)
	runtime.KeepAlive(program)
	return sealResult{Value: uint64(value), Errno: uint64(errno)}
}

// taskFilters observes inherited confinement and NNP on every inventoried thread.
func taskFilters(ids []int) (map[int]int, error) {
	counts := make(map[int]int, len(ids))
	for _, tid := range ids {
		if tid <= 0 {
			return nil, errors.New("invalid observed task ID")
		}
		data, err := os.ReadFile(fmt.Sprintf("/proc/self/task/%d/status", tid))
		if err != nil {
			return nil, err
		}
		status := make(map[string]string)
		for _, line := range strings.Split(string(data), "\n") {
			name, value, found := strings.Cut(line, ":")
			if found {
				status[name] = strings.TrimSpace(value)
			}
		}
		count, err := strconv.Atoi(status["Seccomp_filters"])
		if err != nil || count <= 0 || status["Seccomp"] != "2" || validateIdentity(reply{Status: status}) != nil {
			return nil, errors.New("thread lacks observed inherited filter, identity or NNP")
		}
		counts[tid] = count
	}
	return counts, nil
}

// taskIDs reads a complete bounded kernel task inventory before selecting a TID.
func taskIDs() ([]int, error) {
	entries, err := os.ReadDir("/proc/self/task")
	if err != nil || len(entries) == 0 || len(entries) > 64 {
		return nil, errors.New("task inventory unavailable or outside bound")
	}
	ids := make([]int, 0, len(entries))
	for _, entry := range entries {
		id, parseErr := strconv.Atoi(entry.Name())
		if parseErr != nil || id <= 0 || !entry.IsDir() {
			return nil, errors.New("incomplete task inventory")
		}
		ids = append(ids, id)
	}
	return ids, nil
}

// sealWorker seals all existing threads after Go establishes its template thread.
// It never unlocks a thread whose process filter has permanently changed.
func sealWorker() (*sealEvidence, error) {
	runtime.LockOSThread()
	if nnp, err := unix.PrctlRetInt(unix.PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0); err != nil || nnp != 1 {
		return nil, errors.New("no-new-privileges was not observed before sealing")
	}
	arch := nativeAuditArch()
	if arch == 0 {
		return nil, errors.New("unsupported native architecture")
	}
	before, err := taskIDs()
	if err != nil {
		return nil, err
	}
	beforeFilters, err := taskFilters(before)
	if err != nil {
		return nil, err
	}
	result := installFilter(execFilter(arch), unix.SECCOMP_FILTER_FLAG_TSYNC)
	after, err := taskIDs()
	if err != nil {
		return nil, err
	}
	afterFilters, err := taskFilters(after)
	if err != nil {
		return nil, err
	}
	for _, tid := range before {
		if result == (sealResult{}) && afterFilters[tid] != beforeFilters[tid]+1 {
			return nil, errors.New("thread did not retain the inherited synchronized filter chain")
		}
	}
	return &sealEvidence{Result: result, Synchronized: true, Installer: unix.Gettid(), Before: before, After: after, BeforeFilters: beforeFilters, AfterFilters: afterFilters}, nil
}
