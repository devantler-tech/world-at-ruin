#!/usr/bin/env bash
# Audit the actual ABI0 child trampoline on each native build, not its source label.
set -euo pipefail
[[ $# == 1 && -f $1 ]] || {
  echo 'usage: audit-fork-assembly.sh <built-test-executable>' >&2
  exit 2
}
dump=$(go tool objdump -s 'ownedchild.*rawFork\.abi0$|owned-child-trial\.rawFork\.abi0$' "$1")
[[ -n "$dump" ]] || {
  echo 'fork assembly symbol missing' >&2
  exit 1
}
if printf '%s\n' "$dump" | grep -Eq '[[:space:]](CALL|BL|BLR)[[:space:]]|morestack|[[:space:]](PUSH|POP)|[[:space:]](ADD|SUB|MOV)[A-Z]*[[:space:]].*, (RSP|SP)([[:space:]]|$)'; then
  echo 'fork trampoline calls or changes its stack' >&2
  exit 1
fi
if printf '%s\n' "$dump" | grep -Eq 'MOV[A-Z]*[[:space:]]+[$](0x3b|0x142|59|322), AX|MOV[A-Z]*[[:space:]]+[$](0xdd|0x119|221|281), R8'; then
  echo 'fork trampoline contains an exec syscall number' >&2
  exit 1
fi
returns=$(printf '%s\n' "$dump" | grep -Ec '[[:space:]]RET([[:space:]]|$)')
[[ $returns == 1 ]] || {
  echo 'fork trampoline must have one parent-only return' >&2
  exit 1
}
printf '%s\n' "$dump"
echo 'FORK ASSEMBLY AUDIT PASS: fixed raw syscall branch; no calls or stack growth; sole parent return'
