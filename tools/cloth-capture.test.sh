#!/usr/bin/env bash
# Exercise the actual capture loop with synthetic files, then refuse missing
# evidence and unsafe workflow routing. Real rendered images remain hosted proof.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
capture="$root/tools/capture-cloth-evidence.sh"
[[ -f "$capture" ]] || {
  echo 'TEST FAIL -- cloth capture is still serialized in source frames' >&2
  exit 1
}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# Preserve the specific refused capture or routing condition in the test failure.
fail() {
  echo "TEST FAIL -- $*" >&2
  exit 1
}
mkdir "$scratch/bin"
cat >"$scratch/bin/godot" <<'ENGINE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '--path client res://tools/frame_capture.tscn' && $WAR_SCENARIO == ragged_cloth ]] || exit 90
case "$WAR_RAGGED_CLOTH_DETAIL:$WAR_RAGGED_CLOTH_DRAPE" in
  0:0) mode=off; detail=false; drape=false ;;
  1:0) mode=on; detail=true; drape=false ;;
  0:1) mode=drape; detail=false; drape=true ;;
  1:1) mode=both; detail=true; drape=true ;;
  *) exit 91 ;;
esac
[[ $WAR_RAGGED_WRAP_REFINEMENT == "$WAR_RAGGED_CLOTH_DRAPE" &&
  $WAR_SHOT_DIR == "$RUNNER_TEMP/shots/ragged-cloth/$mode" &&
  $WAR_SAVE_PATH == "$RUNNER_TEMP/cloth_${mode}_absent.json" &&
  $WAR_VAULT_PATH == "$RUNNER_TEMP/cloth_${mode}_vault.json" &&
  $WAR_BOOT_RECOVERY_PATH == "$RUNNER_TEMP/cloth_${mode}_recovery.json" ]] || exit 92
printf '%s\n' "$mode" >>"$RUNNER_TEMP/calls"
for file in cloth_{front,rear,profile,gameplay}{,_repeat,_fold_off,_seam_off,_flat,_mask,_geometry_flat,_geometry_mask,_unrefined,_unrefined_mask}.{png,txt}; do
  [[ "$file" != "${MISSING_FILE:-}" ]] || continue
  printf 'synthetic evidence\n' >"$WAR_SHOT_DIR/$file"
done
[[ ${MISSING_MARKER:-} == pass ]] || printf 'CAPTURE PASS — ragged cloth: front, rear, profile and gameplay; detail=%s drape=%s\n' "$detail" "$drape"
[[ ${MISSING_MARKER:-} == refinement ]] || printf 'WRAP REFINEMENT — enabled=%s\n' "$drape"
[[ ${MISSING_MARKER:-} == boot ]] || printf '%s\n' "${BOOT_VERDICT:-BOOT_OK v0.0.0 — world built, 2 people and 1 hounds in the Reach}"
[[ -z ${RENDER_ERROR:-} ]] || printf '%s\n' "$RENDER_ERROR"
exit "${ENGINE_EXIT:-0}"
ENGINE
chmod +x "$scratch/bin/godot"
# Exercise the shipped loop in a fresh disposable worker directory.
run_capture() {
  local dir="$scratch/run-$case_number"
  mkdir "$dir"
  (cd "$dir" && PATH="$scratch/bin:$PATH" RUNNER_TEMP="$dir" bash "$capture" "$@") >"$scratch/log" 2>&1
}
case_number=0
run_capture || fail 'complete synthetic capture failed'
[[ $(paste -sd, "$scratch/run-0/calls") == off,on,drape,both ]] || fail 'mode set changed'
[[ $(find "$scratch/run-0/shots" -name '*.png' | wc -l) -eq 160 &&
$(find "$scratch/run-0/shots" -name '*.txt' | wc -l) -eq 160 ]] || fail 'complete evidence set changed'
# An earlier success must never fill a missing file in a later capture.
if (cd "$scratch/run-0" && PATH="$scratch/bin:$PATH" RUNNER_TEMP="$scratch/run-0" \
  MISSING_FILE=cloth_front.png bash "$capture" off) >"$scratch/reused.log" 2>&1; then
  fail 'accepted stale evidence from an earlier mode capture'
fi
[[ $(paste -sd, "$scratch/run-0/calls") == off,on,drape,both ]] ||
  fail 'reused evidence reached the engine instead of refusing without overwriting'
[[ -s "$scratch/run-0/shots/ragged-cloth/off/cloth_front.png" ]] ||
  fail 'refusing reused evidence removed the earlier capture'
