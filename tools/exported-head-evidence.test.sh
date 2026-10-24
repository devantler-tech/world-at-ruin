#!/usr/bin/env bash
# Bind the real native capture component to its producer, then execute its
# archive/source admission and renderer failure guards. Not renderer proof.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() {
  printf 'exported HEAD evidence: %s\n' "$*" >&2
  exit 1
}
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$work/ci.json"
jq -e '.jobs["client-export-macos"].outputs["archive-sha256"] == "${{ steps.export-client.outputs.archive-sha256 }}"' "$work/ci.json" >/dev/null ||
  fail 'the native producer does not bind its actual archive bytes'
yq -o=json '.' "$root/.github/actions/capture-exported-head/action.yaml" >"$work/action.json"
jq -e '
  .jobs["frame-capture-exported-head"] |
  .needs==["detect-visual-changes","client-export-macos"] and
  ."runs-on"=="macos-15" and ."timeout-minutes"==15 and
  .if=="needs.detect-visual-changes.outputs.export_affecting == '\''true'\''" and
  (.steps|length)==3 and
  .steps[2]=={name:"Capture the exact exported HEAD",uses:"./.github/actions/capture-exported-head",
    with:{"archive-sha256":"${{ needs.client-export-macos.outputs.archive-sha256 }}"}}
' "$work/ci.json" >/dev/null || fail 'the native capture call changed source, selection or deadline'
jq -e '
  .inputs|keys==["archive-sha256"]
' "$work/action.json" >/dev/null || fail 'unexpected capture interface'
admit_action() {
  jq -e '
    .runs.using=="composite" and
    [.runs.steps[].id]==["prepare","world","previews","first-run","files","conditions","upload","complete"] and
    all(.runs.steps[]; (has("if") or has("continue-on-error"))|not) and
    all(.runs.steps[]|select(has("run")); .shell=="bash" and (has("working-directory")|not)) and
    .outputs.captured.value=="${{ steps.complete.outputs.captured }}" and
    .runs.steps[0].env.EXPECTED_ARCHIVE_SHA256=="${{ inputs.archive-sha256 }}" and
    .runs.steps[6].uses=="actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9" and
    .runs.steps[6].with.name=="exported-head-${{ github.sha }}-${{ github.run_attempt }}" and
    .runs.steps[6].with["if-no-files-found"]=="error" and
    .runs.steps[7].run=="printf '\''captured=true\\n'\'' >> \"$GITHUB_OUTPUT\""
  ' "$1" >/dev/null
}
admit_action "$work/action.json" || fail 'incomplete component or false completion boundary'
for mutation in \
  'del(.runs.steps[]|select(.id=="first-run"))' \
  '(.runs.steps[]|select(.id=="world")).if="false"' \
  '(.runs.steps[]|select(.id=="previews"))["continue-on-error"]=true' \
  '(.runs.steps[]|select(.id=="upload")).with["if-no-files-found"]="ignore"' \
  '(.runs.steps[]|select(.id=="upload")).with.name="stale"' \
  '.runs.steps|=reverse'; do
  jq "$mutation" "$work/action.json" >"$work/broken.json"
  if admit_action "$work/broken.json"; then fail "accepted $mutation"; fi
done
jq -r '.runs.steps[0].run' "$work/action.json" >"$work/prepare.sh"
fixture="$work/fixture"
mkdir -p "$fixture/build" "$fixture/client/recipes" "$work/temp"
git -C "$fixture" init -qb main
git -C "$fixture" config user.name fixture
git -C "$fixture" config user.email fixture@example.invalid
git -C "$fixture" config commit.gpgsign false
printf 'source\n' >"$fixture/source.txt"
printf 'build/\n' >"$fixture/.gitignore"
printf '{}\n' >"$fixture/client/recipes/wanderer.json"
git -C "$fixture" add source.txt .gitignore client/recipes/wanderer.json
git -C "$fixture" commit -qm fixture
head=$(git -C "$fixture" rev-parse HEAD)
bundle="$work/bundle/World at Ruin.app/Contents/MacOS"
mkdir -p "$bundle"
cat >"$bundle/World at Ruin" <<'APP'
#!/usr/bin/env bash
set -euo pipefail
mode=${FAKE_CAPTURE_MODE:-ok}
[[ "$mode" == no-pass ]] || printf 'CAPTURE PASS\n'
[[ "$mode" == no-boot ]] || printf 'BOOT_OK fixture\n'
printf 'VOLUMETRICS off\nHOLLOW FOG off\n'
case "$mode" in
  error) printf 'ERROR: renderer fault\n' ;;
  fence) printf 'ERROR: timeout waiting for fence\n' ;;
  partial) exit 17 ;;
