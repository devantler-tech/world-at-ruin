#!/usr/bin/env bash
# Exercise actual entry supervision, not a copy of its signal logic.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="${1:-$root/tools/run-client-test.sh}"
phase_runner="$root/tools/trusted-regression-phase.sh"
kinds=(phase runner nested parallel watchdog)
causes=(timeout INT TERM capture)
if [[ ${1:-} == --capture-phase ]]; then
  phase_runner="${2:?baseline phase required}"
  runner="$root/tools/run-client-test.sh"
  kinds=(phase)
  causes=(capture)
fi
if [[ ${1:-} == --nested-int ]]; then runner="$root/tools/run-client-test.sh"; kinds=(nested); causes=(INT); fi
tmp="$(mktemp -d)"
canary=''
real_ps="$(command -v ps)"
cleanup() {
  local record owned_pid
  for record in "$tmp"/*/engine* "$tmp"/*/child*; do
    [[ -s $record ]] || continue
    owned_pid="$(cat "$record")"
    kill -KILL "$owned_pid" 2>/dev/null || true
  done
  if [[ -n $canary ]]; then kill "$canary" 2>/dev/null || true; wait "$canary" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
sleep 600 & canary=$!
mkdir -p "$tmp/fixture/client/tests" "$tmp/bin"
: > "$tmp/fixture/client/tests/held.tscn"
: > "$tmp/fixture/client/tests/boot_ledger_boot_test.tscn"
cat > "$tmp/bin/godot" <<'ENGINE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" > "$FAKE_ENGINE"
printf '%s\n' "$$" > "$FAKE_ENGINE.$$"
trap '' TERM
bash -c 'trap "" TERM; printf "%s\n" "$$" > "$FAKE_CHILD"; printf "%s\n" "$$" > "$FAKE_CHILD.$$"; while :; do sleep 0.1; done' &
while :; do sleep 0.1; done
ENGINE
chmod +x "$tmp/bin/godot"
cat > "$tmp/capture-window" <<'CAPTURE'
# A test-owned DEBUG trap signals exactly before the owner captures $!.
set -T
trap 'if [[ "$0" == "$CAPTURE_TARGET" && "$BASH_COMMAND" == "$CAPTURE_COMMAND" && ! -e "$CAPTURE_ONCE" ]]; then
  : > "$CAPTURE_ONCE"
  for ((capture_try=0;capture_try<100;capture_try++)); do
    [[ -s $FAKE_ENGINE && -s $FAKE_CHILD ]] && break
    sleep 0.05
  done
  if [[ "$CAPTURE_COMMAND" == "watchdog_sleep_pid=\$!" ]]; then
    printf "%s\n" "$!" > "$FAKE_WATCHDOG.$!"
    kill -TERM "$BASHPID"
  fi
  kill -TERM "$$"
fi' DEBUG
CAPTURE
terminal() {
  local snapshot
  snapshot="$("$real_ps" -axo pid=,stat=)" || return 2
  awk -v pid="$1" '$1 == pid && $2 !~ /^Z/ {live=1} END {exit live ? 1 : 0}' <<< "$snapshot"
}
for kind in "${kinds[@]}"; do
  for cause in "${causes[@]}"; do
    if [[ $kind == watchdog && $cause != capture ]]; then continue; fi
    echo "CONTROL START -- $kind/$cause"
    case_start=$SECONDS
    case_root="$tmp/$kind-$cause"
    mkdir -p "$case_root/state"
    export FAKE_ENGINE="$case_root/engine" FAKE_CHILD="$case_root/child"
    export FAKE_WATCHDOG="$case_root/watchdog"
    unset BASH_ENV CAPTURE_TARGET CAPTURE_COMMAND CAPTURE_ONCE
    export TMPDIR="$case_root/state" PATH="$tmp/bin:$PATH"
    export WAR_TRUSTED_TERMINATION_SECONDS=1 WAR_CLIENT_STEP_SECONDS=1 RUN_CLIENT_TEST_TIMEOUT_SECONDS=1
    if [[ $cause != timeout ]]; then WAR_CLIENT_STEP_SECONDS=60; RUN_CLIENT_TEST_TIMEOUT_SECONDS=60; fi
    if [[ $kind == nested || $kind == parallel ]]; then
      WAR_TRUSTED_TERMINATION_SECONDS=5
      RUN_CLIENT_TEST_TIMEOUT_SECONDS=60
    fi
    if [[ $kind == phase ]]; then
      printf 'exec "%s/bin/godot"\n' "$tmp" > "$case_root/step.sh"
      entry=(bash "$root/tools/client-proof-step.sh" "$case_root/step.sh")
      if [[ $cause == capture ]]; then entry=(bash "$phase_runner" 'ordinary client step' bash "$case_root/step.sh"); fi
    else
      entry=(bash "$runner" held)
    fi
    if [[ $kind == nested ]]; then
      printf 'cd "%s/fixture"\nexec bash "%s" held\n' "$tmp" "$runner" > "$case_root/step.sh"
      if [[ ${1:-} == --nested-int || ${CLIENT_PROOF_TRACE:-0} == 1 ]]; then printf 'cd "%s/fixture"\nexec bash -x "%s" held\n' "$tmp" "$runner" > "$case_root/step.sh"; fi
      entry=(bash "$root/tools/client-proof-step.sh" "$case_root/step.sh")
    fi
    if [[ $kind == parallel ]]; then
      printf 'cd "%s/fixture"\nexec bash "%s/tools/parallel-save-isolation.test.sh"\n' "$tmp" "$root" > "$case_root/step.sh"
      entry=(bash "$root/tools/client-proof-step.sh" "$case_root/step.sh")
    fi
    if [[ $cause == capture ]]; then
      export BASH_ENV="$tmp/capture-window" CAPTURE_ONCE="$case_root/captured"
      export CAPTURE_TARGET="$runner" CAPTURE_COMMAND='test_pid=$!'
      if [[ $kind == phase ]]; then CAPTURE_TARGET="$phase_runner"; CAPTURE_COMMAND='pid=$!'; fi
      if [[ $kind == parallel ]]; then CAPTURE_TARGET="$root/tools/parallel-save-isolation.test.sh"; CAPTURE_COMMAND='local first_pid=$!'; fi
      if [[ $kind == watchdog ]]; then CAPTURE_COMMAND='watchdog_sleep_pid=$!'; fi
    fi
    set -m
    if [[ $kind == runner || $kind == watchdog ]]; then
      (cd "$tmp/fixture"; exec "${entry[@]}") > "$case_root/output" 2>&1 &
    else
      "${entry[@]}" > "$case_root/output" 2>&1 &
    fi
    entry_pid=$!
    set +m
    for ((attempt=0; attempt<100; attempt++)); do
      if [[ -s $FAKE_ENGINE && -s $FAKE_CHILD ]]; then
        if [[ $kind != parallel || $cause == capture ]]; then break; fi
        engines=("$FAKE_ENGINE".*)
        children=("$FAKE_CHILD".*)
        [[ ${#engines[@]} == 2 && ${#children[@]} == 2 ]] && break
      fi
      sleep 0.05
    done
    [[ -s $FAKE_ENGINE && -s $FAKE_CHILD ]] || { cat "$case_root/output"; exit 1; }
    if [[ $kind == parallel && $cause != capture && (${#engines[@]} != 2 || ${#children[@]} != 2) ]]; then
      echo 'FAIL: parallel cancellation did not launch both engines and descendants' >&2; exit 1
    fi
    if [[ $cause != timeout && $cause != capture ]]; then kill "-$cause" "$entry_pid"; fi
    status=0
    wait "$entry_pid" || status=$?
    if ((SECONDS-case_start > 15)); then cat "$case_root/output"; echo "FAIL: $kind/$cause exceeded its finite cleanup allowance" >&2; exit 1; fi
    if [[ $status == 0 ]]; then echo "FAIL: $kind accepted $cause" >&2; exit 1; fi
    if [[ $cause == capture && ! -f $CAPTURE_ONCE ]]; then echo 'FAIL: capture-window signal did not execute' >&2; exit 1; fi
    for record in "$FAKE_ENGINE".* "$FAKE_CHILD".* "$FAKE_WATCHDOG".*; do
      [[ -f $record ]] || continue
      if ! terminal "$(cat "$record")"; then
        cat "$case_root/output"
        "$real_ps" -axo pid=,ppid=,pgid=,stat=,command= | awk -v engine="$(cat "$record")" '$1 == engine || $2 == engine'
        echo "FAIL: $kind/$cause returned before owned engine and descendant exited" >&2; exit 1
      fi
    done
    kill -0 "$canary"
    if compgen -G "$TMPDIR/run-client-test.*" >/dev/null; then
      echo 'FAIL: acknowledged runner cleanup retained ordinary scratch' >&2; exit 1
    fi
    echo "CONTROL PASS -- $kind/$cause"
  done
done
unset BASH_ENV CAPTURE_TARGET CAPTURE_COMMAND CAPTURE_ONCE
if [[ ${1:-} == --capture-phase || ${1:-} == --nested-int ]]; then echo 'TEST PASS -- targeted phase cancellation owns the launched child'; exit 0; fi
# Inspection failure cannot certify absence or permit scratch removal.
case_root="$tmp/unreadable"
mkdir -p "$case_root/state"
export FAKE_ENGINE="$case_root/engine" FAKE_CHILD="$case_root/child" TMPDIR="$case_root/state"
export RUN_CLIENT_TEST_TIMEOUT_SECONDS=60
printf '#!/bin/sh\nexit 2\n' > "$tmp/bin/ps"
chmod +x "$tmp/bin/ps"
set -m
(cd "$tmp/fixture"; exec bash "$runner" held) > "$case_root/output" 2>&1 &
entry_pid=$!
set +m
for ((attempt=0; attempt<100; attempt++)); do
  [[ -s $FAKE_ENGINE && -s $FAKE_CHILD ]] && break
  sleep 0.05
done
[[ -s $FAKE_ENGINE && -s $FAKE_CHILD ]] || { cat "$case_root/output"; exit 1; }
kill -TERM "$entry_pid"
status=0
wait "$entry_pid" || status=$?
if [[ $status != 2 ]] || ! compgen -G "$TMPDIR/run-client-test.*" >/dev/null; then
  echo 'FAIL: unreadable exit observation was accepted or discarded its private state' >&2; exit 1
fi
terminal "$(cat "$FAKE_ENGINE")" && terminal "$(cat "$FAKE_CHILD")"
kill -0 "$canary"
echo 'TEST PASS -- ordinary timeout, INT and TERM retire engines and descendants; canary survives'
