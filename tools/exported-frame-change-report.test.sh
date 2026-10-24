#!/usr/bin/env bash
# Proves the exported-frame change report renders the base EXPORT rather than
# the editor project, seeds that capture from the base tree, remains advisory
# when the base cannot render, and is wired into the exported capture job.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORTER="$ROOT/tools/exported-frame-change-report.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"

failures=0
SCRATCH_DIR=''

t_fail() {
  printf 'exported frame change report test: FAIL — %s\n' "$1" >&2
  failures=$((failures + 1))
}

cleanup() {
  [ -n "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT

if [ ! -x "$REPORTER" ]; then
  t_fail "production reporter is missing or not executable"
  printf 'exported frame change report test: %d failure(s)\n' "$failures" >&2
  exit 1
fi

SCRATCH_DIR="$(mktemp -d)"
FIXTURE="$SCRATCH_DIR/repo"
FAKE_BIN="$SCRATCH_DIR/bin"
mkdir -p "$FIXTURE/client/recipes" "$FAKE_BIN"

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email t@example.com
git -C "$FIXTURE" config user.name t
printf 'BASE\n' >"$FIXTURE/client/recipes/wanderer.json"
printf '[application]\nconfig/name="fixture"\n' >"$FIXTURE/client/project.godot"
printf '[preset.0]\nname="macOS"\n' >"$FIXTURE/client/export_presets.cfg"
git -C "$FIXTURE" add client
git -C "$FIXTURE" commit -q -m base
BASE_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"

# The head recipe deliberately differs. A reporter that seeds the base capture
# from the head tree makes the fake exported app refuse, which catches the same
# false-diff bug that the editor report already guards against.
printf 'HEAD\n' >"$FIXTURE/client/recipes/wanderer.json"
git -C "$FIXTURE" add client/recipes/wanderer.json
git -C "$FIXTURE" commit -q -m head

cat >"$FAKE_BIN/godot" <<'FAKE_GODOT'
#!/usr/bin/env bash
set -euo pipefail

export_path=''
while [ "$#" -gt 0 ]; do
	if [ "$1" = "--export-release" ]; then
		shift
		[ "$#" -gt 0 ] && shift
		[ "$#" -gt 0 ] || exit 2
		export_path="$1"
		break
	fi
	if [ "$1" = "res://tools/frame_diff.tscn" ]; then
		printf 'DIFF exported_world — changed 45.67%% of pixels, mean |dRGB| 0.0123, max 0.5000\n'
		printf 'UNCOMPARED: head-only.png\n'
		printf 'DIFF PASS (1 frame(s))\n'
		exit 0
	fi
	shift
done

if [ -z "$export_path" ]; then
	printf 'FAKE IMPORT PASS\n'
	exit 0
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/World at Ruin.app/Contents/MacOS/World at Ruin"
mkdir -p "$(dirname "$app")" "$(dirname "$export_path")"
cat > "$app" <<'FAKE_APP'
#!/usr/bin/env bash
set -euo pipefail
if [ "${WAR_SCENARIO:-}" != "first_run" ] &&
		! grep -Fxq BASE "$WAR_SAVE_PATH"; then
	printf 'ERROR: base export received the head recipe\n' >&2
	exit 2
fi
mkdir -p "$WAR_SHOT_DIR"
if [ "${WAR_SCENARIO:-}" = "first_run" ]; then
	dd if=/dev/zero of="$WAR_SHOT_DIR/first_run.png" bs=1024 count=12 2>/dev/null
	printf 'base exported first-run frame\n' > "$WAR_SHOT_DIR/first_run.txt"
	printf '1 first-run vantage written\n'
else
	dd if=/dev/zero of="$WAR_SHOT_DIR/exported_world.png" bs=1024 count=12 2>/dev/null
	printf 'base exported frame\n' > "$WAR_SHOT_DIR/exported_world.txt"
fi
printf 'VOLUMETRICS off\n'
printf 'HOLLOW FOG off\n'
printf 'BOOT_OK vtest\n'
if [ "${FAKE_GODOT_BAD_CAPTURE:-0}" != "1" ]; then
	printf 'CAPTURE PASS\n'
fi
FAKE_APP
chmod +x "$app"
(cd "$stage" && zip -qr "$export_path" "World at Ruin.app")
FAKE_GODOT
chmod +x "$FAKE_BIN/godot"

WORK="$SCRATCH_DIR/report"
if ! render_output="$(
  cd "$FIXTURE" &&
    PATH="$FAKE_BIN:$PATH" "$REPORTER" render-base "$BASE_SHA" "$WORK" 2>&1
)"; then
  t_fail "a valid base export and capture should succeed: $render_output"
fi
if [ ! -s "$WORK/exported-shots-base/exported_world.png" ]; then
  t_fail "render-base did not produce the exported base frame"
fi
if [ ! -f "$WORK/probe_save_base.json" ] ||
  ! grep -Fxq BASE "$WORK/probe_save_base.json"; then
  t_fail "render-base did not seed the capture from the base tree's recipe"
fi
if ! printf '%s\n' "$render_output" | grep -qE 'ADDED CI COST: base export and capture [0-9]+s'; then
  t_fail "render-base did not report the added CI cost"
fi
if ! grep -q 'run_timed 420 env' "$REPORTER"; then
  t_fail "the base world capture timeout no longer clears the measured hosted 296s runtime"
fi
if ! grep -Fq "capture_resolution=\"\${EXPORTED_CAPTURE_RESOLUTION:-1024x576}\"" "$REPORTER"; then
  t_fail "the base exporter does not default to the hosted-safe 16:9 capture resolution"
fi
base_resolution_uses="$(
  grep -Fc -- "\"\$app_path\" --resolution \"\$capture_resolution\"" "$REPORTER" || true
)"
if [ "$base_resolution_uses" -ne 2 ]; then
  t_fail "the base world and first-run captures do not share one pinned resolution"
