//go:build war_child_trial && linux && amd64

#include "textflag.h"

// Fixed forkArgs offsets are checked against the compiled Go layout.
TEXT ·rawFork(SB),NOSPLIT|NOFRAME,$0-8
	MOVQ args+0(FP), R12
	MOVQ $14, AX // rt_sigprocmask(SIG_SETMASK, blocked, saved, 8)
	MOVQ $2, DI
	LEAQ 80(R12), SI
	LEAQ 72(R12), DX
	MOVQ $8, R10
	SYSCALL
	MOVQ AX, 96(R12)
	TESTQ AX, AX
	JNZ fatal
	MOVQ $56, AX // clone(flags, NULL, &pidfd, NULL, NULL)
	MOVQ 56(R12), DI
	XORQ SI, SI
	LEAQ 48(R12), DX
	XORQ R10, R10
	XORQ R8, R8
	SYSCALL
	TESTQ AX, AX
	JZ child
	MOVQ AX, 64(R12)
	MOVQ $14, AX
	MOVQ $2, DI
	LEAQ 72(R12), SI
	XORQ DX, DX
	MOVQ $8, R10
	SYSCALL
	MOVQ AX, 104(R12)
	TESTQ AX, AX
	JNZ fatal
	MOVQ $14, AX // Read back before any Go return, even after clone failure.
	XORQ DI, DI
	XORQ SI, SI
	LEAQ 88(R12), DX
	MOVQ $8, R10
	SYSCALL
	MOVQ AX, 112(R12)
	TESTQ AX, AX
	JNZ fatal
	MOVQ 72(R12), AX
	CMPQ AX, 88(R12)
	JNE fatal
	RET
child:
	// This branch never calls or returns into Go, changes stack or executes exec.
	MOVQ 40(R12), R13
	MOVQ $3, AX
	MOVQ 8(R12), DI
	SYSCALL
	CMPQ 120(R12), $2
	JNE status
	MOVQ $35, AX // Finite five-second delay, bounded externally by exact cleanup.
	LEAQ 128(R12), DI
	XORQ SI, SI
	SYSCALL
status:
	MOVQ $257, AX
	MOVQ $-100, DI
	MOVQ 24(R12), SI
	MOVQ $0x80000, DX // O_RDONLY|O_CLOEXEC
	XORQ R10, R10
	SYSCALL
	MOVQ AX, R14
	MOVQ AX, 0(R13)
	TESTQ AX, AX
	JS send
	MOVQ $0, AX
	MOVQ R14, DI
	LEAQ 32(R13), SI
	MOVQ $3072, DX
	SYSCALL
	MOVQ AX, 0(R13)
	MOVQ $0, AX
	MOVQ R14, DI
	LEAQ 3104(R13), SI
	MOVQ $1, DX
	SYSCALL
	MOVQ AX, 8(R13)
	MOVQ $3, AX
	MOVQ R14, DI
	SYSCALL
	TESTQ AX, AX
	JZ send
	MOVQ AX, 8(R13)
send:
	MOVQ $39, AX
	SYSCALL
	MOVQ AX, 24(R13)
	MOVQ $46, AX
	MOVQ 0(R12), DI
	MOVQ 32(R12), SI
	MOVQ $0x4040, DX // MSG_DONTWAIT|MSG_NOSIGNAL; no shared fcntl mutation.
	SYSCALL
	MOVQ AX, 16(R13)
	MOVQ $1, AX
	MOVQ 16(R12), DI
	MOVQ R13, SI
	MOVQ $3112, DX
	CMPQ 120(R12), $3
	JNE write
	SUBQ $1, DX // Actual incomplete-record control.
write:
	SYSCALL // One atomic nonblocking pipe write below PIPE_BUF.
	CMPQ AX, DX
	JNE child_fail
	CMPQ 120(R12), $1
	JNE child_exit
	MOVQ $35, AX
	LEAQ 128(R12), DI
	XORQ SI, SI
	SYSCALL
child_exit:
	MOVQ $60, AX
	XORQ DI, DI
	SYSCALL
	JMP child_exit
child_fail:
	MOVQ $60, AX
	MOVQ $2, DI
	SYSCALL
	JMP child_fail
fatal:
	MOVQ $231, AX // Uncertain parent signal state cannot return into Go.
	MOVQ $2, DI
	SYSCALL
	JMP fatal

TEXT ·waitFork(SB),NOSPLIT|NOFRAME,$0-24
	MOVQ $247, AX
	MOVQ $3, DI // P_PIDFD
	MOVQ fd+0(FP), SI
	MOVQ info+8(FP), DX
	MOVQ $5, R10 // WEXITED|WNOHANG
	XORQ R8, R8
	SYSCALL
	MOVQ AX, ret+16(FP)
	RET
