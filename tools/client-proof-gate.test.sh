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
    EVENT_NAME=pull_request CLOTH_SELECTED=true CLOTH_RESULT=success \
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
  if run "EXPECTED_SHA=$expected" "ORDINARY_SHA=$expected" "SANDBOX_SHA=$expected" "SCENES_SHA=$expected"; then
    echo 'FAIL: accepted an invalid expected integration SHA' >&2; exit 1
  fi
done
for invalid in '' 0 01 unknown 123456789012345678901; do
  if run "EXPECTED_RUN=$invalid" "SCENES_RUN=$invalid"; then
    echo 'FAIL: accepted matching malformed run identifiers' >&2; exit 1
  fi
  if run "EXPECTED_ATTEMPT=$invalid" "SCENES_ATTEMPT=$invalid"; then
    echo 'FAIL: accepted matching malformed attempt identifiers' >&2; exit 1
  fi
done
# The shared aggregate accepts legitimate skips; this gate independently requires
# every selected cloth worker to succeed, and permits a skip only when not selected.
if ! run CLOTH_SELECTED=false CLOTH_RESULT=skipped; then
  cat "$tmp/verdict"; exit 1
fi
for evidence in true:success false:skipped :skipped; do
  if ! run EVENT_NAME=merge_group "CLOTH_SELECTED=${evidence%:*}" "CLOTH_RESULT=${evidence#*:}"; then
    cat "$tmp/verdict"; exit 1
  fi
done
for event in pull_request merge_group '' push; do
  for selected in true false ''; do
    for result in success skipped failure cancelled timed_out ''; do
      case "$event:$selected:$result" in
        pull_request:true:success|pull_request:false:skipped|merge_group:true:success|merge_group:false:skipped|merge_group::skipped) continue ;;
      esac
      if run "EVENT_NAME=$event" "CLOTH_SELECTED=$selected" "CLOTH_RESULT=$result"; then
        echo 'FAIL: accepted cloth evidence outside its event-specific contract' >&2; exit 1
      fi
    done
  done
done
for selected in true false '' yes; do
  for result in success skipped failure cancelled timed_out ''; do
    case "$selected:$result" in true:success|false:skipped) continue ;; esac
    if run "CLOTH_SELECTED=$selected" "CLOTH_RESULT=$result"; then
      echo 'FAIL: accepted absent or contradictory cloth capture evidence' >&2; exit 1
    fi
  done
done
echo 'TEST PASS -- stable client gate requires all three complete proofs at one integration SHA'
