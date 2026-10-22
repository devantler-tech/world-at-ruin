#!/usr/bin/env bash
# Execute the public controller with a synthetic builder, never a real runtime.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() {
  echo "TEST FAIL -- $*" >&2
  exit 1
}
grep -Fxq '        run: bash tools/sandbox-runtime-handoff.test.sh' "$root/.github/workflows/ci.yaml" || fail 'handoff controls are not wired into ordinary CI'
# shellcheck disable=SC2016 # Assert the literal shipping call, not this test's root.
if grep -Fq '"$root/tools/run-sandboxed-trusted-regressions.sh"' "$root/tools/sandbox-godot-isolation.test.sh"; then
  fail 'the same-invocation probe still rebuilds its full-suite runtime'
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fixture="$scratch/fixture"
mkdir -p "$fixture/tools" "$scratch/bin" "$scratch/private" "$scratch/trusted/docs/phase-0" "$scratch/candidate"
printf 'trusted frame\n' >"$scratch/trusted/docs/phase-0/cave-chamber.png"
for helper in run-sandboxed-trusted-regressions.sh sandbox-regression-context.sh sandbox-godot.sh \
  trusted-regression-phase.sh trusted-phase-command.sh trusted-regression-lifecycle.sh process-group-lifecycle.sh; do
  cp "$root/tools/$helper" "$fixture/tools/"
