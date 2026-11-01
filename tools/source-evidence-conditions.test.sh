#!/usr/bin/env bash
# Exercise the relocated shipping verdict reader, not a fixture implementation.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture() {
  local dir=$1
  mkdir -p "$dir/logs" "$dir/shots"
  printf 'VOLUMETRICS off\nHOLLOW FOG off\nREPLICATION off\n' >"$dir/logs/capture.log"
  printf 'REPLICATION on\n' >"$dir/logs/capture-replication.log"
  printf 'MOB CHASE on\n' >"$dir/logs/capture-mob-chase.log"
}
run() {
  SOURCE_EVIDENCE_DIR="$1" CAPTURE_RUNNER_OS=macOS GPU_GATED=true \
    GITHUB_STEP_SUMMARY="$1/summary" bash "$root/tools/source-evidence-conditions.sh"
}
fixture "$work/valid"
run "$work/valid" >"$work/valid/output" 2>&1
grep -Fxq 'runner: macOS (hosted)' "$work/valid/shots/capture-conditions.txt"
grep -Fxq 'replicated_entities_in_world_frames: off' "$work/valid/shots/capture-conditions.txt"
grep -Fxq 'replicated_entities_in_replication_frames: on' "$work/valid/shots/capture-conditions.txt"
grep -q '::warning::' "$work/valid/output"
for mutation in missing-verdict contradictory-verdict world-populated empty-replication chase-off missing-log; do
  dir="$work/$mutation"
  fixture "$dir"
  case $mutation in
  missing-verdict) printf 'HOLLOW FOG off\nREPLICATION off\n' >"$dir/logs/capture.log" ;;
  contradictory-verdict) printf 'VOLUMETRICS on\n' >>"$dir/logs/capture.log" ;;
  world-populated) printf 'VOLUMETRICS off\nHOLLOW FOG off\nREPLICATION on\n' >"$dir/logs/capture.log" ;;
  empty-replication) printf 'REPLICATION off\n' >"$dir/logs/capture-replication.log" ;;
  chase-off) printf 'MOB CHASE off\n' >"$dir/logs/capture-mob-chase.log" ;;
  missing-log) mv "$dir/logs/capture-mob-chase.log" "$dir/missing.log" ;;
  esac
  if run "$dir" >"$dir/output" 2>&1; then
    echo "FAIL: accepted $mutation" >&2
    exit 1
  fi
  [[ ! -e $dir/shots/capture-conditions.txt ]] || {
    echo 'FAIL: invalid verdicts published evidence conditions' >&2
    exit 1
  }
done
echo 'PASS: source conditions preserve native provenance and reject unknown or contradictory capture verdicts'