fi

# Missing CAPTURE PASS is a real base-render failure. The production script
# must return non-zero so the workflow can annotate it through an explicitly
# advisory step rather than quietly treating an empty base as evidence.
BAD_WORK="$SCRATCH_DIR/bad-report"
if (
  cd "$FIXTURE" &&
    FAKE_GODOT_BAD_CAPTURE=1 PATH="$FAKE_BIN:$PATH" \
      "$REPORTER" render-base "$BASE_SHA" "$BAD_WORK"
) >/dev/null 2>&1; then
  t_fail "render-base accepted an exported app that never reported CAPTURE PASS"
fi

HEAD_SHOTS="$SCRATCH_DIR/head-shots"
mkdir -p "$HEAD_SHOTS"
dd if=/dev/zero of="$HEAD_SHOTS/exported_world.png" bs=1024 count=12 2>/dev/null

if ! report_output="$(
  cd "$FIXTURE" &&
    PATH="$FAKE_BIN:$PATH" "$REPORTER" report "$WORK" "$HEAD_SHOTS" 2>&1
)"; then
  t_fail "the reporting phase must remain advisory: $report_output"
fi
if ! printf '%s\n' "$report_output" | grep -q 'DIFF PASS'; then
  t_fail "report did not run the real frame-diff entry point"
fi
if ! printf '%s\n' "$report_output" |
  grep -q 'DIFF exported_world.*changed 45.67%'; then
  t_fail "report did not preserve the exported frame's non-zero measurement"
fi
if ! printf '%s\n' "$report_output" |
  grep -q '::warning::some exported-client frames carry no base comparison'; then
  t_fail "report did not surface UNCOMPARED exported frames as an annotation"
fi

if ! missing_output="$(
  cd "$FIXTURE" &&
    PATH="$FAKE_BIN:$PATH" "$REPORTER" report "$SCRATCH_DIR/missing" "$HEAD_SHOTS" 2>&1
)"; then
  t_fail "a missing base must warn without failing the required job"
