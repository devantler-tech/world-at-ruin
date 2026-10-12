//go:build war_child_trial && linux

package ownedchild

import (
	"testing"

	"golang.org/x/sys/unix"
)

// policyVerdict evaluates only the tiny fixture's documented cBPF instruction set.
// This modeled test does not claim a real native or foreign-ABI syscall occurred.
func policyVerdict(t *testing.T, policy []unix.SockFilter, arch, number uint32) uint32 {
	t.Helper()
	var accumulator uint32
	for pc := 0; pc < len(policy); pc++ {
		instruction := policy[pc]
		switch instruction.Code {
		case unix.BPF_LD | unix.BPF_W | unix.BPF_ABS:
			switch instruction.K {
			case 0:
				accumulator = number
			case 4:
				accumulator = arch
			default:
				t.Fatal("unknown audit-data offset")
			}
		case unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K:
			if accumulator == instruction.K {
				pc += int(instruction.Jt)
			} else {
				pc += int(instruction.Jf)
			}
		case unix.BPF_JMP | unix.BPF_JSET | unix.BPF_K:
			if accumulator&instruction.K != 0 {
				pc += int(instruction.Jt)
			} else {
				pc += int(instruction.Jf)
			}
		case unix.BPF_RET | unix.BPF_K:
			return instruction.K
		default:
			t.Fatal("unknown fixture policy instruction")
		}
	}
	t.Fatal("policy fell through without a verdict")
	return 0
}

// TestExecSealFilterTable keeps filter-table checks separate from native evidence.
func TestExecSealFilterTable(t *testing.T) {
	arch := nativeAuditArch()
	policy := execFilter(arch)
	for _, number := range []uint32{uint32(unix.SYS_EXECVE), uint32(unix.SYS_EXECVEAT)} {
		if got := policyVerdict(t, policy, arch, number); got != unix.SECCOMP_RET_ERRNO|uint32(unix.EPERM) {
			t.Fatalf("native exec number %d allowed: %x", number, got)
		}
	}
	if got := policyVerdict(t, policy, arch, uint32(unix.SYS_GETPID)); got != unix.SECCOMP_RET_ALLOW {
		t.Fatal("ordinary native syscall refused by additional filter")
	}
	for _, foreign := range []uint32{unix.AUDIT_ARCH_I386, unix.AUDIT_ARCH_ARM, 0} {
		if got := policyVerdict(t, policy, foreign, uint32(unix.SYS_GETPID)); got != unix.SECCOMP_RET_KILL_PROCESS {
			t.Fatal("modeled foreign audit architecture allowed")
		}
	}
	for _, number := range []uint32{0x40000000 | 520, 0x40000000 | 545, 0x40000000 | uint32(unix.SYS_GETPID)} {
		if got := policyVerdict(t, policy, arch, number); got != unix.SECCOMP_RET_ERRNO|uint32(unix.EACCES) {
			t.Fatal("modeled x32 namespace allowed")
		}
	}
}
