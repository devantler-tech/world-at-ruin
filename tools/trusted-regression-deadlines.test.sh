#!/usr/bin/env bash
# Held setup phases must fail promptly without judging unexecuted scenes.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/work/client/tests" "$tmp/work/server/wire" "$tmp/work/.github/workflows" "$tmp/metadata" "$tmp/containers"
printf 'source
' >"$tmp/work/server/wire/wire.go"
printf 'source
' >"$tmp/work/.github/workflows/ci.yaml"
printf 'frame
' >"$tmp/frame"
printf 'asset
' >"$tmp/work/client/icon.svg"
printf '#!/bin/bash
exit 0
' >"$tmp/bin/godot"
cp "$tmp/bin/godot" "$tmp/bin/cache-guard"
cat >"$tmp/bin/docker" <<'DOCKER'
#!/bin/bash
set -eu
if [ "$1" = build ]; then
  for ((index=1;index<=$#;index++)); do
    if [ "${!index}" = --tag ]; then next=$((index+1)); printf '%s\n' "${!next}" >"$FAKE_TAG"; fi
  done
  if [ "${FAKE_HOLD:-}" != build ]; then exit 0; fi
fi
if [ "$1" = build ] || [ "$1" = run ] || { [ "$1" = image ] && [ "${FAKE_HOLD:-}" = inspect ]; }; then
  if [ "$1" = run ]; then
    shift
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --name ]; then printf owned >"$FAKE_CONTAINERS/$2"; fi
      shift
    done
  fi
  bash -c 'trap "" TERM; sleep 60' &
  child=$!
  printf '%s
' "$child" >"$FAKE_CHILD"
  wait "$child"
elif [ "$1" = image ]; then
  test "$3" = "$(cat "$FAKE_TAG")"
  printf 'sha256:%064d
' 0
elif [ "$1" = rm ]; then
  rm -f "$FAKE_CONTAINERS/$3"
elif [ "$1" = ps ]; then
  if [ "${FAKE_CLEANUP_UNKNOWN:-}" = 1 ]; then exit 17; fi
  exit 0
else
  exit 2
fi
DOCKER
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" FAKE_CONTAINERS="$tmp/containers" FAKE_CHILD="$tmp/child" FAKE_TAG="$tmp/tag"
GODOT_SANDBOX_IMAGE="sha256:$(printf '%064d' 0)"
export GODOT_SANDBOX_IMAGE
export GODOT_SANDBOX_CACHE_GUARD="$tmp/bin/cache-guard" GODOT_SANDBOX_METADATA="$tmp/metadata" GODOT_SANDBOX_FRAME="$tmp/frame"
export WAR_TRUSTED_BUILD_SECONDS=1 WAR_TRUSTED_INSPECT_SECONDS=1 WAR_TRUSTED_IMPORT_SECONDS=1 WAR_TRUSTED_PROBE_SECONDS=1 WAR_TRUSTED_TERMINATION_SECONDS=1
failures=0
printf unrelated >"$tmp/containers/unrelated"
for phase in build inspect import probe; do
  export FAKE_HOLD="$phase"
  if [ "$phase" = build ] || [ "$phase" = inspect ]; then
    command=(bash "$root/tools/build-trusted-regression-runtime.sh")
    expected='runtime build/pull'
    if [ "$phase" = inspect ]; then expected='runtime image inspection'; fi
  elif [ "$phase" = import ]; then
    command=(bash "$root/tools/sandbox-godot.sh" --headless --editor --quit --path client)
    expected='editor import'
  else
    mkdir -p "$tmp/work/client/.godot"
    printf sidecar >"$tmp/metadata/icon.svg.import"
    command=(bash "$root/tools/sandbox-godot.sh" --headless --path client)
    expected='sandbox execution'
  fi
  start=$SECONDS
  status=0
  (cd "$tmp/work"; timeout --kill-after=1s 6s "${command[@]}") >"$tmp/$phase.log" 2>&1 || status=$?
  elapsed=$((SECONDS-start))
  if [ "$status" -eq 0 ] || [ "$elapsed" -gt 4 ] || ! grep -Fq "$expected timed out" "$tmp/$phase.log"; then
    echo "TEST FAIL -- held $phase did not report a bounded phase failure (status=$status elapsed=$elapsed)" >&2
    failures=$((failures+1))
  fi
  if grep -Eq 'TEST PASS|Ran .*trusted regression' "$tmp/$phase.log"; then
    echo 'TEST FAIL -- setup failure fabricated a scene verdict' >&2
    failures=$((failures+1))
  fi
  if [ -f "$tmp/child" ] && kill -0 "$(cat "$tmp/child")" 2>/dev/null; then
    state="$(ps -o stat= -p "$(cat "$tmp/child")" || true)"
    case "$state" in Z*) ;; *) echo 'TEST FAIL -- setup descendant survived' >&2; failures=$((failures+1));; esac
  fi