for kind in directory file symlink; do
  reused="$scratch/preexisting-$kind"
  mkdir -p "$reused/shots/ragged-cloth"
  output="$reused/shots/ragged-cloth/off"
  case "$kind" in
  directory) mkdir "$output" ;;
  file) printf 'retained evidence\n' >"$output" ;;
  symlink) ln -s "$scratch/run-0/shots/ragged-cloth/off" "$output" ;;
  esac
  if (cd "$reused" && PATH="$scratch/bin:$PATH" RUNNER_TEMP="$reused" bash "$capture" off) >"$scratch/reused.log" 2>&1; then
    fail "accepted an existing $kind as fresh evidence"
  fi
  [[ ! -e "$reused/calls" ]] || fail 'existing output reached the engine'
  [[ -e "$output" || -L "$output" ]] || fail 'refused output was deleted'
done
# Every matrix worker captures its entire mode, and no neighbouring mode. The
# four fixed workers therefore preserve the same complete Cartesian product.
for mode in off on drape both; do
  case_number=$((case_number + 1))
  run_capture "$mode" || fail "$mode worker failed"
  [[ $(cat "$scratch/run-$case_number/calls") == "$mode" ]] || fail 'worker ran the wrong mode'
  [[ $(find "$scratch/run-$case_number/shots" -name '*.png' | wc -l) -eq 40 &&
  $(find "$scratch/run-$case_number/shots" -name '*.txt' | wc -l) -eq 40 ]] || fail 'incomplete worker evidence'
  case_number=$((case_number + 1))
  if MISSING_FILE=cloth_gameplay_unrefined_mask.txt run_capture "$mode"; then fail "$mode worker accepted missing evidence"; fi
done
for mode in '' missing 'off,on' '../off'; do
  case_number=$((case_number + 1))
  if run_capture "$mode"; then fail 'accepted an invalid worker mode'; fi
  [[ ! -e "$scratch/run-$case_number/calls" ]] || fail 'invalid worker reached the engine'
done
case_number=$((case_number + 1))
if run_capture off on; then fail 'accepted more than one worker mode'; fi
[[ ! -e "$scratch/run-$case_number/calls" ]] || fail 'extra argument reached the engine'
# Cover each view, arm and file type independently, without copying production
# loop structure. Omitting any one assertion must make a negative control pass.
missing_files=(cloth_rear.png cloth_profile.png cloth_gameplay.png cloth_front.txt)
for arm in '' _repeat _fold_off _seam_off _flat _mask _geometry_flat _geometry_mask _unrefined _unrefined_mask; do
  missing_files+=("cloth_front$arm.png")
done
for file in "${missing_files[@]}"; do
  case_number=$((case_number + 1))
  if MISSING_FILE="$file" run_capture; then fail "accepted missing $file"; fi
done
for marker in pass refinement boot; do
  case_number=$((case_number + 1))
  if MISSING_MARKER="$marker" run_capture; then fail "accepted missing $marker verdict"; fi
done
for verdict in \
  'NOT_BOOT_OK v0.0.0 — world built, 2 people and 1 hounds in the Reach' \
  'BOOT_OK' \
  'prefix BOOT_OK v0.0.0 — world built, 2 people and 1 hounds in the Reach' \
  'BOOT_OK v0.0.0 — world built, 2 people and 1 hounds in the Reach suffix'; do
  case_number=$((case_number + 1))
  if BOOT_VERDICT="$verdict" run_capture off; then fail 'accepted a near-miss boot verdict'; fi
done
for error in 'SCRIPT ERROR: synthetic refusal' 'SHADER ERROR: synthetic refusal'; do
  case_number=$((case_number + 1))
  if RENDER_ERROR="$error" run_capture; then fail 'accepted a rendering failure after PASS'; fi
done
case_number=$((case_number + 1))
if ENGINE_EXIT=29 run_capture; then fail 'accepted a failed engine after PASS'; fi
case_number=$((case_number + 1))
RENDER_ERROR='timeout waiting for fence' run_capture || fail 'existing recovered driver retry was rejected'

