#!/usr/bin/env bash
# Exercise the actual stable gate, including missing and mismatched completion.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sha=0123456789abcdef0123456789abcdef01234567
# Invoke the actual gate with valid defaults and the case's explicit evidence overrides.
run() {
  env EXPECTED_SHA="$sha" ORDINARY_RESULT=success SANDBOX_RESULT=success SCENES_RESULT=success \
    ORDINARY_COMPLETE=true SANDBOX_COMPLETE=true SCENES_COMPLETE=true ORDINARY_SHA="$sha" SANDBOX_SHA="$sha" SCENES_SHA="$sha" \
    EXPECTED_RUN=77 EXPECTED_ATTEMPT=2 SCENES_RUN=77 SCENES_ATTEMPT=2 \
    "$@" bash "$root/tools/client-proof-gate.sh" >"$tmp/verdict" 2>&1
}
if ! run; then cat "$tmp/verdict"; exit 1; fi
for participant in ORDINARY SANDBOX SCENES; do
  for result in failure cancelled skipped timed_out ''; do
    if run "${participant}_RESULT=$result"; then
      echo "FAIL: accepted $participant result '$result'" >&2; exit 1
    fi
  done
  for complete in false yes ''; do
    if run "${participant}_COMPLETE=$complete"; then
      echo "FAIL: accepted $participant completion '$complete'" >&2; exit 1
    fi
  done
  for observed in '' fedcba9876543210fedcba9876543210fedcba98 "$sha extra"; do
    if run "${participant}_SHA=$observed"; then
      echo "FAIL: accepted $participant mismatched integration" >&2; exit 1
    fi
  done
done
for field in SCENES_RUN SCENES_ATTEMPT EXPECTED_RUN EXPECTED_ATTEMPT; do
  for value in '' 0 01 unknown 9; do
    if run "$field=$value"; then
      echo "FAIL: accepted stale or invalid $field" >&2; exit 1
    fi
  done
done
for expected in '' short 'refs/heads/main'; do
  if run "EXPECTED_SHA=$expected" "ORDINARY_SHA=$expected" "SANDBOX_SHA=$expected"; then
    echo 'FAIL: accepted an invalid expected integration SHA' >&2; exit 1
  fi
done
echo 'TEST PASS -- stable client gate requires all three complete proofs at one integration SHA'
