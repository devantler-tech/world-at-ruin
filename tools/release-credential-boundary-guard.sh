#!/usr/bin/env bash
set -euo pipefail

workflow=${1:-.github/workflows/cd.yaml}

fail() {
  printf 'release-credential-boundary: %s\n' "$1" >&2
  exit 1
}

job_block() {
  local job=$1
  awk -v job="$job" '
    $0 == "  " job ":" {
      found = 1
    }
    found && $0 ~ /^  [[:alnum:]_-]+:$/ && $0 != "  " job ":" {
      exit
    }
    found {
      print
    }
  ' "$workflow"
}

require_text() {
  local block=$1
  local text=$2
  local message=$3
  grep -Fq -- "$text" <<<"$block" || fail "$message"
}

reject_text() {
  local block=$1
  local text=$2
  local message=$3
  if grep -Fq -- "$text" <<<"$block"; then
    fail "$message"
  fi
}

[ -f "$workflow" ] || fail "workflow not found: $workflow"

publish_macos=$(job_block publish-macos)
attach_release=$(job_block attach-release)
publish_release=$(job_block publish-release)
required_checks=$(job_block cd-required-checks)
literal_dollar='$'
aggregate_expression="${literal_dollar}{{ needs.attach-release.result }}"

require_text "$publish_macos" "      contents: read" "publish-macos must have read-only repository contents"
reject_text "$publish_macos" "contents: write" "publish-macos must not hold a repository write token"
reject_text "$publish_macos" "secrets." "publish-macos must not consume repository secrets"
reject_text "$publish_macos" "gh release upload" "publish-macos must not attach the release asset"
require_text "$publish_macos" "actions/upload-artifact@" "publish-macos must hand its build to later jobs as a workflow artifact"
require_text "$publish_macos" "name: client-macos-universal" "publish-macos must upload the canonical client artifact"

require_text "$attach_release" "  attach-release:" "attach-release job is missing"
require_text "$attach_release" "    needs: [publish-macos]" "attach-release must wait for publish-macos"
require_text "$attach_release" "    timeout-minutes: 15" "attach-release timeout must cover the fail-closed retry budget"
require_text "$attach_release" "      contents: write" "attach-release needs contents: write to attach the release asset"
require_text "$attach_release" "actions/download-artifact@" "attach-release must receive the build through a workflow artifact"
require_text "$attach_release" "name: client-macos-universal" "attach-release must download the canonical client artifact"
require_text "$attach_release" "gh release upload" "attach-release must own the release upload"
reject_text "$attach_release" "actions/checkout@" "attach-release must never check out repository-controlled code"
reject_text "$attach_release" "uses: ./" "attach-release must never execute a repository-local action"

require_text "$publish_release" "    needs: [attach-release, publish-ghcr]" "publish-release must wait for both asset publication jobs"
require_text "$required_checks" "        attach-release," "CD required checks must include attach-release"
require_text "$required_checks" "$aggregate_expression" "CD aggregate must include attach-release's result"

printf 'release-credential-boundary: PASS\n'