esac
APP
chmod +x "$bundle/World at Ruin"
(cd "$work/bundle" && zip -qr "$fixture/build/WorldAtRuin.zip" .)
cp "$fixture/build/WorldAtRuin.zip" "$work/pristine.zip"
digest=$(shasum -a 256 "$fixture/build/WorldAtRuin.zip")
digest=${digest%% *}
# Run the actual producer under GitHub's unspecified-shell bash -e behavior.
# Plausible output followed by a nonzero export must not publish a digest.
jq -r '.jobs["client-export-macos"].steps[]|select(.id=="export-client").run' "$work/ci.json" >"$work/producer.sh"
mkdir "$work/bin"
cat >"$work/bin/godot" <<'GODOT'
#!/usr/bin/env bash
set -euo pipefail
[[ "$4" == "$PWD/build/WorldAtRuin.zip" ]] || exit 88
if [[ "$PRODUCER_MODE" == empty ]]; then
  : >"$4"
else
  cp "$ARCHIVE_FIXTURE" "$4"
fi
printf 'export fixture finished\n'
[[ "$PRODUCER_MODE" != partial ]] || exit 17
GODOT
chmod +x "$work/bin/godot"
for mode in ok empty partial; do
  producer_root="$work/producer-$mode"
  mkdir "$producer_root"
  status=0
  (cd "$producer_root" && PATH="$work/bin:$PATH" PRODUCER_MODE="$mode" \
    ARCHIVE_FIXTURE="$work/pristine.zip" GITHUB_OUTPUT="$producer_root/output" \
    bash -e "$work/producer.sh") >"$work/producer-$mode.log" 2>&1 || status=$?
  if [[ "$mode" == ok ]]; then
    if [[ "$status" != 0 ]] || ! grep -Fxq "archive-sha256=$digest" "$producer_root/output"; then
      fail 'producer did not bind the actual successful archive'
    fi
  else
    [[ "$status" != 0 && ! -s "$producer_root/output" ]] ||
      fail "$mode producer published validation after incomplete export"
  fi
