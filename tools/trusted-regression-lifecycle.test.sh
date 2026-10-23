#!/usr/bin/env bash
# Exercise actual controller waits; failed cleanup is persistent evidence.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lifecycle="${1:-$root/tools/trusted-regression-lifecycle.sh}"
tmp="$(mktemp -d)"
child=''
second_child=''
# Retire the test's direct child and remove only its invocation-owned fixtures.
cleanup() {
  if [[ -n $child ]]; then
    kill -KILL "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  if [[ -n $second_child ]]; then
    kill -KILL "$second_child" 2>/dev/null || true
    wait "$second_child" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
# shellcheck source=tools/trusted-regression-lifecycle.sh
source "$lifecycle"
# A synthetic unknown join must not release ownership. These functions shadow
# process builtins only inside this subshell; no real unrelated PID is signaled.
if ! (
  kill() { return 1; }
  # shellcheck disable=SC2329 # The sourced cleanup function invokes this mock.
  wait() { return 127; }
  trusted_parallel_pids=(123)
  verdict=0
  trusted_stop_child || verdict=$?
  [[ $verdict == 2 && $trusted_cleanup_uncertain == 1 ]]
); then
  echo 'TEST FAIL -- unknown parallel child join released cleanup ownership' >&2
  exit 1
fi
status=0
trusted_wait bash -c 'exit 17' || status=$?
[[ $status == 17 && $trusted_cleanup_uncertain == 0 ]]
status=0
trusted_wait bash -c 'exit 2' || status=$?
[[ $status == 2 && $trusted_cleanup_uncertain == 1 ]]
status=0
trusted_stop_child || status=$?
[[ $status == 2 ]]
# A later successful wait cannot erase the refusal.
trusted_wait true
status=0
trusted_stop_child || status=$?
[[ $status == 2 ]]
trusted_cleanup_uncertain=0
cat >"$tmp/child" <<'CHILD'
#!/usr/bin/env bash
trap 'exit 2' TERM
touch "$READY"
while :; do sleep 0.1; done
CHILD
READY="$tmp/ready" bash "$tmp/child" &
child=$!
trusted_active_pid=$child
for ((i = 0; i < 100; i++)); do
  [[ -f $tmp/ready ]] && break
  sleep 0.05
done
[[ -f $tmp/ready ]]
status=0
trusted_stop_child || status=$?
child=''
[[ $status == 2 && $trusted_cleanup_uncertain == 1 && -z $trusted_active_pid ]]
trusted_cleanup_uncertain=0
# The observed phase may use all five seconds plus two seconds after KILL.
cat >"$tmp/child" <<'CHILD'
#!/usr/bin/env bash
trap 'sleep 7.2; touch "$SETTLED"; exit 130' TERM
touch "$READY"
while :; do sleep 0.1; done
CHILD
rm "$tmp/ready"
READY="$tmp/ready" SETTLED="$tmp/settled" bash "$tmp/child" &
child=$!
trusted_active_pid=$child
for ((i = 0; i < 100; i++)); do
  [[ -f $tmp/ready ]] && break
  sleep 0.05
done
[[ -f $tmp/ready ]]
trusted_stop_child
child=''
[[ -f $tmp/settled && $trusted_cleanup_uncertain == 0 ]]
# Both children may consume their complete grace concurrently, never one
# eight-second wait after another. Cancellation must reach every owned handle.
rm "$tmp/ready" "$tmp/settled"
READY="$tmp/ready" SETTLED="$tmp/settled" bash "$tmp/child" &
child=$!
READY="$tmp/second-ready" SETTLED="$tmp/second-settled" bash "$tmp/child" &
second_child=$!
for ((i = 0; i < 100; i++)); do
  [[ -f $tmp/ready && -f $tmp/second-ready ]] && break
  sleep 0.05
done
[[ -f $tmp/ready && -f $tmp/second-ready ]]
trusted_parallel_pids=("$child" "$second_child")
started=$SECONDS
trusted_stop_child
child=''
second_child=''
[[ -f $tmp/settled && -f $tmp/second-settled && $trusted_cleanup_uncertain == 0 ]]
[[ $((SECONDS - started)) -lt 11 && ${#trusted_parallel_pids[@]} == 0 ]]
# GNU timeout replaces a cancellation status; the phase must preserve the
# child's separate private cleanup verdict after an actual join.
rm "$tmp/ready"
READY="$tmp/ready" TMPDIR="$tmp" bash "$root/tools/trusted-regression-phase.sh" 'ordinary client step' bash -c 'trap "exit 2" TERM; touch "$READY"; while :; do sleep 0.1; done' >"$tmp/phase-refused" 2>&1 &
child=$!
for ((i = 0; i < 100; i++)); do
  [[ -f $tmp/ready ]] && break
  sleep 0.05
done
[[ -f $tmp/ready ]]
kill -TERM "$child"
status=0
wait "$child" || status=$?
child=''
[[ $status == 2 ]]
compgen -G "$tmp/trusted-regression-phase.*" >/dev/null
echo 'TEST PASS -- controller preserves cleanup refusals and the complete exit-observation budget'