fi
if ! printf '%s\n' "$missing_output" |
  grep -q '::warning::no exported base frames'; then
  t_fail "a missing base produced no explicit warning"
fi

# Transported comparison data must bind this exact integration, base, run and
# attempt. A failed base remains advisory, but its partial images are not proof.
fixture_head=$(git -C "$FIXTURE" rev-parse HEAD)
source_mode() {
  GITHUB_SHA="$fixture_head" BASE_SHA="$BASE_SHA" GITHUB_RUN_ID=42 \
    GITHUB_RUN_ATTEMPT="${SOURCE_TEST_ATTEMPT:-1}" PATH="$FAKE_BIN:$PATH" \
    "$REPORTER" "$@"
}
if ! source_mode record-source "$WORK" success success >"$SCRATCH_DIR/source.log" 2>&1; then
  t_fail "the reporter cannot bind portable comparison evidence to its source"
else
  if ! source_mode report-source "$WORK" "$HEAD_SHOTS" >"$SCRATCH_DIR/source.log" 2>&1 ||
    ! grep -q 'DIFF PASS' "$SCRATCH_DIR/source.log"; then
    t_fail "source-bound transported evidence did not reach the real comparison"
  fi
  if SOURCE_TEST_ATTEMPT=2 source_mode report-source "$WORK" "$HEAD_SHOTS" >"$SCRATCH_DIR/source.log" 2>&1; then
    t_fail "a prior-attempt artifact was accepted as current comparison evidence"
  fi
  cp "$WORK/source.json" "$SCRATCH_DIR/bound-source.json"
  for mutation in \
    '.integration="wrong"' '.base="wrong"' '.run="43"' '.attempt="2"' \
    '.status="unknown"' '.extra="unreviewed"' 'del(.version)'; do
    jq "$mutation" "$SCRATCH_DIR/bound-source.json" >"$WORK/source.json"
    if source_mode report-source "$WORK" "$HEAD_SHOTS" >"$SCRATCH_DIR/source.log" 2>&1; then
      t_fail "accepted ambiguous comparison source: $mutation"
    fi
  done
  for failed_phase in install render; do
    if [ "$failed_phase" = install ]; then outcomes=(failure success); else outcomes=(success failure); fi
    source_mode record-source "$WORK" "${outcomes[@]}"
    if ! source_mode report-source "$WORK" "$HEAD_SHOTS" >"$SCRATCH_DIR/source.log" 2>&1 ||
      ! grep -q '::warning::' "$SCRATCH_DIR/source.log" || grep -q 'DIFF PASS' "$SCRATCH_DIR/source.log"; then
      t_fail "a failed $failed_phase either blocked the advisory result or compared partial images"
    fi
  done
fi

# The behavior above earns no value if the exported capture job never calls it.
exported_block="$(yq '.jobs."frame-capture-exported-head"' "$WORKFLOW")"
base_block="$(yq '.jobs."frame-capture-exported-base"' "$WORKFLOW")"
report_block="$(yq '.jobs."frame-capture-exported"' "$WORKFLOW")"
export_gate="$(sed -n '/# Export-affecting paths get a THIRD/,/# A FOURTH gate/p' "$WORKFLOW")"
if ! printf '%s\n' "$base_block" |
  grep -q 'tools/exported-frame-change-report\.sh render-base'; then
  t_fail "frame-capture-exported does not render the base through the tested reporter"
fi
if ! printf '%s\n' "$report_block" |
  grep -q 'tools/exported-frame-change-report\.sh report'; then
  t_fail "frame-capture-exported does not publish the tested change report"
fi
if ! printf '%s\n' "$exported_block" | grep -q 'fetch-depth: 0'; then
  t_fail "frame-capture-exported cannot reach the PR base because its checkout is shallow"
fi
if ! printf '%s\n' "$exported_block" |
  grep -Fq 'EXPORTED_CAPTURE_RESOLUTION: 1024x576'; then
  t_fail "frame-capture-exported does not pin a hosted-safe 16:9 resolution"