# Run the real installer against command doubles. A bad download or checksum
# must stop before extraction or privileged installation; no host paths change.
mkdir "$scratch/setup-bin"
cat >"$scratch/setup-bin/command-double" <<'SETUP'
#!/usr/bin/env bash
set -euo pipefail
case "${0##*/}" in
  curl)
    [[ "$*" == "-fsSL -o godot.zip https://github.com/godotengine/godot-builds/releases/download/4.7.1-stable/Godot_v4.7.1-stable_macos.universal.zip" ]] || exit 91
    echo download >>"$SETUP_TRACE"
    exit "${DOWNLOAD_EXIT:-0}"
    ;;
  shasum)
    [[ "$*" == '-a 512 -c -' ]] || exit 92
    [[ $(cat) == 'expected-checksum  godot.zip' ]] || exit 93
    echo checksum >>"$SETUP_TRACE"
    exit "${CHECKSUM_EXIT:-0}"
    ;;
  unzip)
    [[ "$*" == '-q godot.zip' ]] || exit 94
    echo extract >>"$SETUP_TRACE"
    ;;
  sudo)
    case "$*" in
      'tee /usr/local/bin/godot')
        wrapper=$(cat)
        [[ "$wrapper" == "$(printf '#!/bin/sh\nexec "%s/Godot.app/Contents/MacOS/Godot" "$@"\n' "$PWD")" ]] || exit 95
        echo wrapper >>"$SETUP_TRACE"
        ;;
      'chmod +x /usr/local/bin/godot') echo executable >>"$SETUP_TRACE" ;;
      *) exit 96 ;;
    esac
    ;;
  *) exit 97 ;;
esac
SETUP
chmod +x "$scratch/setup-bin/command-double"
for command in curl shasum unzip sudo; do ln -s command-double "$scratch/setup-bin/$command"; done
# Substitute transport and installation commands without touching the host installation.
run_setup() {
  : >"$scratch/setup-trace"
  (cd "$scratch" && PATH="$scratch/setup-bin:$PATH" SETUP_TRACE="$scratch/setup-trace" \
    GODOT_VERSION=4.7.1 GODOT_MACOS_SHA512=expected-checksum bash "$root/tools/install-ci-macos-godot.sh")
}
run_setup || fail 'verified installer failed'
[[ $(paste -sd, "$scratch/setup-trace") == download,checksum,extract,wrapper,executable ]] || fail 'installer skipped or reordered verification'
if CHECKSUM_EXIT=17 run_setup; then fail 'installed after checksum rejection'; fi
[[ $(paste -sd, "$scratch/setup-trace") == download,checksum ]] || fail 'checksum failure reached installation'
if DOWNLOAD_EXIT=23 run_setup; then fail 'installed after download failure'; fi
[[ $(paste -sd, "$scratch/setup-trace") == download ]] || fail 'download failure reached verification'

yq -o=json . "$root/.github/workflows/ci.yaml" >"$scratch/workflow.json"
# Execute the shipping path detector with real commits, one helper change at a
# time. A regex-presence assertion alone cannot prove the required job runs.
jq -r '.jobs["detect-visual-changes"].steps[] | select(.id=="check") | .run' \
  "$scratch/workflow.json" >"$scratch/detect.sh"
for helper in tools/capture-cloth-evidence.sh tools/install-ci-macos-godot.sh \
  tools/source-capture-inputs.sh tools/source-evidence-package.sh tools/source-evidence-conditions.sh \
  tools/render-source-base.sh tools/report-source-frames.sh tools/source-evidence/main.go \
  .github/actions/capture-source/action.yaml; do
  fixture="$scratch/detect-${helper//\//-}"
  mkdir -p "$fixture/tools"
  git -C "$fixture" init -q -b main
  git -C "$fixture" config user.name fixture
  git -C "$fixture" config user.email fixture@example.invalid
  git -C "$fixture" config commit.gpgsign false
  git -C "$fixture" config core.hooksPath /dev/null
  cp "$root/tools/pr-diff-base.sh" "$fixture/tools/pr-diff-base.sh"
  git -C "$fixture" add tools/pr-diff-base.sh
  git -C "$fixture" commit -qm base
  base=$(git -C "$fixture" rev-parse HEAD)
  mkdir -p "$(dirname "$fixture/$helper")"
  printf '# changed helper\n' >"$fixture/$helper"
  git -C "$fixture" add "$helper"
  git -C "$fixture" commit -qm helper-change
  head=$(git -C "$fixture" rev-parse HEAD)
  (cd "$fixture" && BASE_SHA="$base" HEAD_SHA="$head" GITHUB_OUTPUT="$fixture/output" \
    bash -e -o pipefail "$scratch/detect.sh") >"$scratch/detect.log" 2>&1 || fail "$helper classification failed"
  grep -Fxq visual=true "$fixture/output" || fail "$helper change skipped real capture"