done
[ "$failures" -eq 0 ] || exit 1
test "$(cat "$tmp/containers/unrelated")" = unrelated
test "$(ls -A "$tmp/containers")" = unrelated
echo 'TEST PASS -- held build, import and probe fail within deadline and release descendants'

# A controller should return promptly when its child acknowledges cancellation.
cat >"$tmp/fast-child" <<'FAST'
#!/bin/bash
trap 'exit 130' TERM
while :; do :; done
FAST
chmod +x "$tmp/fast-child"
source "$root/tools/trusted-regression-lifecycle.sh"
"$tmp/fast-child" &
trusted_active_pid=$!
sleep 0.2
start=$SECONDS
trusted_stop_child
test "$((SECONDS-start))" -le 2
# A supervisor needs the full five-second grace plus a small scheduling margin.
cat >"$tmp/slow-child" <<'SLOW'
#!/bin/bash
trap 'sleep 5.2; touch "$FAKE_SETTLED"; exit 130' TERM
while :; do :; done
SLOW
chmod +x "$tmp/slow-child"
FAKE_SETTLED="$tmp/settled" "$tmp/slow-child" &
trusted_active_pid=$!
sleep 0.2
trusted_stop_child
test -f "$tmp/settled"
echo 'TEST PASS -- controller stops promptly after acknowledgment and preserves supervisor grace'

FAKE_HOLD=none bash "$root/tools/build-trusted-regression-runtime.sh" >"$tmp/image"
test "$(cat "$tmp/image")" = "$GODOT_SANDBOX_IMAGE"
# Cancellation must propagate while a long phase is still running.
sleep 60 &
unrelated=$!
trap 'kill "$unrelated" 2>/dev/null || true; wait "$unrelated" 2>/dev/null || true; rm -rf "$tmp"' EXIT
WAR_TRUSTED_PROBE_SECONDS=60 bash "$root/tools/trusted-regression-phase.sh" 'sandbox execution' bash -c 'sleep 60 & echo $! >"$FAKE_CHILD"; wait' >"$tmp/cancel.log" 2>&1 &
phase_pid=$!
sleep 1
kill -TERM "$phase_pid"
status=0
wait "$phase_pid" || status=$?
test "$status" -eq 130
grep -Fq 'sandbox execution cancelled' "$tmp/cancel.log"
kill -0 "$unrelated"
if kill -0 "$(cat "$tmp/child")" 2>/dev/null; then
  state="$(ps -o stat= -p "$(cat "$tmp/child")" || true)"
  case "$state" in Z*) ;; *) echo 'TEST FAIL -- cancelled descendant survived' >&2; exit 1;; esac
fi
# Invalid or widened budgets cannot execute the supplied command.
for budget in 0 invalid 901; do
  if WAR_TRUSTED_BUILD_SECONDS="$budget" bash "$root/tools/trusted-regression-phase.sh" 'runtime build/pull' touch "$tmp/unexecuted" >"$tmp/invalid.log" 2>&1; then exit 1; fi
done
test ! -e "$tmp/unexecuted"
# An ordinary failed phase keeps its actual status.
status=0
bash "$root/tools/trusted-regression-phase.sh" 'runtime image inspection' bash -c 'exit 17' || status=$?
test "$status" -eq 17
# Signal the actual sandbox launcher, not only its phase supervisor.
(cd "$tmp/work"; WAR_TRUSTED_PROBE_SECONDS=60 exec bash "$root/tools/sandbox-godot.sh" --headless --path client) >"$tmp/sandbox-cancel.log" 2>&1 &
launcher=$!
sleep 1
start=$SECONDS
kill -TERM "$launcher"
status=0
wait "$launcher" || status=$?
test "$status" -eq 130
test "$((SECONDS-start))" -le 12
test "$(ls -A "$tmp/containers")" = unrelated
kill -0 "$unrelated"
# Cleanup must retain its owned record when Docker absence is unknown.
mkdir "$tmp/records"
record="war-trusted-$(printf '%032d' 0)"
printf owned >"$tmp/records/$record"
status=0
FAKE_CLEANUP_UNKNOWN=1 bash "$root/tools/trusted-regression-phase.sh" 'sandbox cleanup' bash "$root/tools/trusted-regression-phase.sh" --cleanup-containers "$tmp/records" >"$tmp/unknown.log" 2>&1 || status=$?
test "$status" -ne 0
test -f "$tmp/records/$record"
grep -Fq 'could not verify absence' "$tmp/unknown.log"
bash "$root/tools/trusted-regression-phase.sh" 'sandbox cleanup' bash "$root/tools/trusted-regression-phase.sh" --cleanup-containers "$tmp/records"
test ! -e "$tmp/records/$record"
echo 'TEST PASS -- cancellation releases descendants, preserves unrelated work and rejects widened deadlines'
echo 'TEST PASS -- unknown container cleanup fails and retains private ownership evidence'