fi
head_resolution_uses="$(
  yq -r '.runs.steps[] | select(has("run")) | .run' "$ROOT/.github/actions/capture-exported-head/action.yaml" |
    grep -Fc -- "--resolution \"\${EXPORTED_CAPTURE_RESOLUTION}\"" || true
)"
if [ "$head_resolution_uses" -ne 3 ]; then
  t_fail "the exported world, preview, and first-run captures do not share one pinned resolution"
fi
if ! printf '%s\n' "$base_block" |
  grep -q 'ADDED CI COST: base Godot and templates install'; then
  t_fail "the added Godot and export-template installation cost is not recorded"
fi

# Actual fork/join source: neither capture waits on the other, and the stable
# terminal check cannot pass without the HEAD result and source-bound BASE data.
yq -o=json '.' "$WORKFLOW" >"$SCRATCH_DIR/workflow.json"
yq -o=json '.' "$ROOT/.github/actions/capture-exported-head/action.yaml" >"$SCRATCH_DIR/component.json"
jq --slurpfile component "$SCRATCH_DIR/component.json" '. + {exported_head_component:$component[0]}' \
  "$SCRATCH_DIR/workflow.json" >"$SCRATCH_DIR/parallel.json"
parallel_contract() {
  # shellcheck disable=SC2016 # jq owns these bound variables and literal expressions.
  jq -e '
		.jobs["frame-capture-exported-head"] as $head |
		.jobs["frame-capture-exported-base"] as $base |
		.jobs["frame-capture-exported"] as $join |
		.exported_head_component as $component |
		all([$head,$base,$join][]; (has("continue-on-error") or has("defaults") or has("permissions"))|not) and
		all([$head,$base,$join][]; .steps[0].with=={ref:"${{ github.sha }}","fetch-depth":0,"persist-credentials":false}) and
		$head.needs==["detect-visual-changes","client-export-macos"] and
		$base.needs==["detect-visual-changes"] and
		$head.if=="needs.detect-visual-changes.outputs.export_affecting == '\''true'\''" and
		$base.if==$head.if and $head.env.EXPORTED_CAPTURE_RESOLUTION=="1024x576" and $base.env==$head.env and
		$head["runs-on"]=="macos-15" and $base["runs-on"]=="macos-15" and
		all($head.steps[];(has("continue-on-error") or has("if"))|not) and
		$head.steps[-1].uses=="./.github/actions/capture-exported-head" and
		$head.steps[-1].with=={"archive-sha256":"${{ needs.client-export-macos.outputs.archive-sha256 }}"} and
		all($component.runs.steps[];(has("continue-on-error") or has("if"))|not) and
		($component.runs.steps[]|select(.id=="upload").with.name)=="exported-head-${{ github.sha }}-${{ github.run_attempt }}" and
		($component.runs.steps[]|select(.id=="upload").with["if-no-files-found"])=="error" and
		$base.steps[1].id=="base-engine" and $base.steps[1]["continue-on-error"]==true and
		$base.steps[2].id=="base-capture" and $base.steps[2]["continue-on-error"]==true and
		$base["timeout-minutes"]==15 and
		$base.steps[1]["timeout-minutes"]==2 and $base.steps[2]["timeout-minutes"]==9 and
		$base.steps[2].if=="steps.base-engine.outcome == '\''success'\''" and
		$base.steps[3]["timeout-minutes"]==1 and $base.steps[4]["timeout-minutes"]==1 and
		$base.steps[2].env=={BASE_SHA:"${{ github.event.pull_request.base.sha }}"} and
		$base.steps[3].env=={BASE_SHA:"${{ github.event.pull_request.base.sha }}",ENGINE_OUTCOME:"${{ steps.base-engine.outcome }}",CAPTURE_OUTCOME:"${{ steps.base-capture.outcome }}"} and
		($base.steps[3].run|contains(" record-source ")) and
		$base.steps[4].with.name=="exported-base-${{ github.sha }}-${{ github.run_attempt }}" and
		$base.steps[4].with["if-no-files-found"]=="error" and
		$join.needs==["detect-visual-changes","frame-capture-exported-head","frame-capture-exported-base"] and
		$join.if=="always() && needs.detect-visual-changes.result == '\''success'\'' && needs.detect-visual-changes.outputs.export_affecting == '\''true'\''" and
		$join["runs-on"]=="ubuntu-latest" and
		all($join.steps[];(has("continue-on-error") or has("if"))|not) and
		$join.steps[1].env=={HEAD_RESULT:"${{ needs.frame-capture-exported-head.result }}",BASE_RESULT:"${{ needs.frame-capture-exported-base.result }}"} and
		$join.steps[1].run=="[[ \"$HEAD_RESULT\" == success && \"$BASE_RESULT\" == success ]]" and
		$join.steps[2].with.name=="exported-head-${{ github.sha }}-${{ github.run_attempt }}" and
		$join.steps[3].with.name=="exported-base-${{ github.sha }}-${{ github.run_attempt }}" and
		$join.steps[6].env=={BASE_SHA:"${{ github.event.pull_request.base.sha }}"} and
		($join.steps[6].run|contains(" report-source ")) and
		$join.steps[-1].with.name=="exported-frames-${{ github.event.pull_request.head.sha }}" and
		$join.steps[-1].with["if-no-files-found"]=="error"
	' "$1" >/dev/null
}
if ! parallel_contract "$SCRATCH_DIR/parallel.json"; then
  t_fail "exported HEAD and BASE do not join through the source-bound terminal check"