done
cat >"$fixture/tools/build-trusted-regression-runtime.sh" <<'BUILDER'
#!/usr/bin/env bash
set -euo pipefail
printf 'build\n' >>"$HANDOFF_TRACE"
[[ ${BUILDER_EXIT:-0} == 0 ]] || exit "$BUILDER_EXIT"
printf '%s\n' "${BUILDER_IMAGE-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
BUILDER
cat >"$scratch/bin/go" <<'GO'
#!/usr/bin/env bash
set -euo pipefail
[[ $GOTOOLCHAIN == local && $GOWORK == off && "$1 $2" == 'build -o' ]] || exit 90
[[ ${GUARD_EXIT:-0} == 0 ]] || exit "$GUARD_EXIT"
printf '#!/usr/bin/env bash\nexit 0\n' >"$3"
chmod +x "$3"
GO
cat >"$fixture/tools/required-regression-control.sh" <<'CONTROL'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && "$1" == "$HANDOFF_TRUSTED" && "$2" == "$HANDOFF_CANDIDATE" ]] || exit 91
[[ $GODOT_SANDBOX_IMAGE == sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || exit 92
[[ -x $GODOT_SANDBOX_CACHE_GUARD && -d $GODOT_SANDBOX_METADATA && -d $GODOT_SANDBOX_CONTAINERS ]] || exit 93
[[ $(cat "$GODOT_SANDBOX_FRAME") == 'trusted frame' ]] || exit 94
printf 'suite\n' >>"$HANDOFF_TRACE"
if [[ ${SUITE_HOLD:-0} == 1 ]]; then
  sleep 60 &
  child=$!
  printf '%s\n' "$child" >"$SUITE_CHILD"
  trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 130' TERM INT
  : >"$SUITE_READY"
  wait "$child"
fi
exit "${SUITE_EXIT:-0}"
CONTROL
cat >"$scratch/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
# Only real cleanup's absence check is allowed by this fixture.
[[ $1 == ps || $1 == rm ]] || exit 95
DOCKER
chmod +x "$scratch/bin/"* "$fixture/tools/required-regression-control.sh"
export HANDOFF_TRACE="$scratch/trace" HANDOFF_TRUSTED="$scratch/trusted" HANDOFF_CANDIDATE="$scratch/candidate"
run_controller() {
  : >"$HANDOFF_TRACE"
  PATH="$scratch/bin:$PATH" TMPDIR="$scratch/private" \
    GODOT_SANDBOX_IMAGE=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    bash "$fixture/tools/run-sandboxed-trusted-regressions.sh" "$HANDOFF_TRUSTED" "$HANDOFF_CANDIDATE" "$@" >"$scratch/log" 2>&1
}
run_controller || {
  cat "$scratch/log"
  fail 'public controller failed'
}
[[ $(paste -sd, "$HANDOFF_TRACE") == build,suite ]] || fail 'runtime was rebuilt or suite omitted'
[[ -z $(ls -A "$scratch/private") ]] || fail 'successful context was retained'
: >"$HANDOFF_TRACE"
PATH="$scratch/bin:$PATH" TMPDIR="$scratch/private" BUILDER_EXIT=17 \
  bash -c 'source "$1"; run_sandboxed_regression_context "$2" "$3" "$4"' private-context \
  "$fixture/tools/sandbox-regression-context.sh" "$HANDOFF_TRUSTED" "$HANDOFF_CANDIDATE" \
  sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$scratch/log" 2>&1 || fail 'same-invocation context failed'
[[ $(paste -sd, "$HANDOFF_TRACE") == suite ]] || fail 'prebuilt same-invocation context rebuilt or omitted suite'
[[ -z $(ls -A "$scratch/private") ]] || fail 'same-invocation context was retained'
: >"$HANDOFF_TRACE"
PATH="$scratch/bin:$PATH" TMPDIR="$scratch/private" \
  bash -c 'source "$1/trusted-regression-lifecycle.sh"; source "$1/sandbox-regression-context.sh"; trusted_wait run_sandboxed_regression_context "$2" "$3" "$4"' private-owned-child \
  "$fixture/tools" "$HANDOFF_TRUSTED" "$HANDOFF_CANDIDATE" \
  sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$scratch/log" 2>&1 || fail 'owned-child handoff failed'
[[ $(paste -sd, "$HANDOFF_TRACE") == suite && -z $(ls -A "$scratch/private") ]] || fail 'owned-child handoff rebuilt or leaked its context'
for bad_image in latest '' 'sha256:short' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa extra'; do
  if BUILDER_IMAGE="$bad_image" run_controller; then fail 'accepted malformed runtime identity'; fi
  [[ $(paste -sd, "$HANDOFF_TRACE") == build ]] || fail 'invalid runtime reached the suite'
  [[ -z $(ls -A "$scratch/private") ]] || fail 'refused image context was retained'
done
for failure in BUILDER_EXIT=17 GUARD_EXIT=23 SUITE_EXIT=29; do
  status=0
  env "$failure" PATH="$scratch/bin:$PATH" TMPDIR="$scratch/private" \
    bash "$fixture/tools/run-sandboxed-trusted-regressions.sh" "$HANDOFF_TRUSTED" "$HANDOFF_CANDIDATE" >"$scratch/log" 2>&1 || status=$?
  [[ $status == "${failure#*=}" ]] || fail 'builder, guard or suite failure was hidden'
  [[ -z $(ls -A "$scratch/private") ]] || fail 'failed invocation context was retained'
done
if run_controller sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then fail 'public controller accepted an image override'; fi
[[ ! -s $HANDOFF_TRACE ]] || fail 'extra argument reached the builder'
# Signal the public controller PID itself, not its process group. Its cleanup
# must forward cancellation and join the private context's actual owned child.
PATH="$scratch/bin:$PATH" TMPDIR="$scratch/private" SUITE_HOLD=1 \
  SUITE_CHILD="$scratch/child" SUITE_READY="$scratch/ready" \
  bash "$fixture/tools/run-sandboxed-trusted-regressions.sh" "$HANDOFF_TRUSTED" "$HANDOFF_CANDIDATE" >"$scratch/log" 2>&1 &
controller=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ ! -f $scratch/ready ]] || break
  sleep 0.05
done
if [[ ! -f $scratch/ready ]]; then
  kill -TERM "$controller" 2>/dev/null || true
  wait "$controller" 2>/dev/null || true
  fail 'held suite never started'
fi
child=$(cat "$scratch/child")
kill -TERM "$controller"
status=0
wait "$controller" || status=$?
[[ $status == 130 ]] || fail 'controller cancellation was hidden'
! kill -0 "$child" 2>/dev/null || fail 'controller cancellation left the owned child alive'
[[ -z $(ls -A "$scratch/private") ]] || fail 'acknowledged cancellation retained private context'
status=0
bash "$fixture/tools/sandbox-regression-context.sh" "$HANDOFF_TRUSTED" "$HANDOFF_CANDIDATE" ignored >"$scratch/refusal" 2>&1 || status=$?
if [[ $status != 2 ]] || ! grep -Fq 'private host function' "$scratch/refusal"; then
  fail 'private function became a public image entrypoint'
fi
printf 'TEST PASS -- one private runtime identity, no public override, failures and cleanup preserved\n'
