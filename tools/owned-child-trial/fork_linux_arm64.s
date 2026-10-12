//go:build war_child_trial && linux && arm64

#include "textflag.h"

TEXT ·rawFork(SB),NOSPLIT|NOFRAME,$0-8
	MOVD args+0(FP), R19
	MOVD $135, R8
	MOVD $2, R0
	ADD $80, R19, R1
	ADD $72, R19, R2
	MOVD $8, R3
	SVC $0
	MOVD R0, 96(R19)
	CBNZ R0, fatal
	MOVD $220, R8
	MOVD 56(R19), R0
	MOVD ZR, R1
	ADD $48, R19, R2 // clone's parent_tidptr receives the launch-time int32 pidfd.
	MOVD ZR, R3
	MOVD ZR, R4
	SVC $0
	CBZ R0, child
	MOVD R0, 64(R19)
	MOVD $135, R8
	MOVD $2, R0
	ADD $72, R19, R1
	MOVD ZR, R2
	MOVD $8, R3
	SVC $0
	MOVD R0, 104(R19)
	CBNZ R0, fatal
	MOVD $135, R8
	MOVD ZR, R0
	MOVD ZR, R1
	ADD $88, R19, R2
	MOVD $8, R3
	SVC $0
	MOVD R0, 112(R19)
	CBNZ R0, fatal
	MOVD 72(R19), R0
	MOVD 88(R19), R1
	CMP R0, R1
	BNE fatal
	RET
child:
	// No BL/CALL, stack growth, exec or child return is reachable here.
	MOVD 40(R19), R20
	MOVD $57, R8
	MOVD 8(R19), R0
	SVC $0
	MOVD 120(R19), R0
	CMP $2, R0
	BNE status
	MOVD $101, R8 // arm64 has no native pause; use a finite raw nanosleep.
	ADD $128, R19, R0
	MOVD ZR, R1
	SVC $0
status:
	MOVD $56, R8
	MOVD $-100, R0
	MOVD 24(R19), R1
	MOVD $0x80000, R2
	MOVD ZR, R3
	SVC $0
	MOVD R0, R21
	MOVD R0, 0(R20)
	CMP $0, R0
	BLT send
	MOVD $63, R8
	MOVD R21, R0
	ADD $32, R20, R1
	MOVD $3072, R2
	SVC $0
	MOVD R0, 0(R20)
	MOVD $63, R8
	MOVD R21, R0
	ADD $3104, R20, R1
	MOVD $1, R2
	SVC $0
	MOVD R0, 8(R20)
	MOVD $57, R8
	MOVD R21, R0
	SVC $0
	CBZ R0, send
	MOVD R0, 8(R20)
send:
	MOVD $172, R8
	SVC $0
	MOVD R0, 24(R20)
	MOVD $211, R8
	MOVD 0(R19), R0
	MOVD 32(R19), R1
	MOVD $0x4040, R2
	SVC $0
	MOVD R0, 16(R20)
	MOVD $64, R8
	MOVD 16(R19), R0
	MOVD R20, R1
	MOVD $3112, R2
	MOVD 120(R19), R3
	CMP $3, R3
	BNE write
	SUB $1, R2, R2
write:
	SVC $0
	CMP R0, R2
	BNE child_fail
	MOVD 120(R19), R0
	CMP $1, R0
	BNE child_exit
	MOVD $101, R8
	ADD $128, R19, R0
	MOVD ZR, R1
	SVC $0
child_exit:
	MOVD $93, R8
	MOVD ZR, R0
	SVC $0
	B child_exit
child_fail:
	MOVD $93, R8
	MOVD $2, R0
	SVC $0
	B child_fail
fatal:
	MOVD $94, R8
	MOVD $2, R0
	SVC $0
	B fatal

TEXT ·waitFork(SB),NOSPLIT|NOFRAME,$0-24
	MOVD $95, R8
	MOVD $3, R0
	MOVD fd+0(FP), R1
	MOVD info+8(FP), R2
	MOVD $5, R3
	MOVD ZR, R4
	SVC $0
	MOVD R0, ret+16(FP)
	RET