done
# Check the exact required worker matrix and artifact contract after parsing real YAML.
admit() {
  jq -e '
    .jobs as $jobs | $jobs["frame-capture-cloth"] as $cloth |
    $cloth.name=="Frame capture (cloth evidence, ${{ matrix.mode }})" and
    $cloth.needs==["detect-visual-changes"] and
    $cloth.if==$jobs["frame-capture-head"].if and
    $cloth.if=="needs.detect-visual-changes.outputs.visual == '\''true'\''" and
    $cloth["runs-on"]=="macos-latest" and $cloth["timeout-minutes"]==15 and
    ($cloth|keys)==["if","name","needs","runs-on","steps","strategy","timeout-minutes"] and
    $cloth.strategy=={"fail-fast":false,matrix:{mode:["off","on","drape","both"]}} and
    ($cloth.steps|length)==5 and
    all($cloth.steps[]; (has("if") or has("continue-on-error"))|not) and
    $cloth.steps[0]=={uses:"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",with:{"fetch-depth":0,"persist-credentials":false}} and
    $cloth.steps[1].run=="bash tools/install-ci-macos-godot.sh" and
    $cloth.steps[2].run=="godot --headless --editor --quit --path client 2>&1 | tee import.log" and
    $cloth.steps[3].env=={CLOTH_MODE:"${{ matrix.mode }}"} and
    $cloth.steps[3].run=="bash tools/capture-cloth-evidence.sh \"$CLOTH_MODE\"" and
    $cloth.steps[4].uses=="actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9" and
    $cloth.steps[4].with.name=="cloth-frames-${{ matrix.mode }}-${{ github.sha }}" and
    $cloth.steps[4].with["if-no-files-found"]=="error" and
    ($cloth.steps[4].with.path|split("\n")|map(select(length>0))|sort)==[
      "${{ runner.temp }}/shots/ragged-cloth/${{ matrix.mode }}/*.png",
      "${{ runner.temp }}/shots/ragged-cloth/${{ matrix.mode }}/*.txt",
      "cloth-${{ matrix.mode }}.log"] and
    ($jobs["ci-required-checks"].needs|index("frame-capture-cloth"))!=null and
    ($jobs["ci-required-checks"].steps[-1].with["job-results"]|contains("${{ needs.frame-capture-cloth.result }}")) and
    any($jobs["client-ordinary"].steps[];.run?=="bash tools/cloth-capture.test.sh") and
    any($jobs["frame-capture-head"].steps[];(.uses? // "" | test("^devantler-tech/world-at-ruin/\\.github/actions/capture-source@[0-9a-f]{40}$"))) and
    (any($jobs["frame-capture"].steps[];(.run? // "")|contains("ragged_cloth"))|not)
  ' "$1" >/dev/null
}
admit "$scratch/workflow.json" || fail 'required parallel capture contract changed'
for mutation in \
  'del(.jobs["frame-capture-cloth"])' \
  '.jobs["frame-capture-cloth"].if="false"' \
  '.jobs["frame-capture-cloth"].needs=["frame-capture"]' \
  '.jobs["frame-capture-cloth"]["continue-on-error"]=true' \
  '.jobs["frame-capture-cloth"]["timeout-minutes"]=30' \
  '.jobs["frame-capture-cloth"].strategy["fail-fast"]=true' \
  '.jobs["frame-capture-cloth"].strategy.matrix.mode=["off","on","drape"]' \
  '.jobs["frame-capture-cloth"].strategy.matrix.mode=["off","on","drape","drape"]' \
  '.jobs["frame-capture-cloth"].strategy.matrix.exclude=[{mode:"both"}]' \
  '.jobs["frame-capture-cloth"].steps[0].with["persist-credentials"]=true' \
  '.jobs["frame-capture-cloth"].steps[0].with.ref="main"' \
  '.jobs["frame-capture-cloth"].steps[1].run="true"' \
  '.jobs["frame-capture-cloth"].steps[2].run="true"' \
  '.jobs["frame-capture-cloth"].steps[3].if="false"' \
  '.jobs["frame-capture-cloth"].steps[3].run="true"' \
  '.jobs["frame-capture-cloth"].steps[3].env.CLOTH_MODE="off"' \
  '.jobs["frame-capture-cloth"].steps[4].with.path="cloth-off.log"' \
  '.jobs["frame-capture-cloth"].steps[4].with.name="unbound-frames"' \
  '.jobs["frame-capture-cloth"].steps[4].with["if-no-files-found"]="ignore"' \
  '.jobs["ci-required-checks"].needs|=map(select(.!="frame-capture-cloth"))' \
  '.jobs["ci-required-checks"].steps[-1].with["job-results"]|=sub("frame-capture-cloth";"frame-capture")'; do
  jq "$mutation" "$scratch/workflow.json" >"$scratch/mutant.json"
  if admit "$scratch/mutant.json"; then fail "accepted routing mutation $mutation"; fi
done
printf 'TEST PASS -- complete cloth evidence, refusal controls and required parallel routing\n'