else
  for mutation in \
    '.jobs["frame-capture-exported-base"].needs += ["client-export-macos"]' \
    '.jobs["frame-capture-exported-head"]["continue-on-error"]=true' \
    '.jobs["frame-capture-exported-head"].steps[1]["continue-on-error"]=true' \
    '(.exported_head_component.runs.steps[]|select(.id=="upload")).with.name="unbound-head"' \
    '.jobs["frame-capture-exported-base"].steps[2].env.BASE_SHA="wrong"' \
    'del(.jobs["frame-capture-exported-base"].steps[1]["timeout-minutes"])' \
    '.jobs["frame-capture-exported-base"].steps[2]["timeout-minutes"]=15' \
    'del(.jobs["frame-capture-exported-base"].steps[2].if)' \
    'del(.jobs["frame-capture-exported-base"].steps[3]["timeout-minutes"])' \
    'del(.jobs["frame-capture-exported-base"].steps[4]["timeout-minutes"])' \
    '.jobs["frame-capture-exported-base"].steps[4].with.name="unbound-base"' \
    '.jobs["frame-capture-exported"].if="true"' \
    '.jobs["frame-capture-exported"].needs |= .[:-1]' \
    '.jobs["frame-capture-exported"].steps[1].env.HEAD_RESULT="success"' \
    '.jobs["frame-capture-exported"].steps[2].with.name="unbound-head"' \
    '.jobs["frame-capture-exported"].steps[6].run="true"' \
    '.jobs["frame-capture-exported"].steps[-1].with["if-no-files-found"]="ignore"'; do
    jq "$mutation" "$SCRATCH_DIR/parallel.json" >"$SCRATCH_DIR/changed.json"
    if parallel_contract "$SCRATCH_DIR/changed.json"; then t_fail "accepted parallel mutation $mutation"; fi
  done
fi
if ! printf '%s\n' "$export_gate" |
  grep -Fq '^client/(project\.godot|export_presets\.cfg)$' ||
  ! printf '%s\n' "$export_gate" | grep -q 'export_affecting=true'; then
  t_fail "an export-presets-only change does not select the exported capture and comparison"
fi
if ! grep -q './tools/exported-frame-change-report.test.sh' "$WORKFLOW"; then
  t_fail "the reporter regression test is not wired into ci.yaml"
fi

if [ "$failures" -ne 0 ]; then
  printf 'exported frame change report test: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'exported frame change report test: OK\n'
