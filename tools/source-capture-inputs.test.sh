#!/usr/bin/env bash
# Reject wrong sources and unknown flags before a renderer can touch state.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/tools/source-capture-inputs.sh"
[[ -f $script ]] || {
  echo 'FAIL: source capture input validator is missing' >&2
  exit 1
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q
git -C "$work" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm fixture --allow-empty
sha=$(git -C "$work" rev-parse HEAD)
run() {
  (cd "$work" && env CAPTURE_GROUP=world FIRST_RUN=false VISUAL=true GPU_GATED=false GITHUB_SHA="$sha" RUNNER_TEMP="$work" "$@" bash "$script")
}
run
[[ -d $work/shots && ! -L $work/shots ]] || {
  echo 'FAIL: fresh evidence directory missing' >&2
  exit 1
}
rmdir "$work/shots"
run CAPTURE_GROUP=activity FIRST_RUN=true GPU_GATED=true
rmdir "$work/shots"
for bad in CAPTURE_GROUP=unknown CAPTURE_GROUP= FIRST_RUN=yes VISUAL=false VISUAL=yes GPU_GATED=yes GITHUB_SHA=unknown GITHUB_SHA=0000000000000000000000000000000000000000; do
  if run "$bad" >"$work/output" 2>&1; then
    echo "FAIL: accepted $bad" >&2
    exit 1
  fi
  [[ ! -e $work/shots ]] || {
    echo 'FAIL: invalid inputs created evidence state' >&2
    exit 1
  }
done
mkdir "$work/shots"
if run >"$work/output" 2>&1; then
  echo 'FAIL: accepted pre-existing evidence directory' >&2
  exit 1
fi
rmdir "$work/shots"
mkdir "$work/other"
ln -s other "$work/shots"
if run >"$work/output" 2>&1; then
  echo 'FAIL: accepted linked evidence directory' >&2
  exit 1
fi
[[ -L $work/shots && -d $work/other ]] || {
  echo 'FAIL: refused input changed existing state' >&2
  exit 1
}
echo 'PASS: source capture accepts closed flags and exact checkout; refuses stale or linked state'
