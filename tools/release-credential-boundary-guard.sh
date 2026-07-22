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

job_permission() {
	local block=$1
	local permission=$2
	awk -v permission="$permission" '
    function permission_value(line) {
      sub(/^[^:]+:[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      return line
    }
    /^    permissions:/ {
      permission_blocks++
      in_permissions = 1
      if (permission_value($0) != "") {
        in_permissions = 0
      }
      next
    }
    in_permissions && /^      [[:alnum:]_-]+:/ {
      permission_entries++
      if ($0 ~ ("^      " permission ":")) {
        requested_entries++
        value = permission_value($0)
      }
      next
    }
    in_permissions && /^    [[:alnum:]_-]+:/ {
      in_permissions = 0
    }
    END {
      if (permission_blocks != 1 || permission_entries != 1 || requested_entries != 1) {
        print "invalid"
      } else {
        print value
      }
    }
  ' <<<"$block"
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
publish_ghcr=$(job_block publish-ghcr)
publish_release=$(job_block publish-release)
required_checks=$(job_block cd-required-checks)
literal_dollar='$'
aggregate_expression="${literal_dollar}{{ needs.attach-release.result }}"

[ "$(job_permission "$publish_macos" contents)" = "read" ] || fail "publish-macos must set only contents: read"
reject_text "$publish_macos" "secrets." "publish-macos must not consume repository secrets"
reject_text "$publish_macos" "gh release upload" "publish-macos must not attach the release asset"
require_text "$publish_macos" "actions/upload-artifact@" "publish-macos must hand its build to later jobs as a workflow artifact"
require_text "$publish_macos" "name: client-macos-universal" "publish-macos must upload the canonical client artifact"

require_text "$attach_release" "  attach-release:" "attach-release job is missing"
require_text "$attach_release" "    needs: [publish-macos]" "attach-release must wait for publish-macos"
require_text "$attach_release" "    timeout-minutes: 15" "attach-release timeout must cover the fail-closed retry budget"
[ "$(job_permission "$attach_release" contents)" = "write" ] || fail "attach-release must set only contents: write"
require_text "$attach_release" "actions/download-artifact@" "attach-release must receive the build through a workflow artifact"
require_text "$attach_release" "name: client-macos-universal" "attach-release must download the canonical client artifact"
require_text "$attach_release" "gh release upload" "attach-release must own the release upload"
reject_text "$attach_release" "actions/checkout@" "attach-release must never check out repository-controlled code"
reject_text "$attach_release" "uses: ./" "attach-release must never execute a repository-local action"

require_text "$publish_release" "    needs: [attach-release, publish-ghcr]" "publish-release must wait for both asset publication jobs"
[ "$(job_permission "$publish_release" contents)" = "write" ] || fail "publish-release must set only contents: write"
reject_text "$publish_release" "actions/checkout@" "publish-release must never check out repository-controlled code"
reject_text "$publish_release" "uses: ./" "publish-release must never execute a repository-local action"

require_text "$publish_ghcr" "    needs: [publish-macos, attach-release]" "publish-ghcr must wait for successful release attachment"
require_text "$required_checks" "        attach-release," "CD required checks must include attach-release"
require_text "$required_checks" "$aggregate_expression" "CD aggregate must include attach-release's result"

printf 'release-credential-boundary: PASS\n'
