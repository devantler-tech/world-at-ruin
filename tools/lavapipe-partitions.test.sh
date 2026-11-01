#!/usr/bin/env bash
# The real collector must refuse incomplete, mixed-source or unsuccessful unions.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
collector="$root/tools/collect-lavapipe-captures.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
sha=1234567890123456789012345678901234567890
views=(sunward crossfield shrine bonepale cinderreach cave-chamber cave-walkout cave-mouth)
fail() {
  echo "TEST FAIL -- $*" >&2
  exit 1
}
[[ -f $collector ]] || fail 'there is no executable complete-union collector'
fixture() {
  local view cell
  mkdir "$scratch/input"
  for view in "${views[@]}"; do
    cell="$scratch/input/lavapipe-volumetric-frames-$sha-$view"
    mkdir "$cell"
    printf 'synthetic presence fixture, not visual evidence\n' >"$cell/$view.png"
    printf 'frame note\n' >"$cell/$view.txt"
    printf 'integration_sha: %s\nvantage: %s\ncapture_seconds: 30\n' "$sha" "$view" >"$cell/capture-conditions-$view.txt"
    {
      echo 'VOLUMETRICS on — R32_Uint atomic storage image supported'
      echo 'BOOT_OK vdev'
      echo 'Vulkan 1.4.318 - Forward+ - Using Device #0: llvmpipe (LLVM 20.1.2, 256 bits)'
      echo 'HOLLOW FOG on — 3 ash pools with whole-pool density swell'
      printf 'CAPTURED %s -> fixture (1600x900)\nCAPTURE PASS — 1 vantages written to fixture\n' "$view"
    } >"$cell/capture-lavapipe.log"
  done
}
fixture
bash "$collector" "$scratch/input" "$scratch/output" "$sha" >"$scratch/verdict" 2>&1 || {
  cat "$scratch/verdict" >&2
  fail 'a complete source-bound union was rejected'
}
[[ $(find "$scratch/output" -name '*.png' -type f | wc -l) -eq 8 ]] || fail 'the complete union lost or replayed a frame'
[[ $(find "$scratch/output" -name 'capture-lavapipe-*.log' -type f | wc -l) -eq 8 ]] || fail 'per-view logs were overwritten'
for mutation in missing extra mixed-head wrong-view runtime-error no-verdict contradictory empty-frame symlink; do
  rm -rf "$scratch/input" "$scratch/output"
  fixture
  cell="$scratch/input/lavapipe-volumetric-frames-$sha-sunward"
  case "$mutation" in
  missing) rm -rf "$cell" ;;
  extra) mkdir "$scratch/input/unexpected" ;;
  mixed-head) printf 'integration_sha: %040d\nvantage: sunward\ncapture_seconds: 30\n' 0 >"$cell/capture-conditions-sunward.txt" ;;
  wrong-view) mv "$cell/sunward.png" "$cell/crossfield.png" ;;
  runtime-error) echo 'SCRIPT ERROR: deliberate failure' >>"$cell/capture-lavapipe.log" ;;
  no-verdict)
    sed '/CAPTURE PASS/d' "$cell/capture-lavapipe.log" >"$scratch/changed"
    mv "$scratch/changed" "$cell/capture-lavapipe.log"
    ;;
  contradictory) echo 'VOLUMETRICS off — fallback' >>"$cell/capture-lavapipe.log" ;;
  empty-frame) : >"$cell/sunward.png" ;;
  symlink)
    mv "$cell/sunward.png" "$scratch/link-target"
    ln -s "$scratch/link-target" "$cell/sunward.png"
    ;;
  esac
  if bash "$collector" "$scratch/input" "$scratch/output" "$sha" >"$scratch/verdict" 2>&1; then fail "accepted $mutation"; fi
  [[ ! -e $scratch/output ]] || fail "$mutation published a partial union"
done
echo 'TEST PASS -- complete lavapipe union refuses missing, extra, mixed-source and failed evidence'