done
run_prepare() {
  (cd "$fixture" && GITHUB_SHA="$head" RUNNER_TEMP="$work/temp" \
    EXPECTED_ARCHIVE_SHA256="$digest" bash -euo pipefail "$work/prepare.sh") >"$work/log" 2>&1
}
run_prepare || fail "valid actual archive/source was rejected: $(<"$work/log")"
printf 'changed archive\n' >>"$fixture/build/WorldAtRuin.zip"
if run_prepare; then fail 'changed archive was admitted'; fi
cp "$work/pristine.zip" "$fixture/build/WorldAtRuin.zip"
original_digest=$digest
digest=0000000000000000000000000000000000000000000000000000000000000000
if run_prepare; then fail 'wrong producer digest was admitted'; fi
digest=$original_digest
printf 'dirty\n' >>"$fixture/source.txt"
if run_prepare; then fail 'dirty capture source was admitted'; fi
printf 'source\n' >"$fixture/source.txt"
original_head=$head
head=0000000000000000000000000000000000000000
if run_prepare; then fail 'another integration source was admitted'; fi
head=$original_head
mkdir "$work/temp/exported-shots"
if run_prepare; then fail 'stale capture outputs were admitted'; fi
rmdir "$work/temp/exported-shots"
mv "$fixture/build/WorldAtRuin.zip" "$work/archive"
ln -s "$work/archive" "$fixture/build/WorldAtRuin.zip"
if run_prepare; then fail 'linked archive was admitted'; fi
rm "$fixture/build/WorldAtRuin.zip"
cp "$work/pristine.zip" "$fixture/build/WorldAtRuin.zip"
jq -r '.runs.steps[]|select(.id=="world").run' "$work/action.json" >"$work/world.sh"
jq -r '.runs.steps[]|select(.id=="files").run' "$work/action.json" >"$work/files.sh"
for mode in ok fence no-pass no-boot error partial; do
  case_root="$work/case-$mode"
  cp -R "$fixture" "$case_root"
  mkdir "$case_root/temp"
  status=0
  (cd "$case_root" && FAKE_CAPTURE_MODE="$mode" RUNNER_TEMP="$case_root/temp" \
    EXPORTED_CAPTURE_RESOLUTION=1024x576 bash -euo pipefail "$work/world.sh") >"$work/world-$mode.log" 2>&1 || status=$?
  case "$mode" in
    ok | fence)
      [[ "$status" == 0 ]] || fail "$mode capture protocol rejected: $(<"$work/world-$mode.log")"
      # PASS/BOOT markers alone are never file evidence.
      if (cd "$case_root" && RUNNER_TEMP="$case_root/temp" bash -euo pipefail "$work/files.sh") >"$work/files.log" 2>&1; then
        fail 'capture markers without PNGs were admitted'
      fi
      ;;
    no-pass)
      if [[ "$status" == 0 ]] || ! grep -q 'did not report PASS' "$work/world-$mode.log"; then fail 'missing capture verdict was not rejected'; fi
      ;;
    no-boot)
      if [[ "$status" == 0 ]] || ! grep -q 'never reached BOOT_OK' "$work/world-$mode.log"; then fail 'partial boot was not rejected'; fi
      ;;
    error)
      if [[ "$status" == 0 ]] || ! grep -q 'errors during the exported-client capture' "$work/world-$mode.log"; then fail 'renderer error was not rejected'; fi
      ;;
    partial) [[ "$status" == 17 ]] || fail 'plausible partial output hid a failed renderer' ;;
  esac
done
jq -r '.jobs["detect-visual-changes"].steps[]|select(.id=="check").run' "$work/ci.json" >"$work/detect.sh"
for changed_path in .github/actions/capture-exported-head/action.yaml tools/exported-head-evidence.test.sh README.md; do
  selection_root=$(mktemp -d "$work/selection.XXXXXX")
  mkdir "$selection_root/tools"
  git -C "$selection_root" init -qb main
  git -C "$selection_root" config user.name fixture
  git -C "$selection_root" config user.email fixture@example.invalid
  git -C "$selection_root" config commit.gpgsign false
  cp "$root/tools/pr-diff-base.sh" "$selection_root/tools/pr-diff-base.sh"
  git -C "$selection_root" add tools/pr-diff-base.sh
  git -C "$selection_root" commit -qm base
  base=$(git -C "$selection_root" rev-parse HEAD)
  mkdir -p "$selection_root/$(dirname "$changed_path")"
  printf 'fixture change\n' >"$selection_root/$changed_path"
  git -C "$selection_root" add "$changed_path"
  git -C "$selection_root" commit -qm candidate
  candidate=$(git -C "$selection_root" rev-parse HEAD)
  (cd "$selection_root" && BASE_SHA="$base" HEAD_SHA="$candidate" GITHUB_OUTPUT="$selection_root/output" \
    bash -e -o pipefail "$work/detect.sh") >"$work/selection.log" 2>&1 ||
    fail "shipping selection failed for $changed_path"
  selected=true
  [[ "$changed_path" != README.md ]] || selected=false
  for field in visual first_run export_affecting gpu_gated; do
    grep -Fxq "$field=$selected" "$selection_root/output" ||
      fail "$changed_path did not retain $field selection"
  done
done
printf 'PASS: archive/source refusals, complete-component mutations and actual renderer/file failure guards\n'
