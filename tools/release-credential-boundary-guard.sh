#!/usr/bin/env bash
set -euo pipefail

workflow=${1:-.github/workflows/cd.yaml}

fail() {
	printf 'release-credential-boundary: %s\n' "$1" >&2
	exit 1
}

job_block() {
	local job=$1
	local count
	count=$(awk -v job="$job" '$0 == "  " job ":" { count++ } END { print count + 0 }' "$workflow")
	[ "$count" = "1" ] || fail "$job must have exactly one job definition"
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

workflow_block() {
	local key=$1
	awk -v key="$key" '
    $0 ~ ("^" key ":") {
      in_env = 1
      print
      next
    }
    in_env && /^[^[:space:]#]/ {
      in_env = 0
    }
    in_env {
      print
    }
  ' "$workflow"
}

job_names() {
	awk '
    /^jobs:/ {
      in_jobs = 1
      next
    }
    in_jobs && /^  [[:alnum:]_-]+:$/ {
      name = $0
      sub(/^  /, "", name)
      sub(/:$/, "", name)
      print name
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

job_permission_value() {
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
      scalar = permission_value($0)
      if (scalar != "") {
        scalar_entries++
        in_permissions = 0
      } else {
        in_permissions = 1
      }
      next
    }
    in_permissions && /^      [[:alnum:]_-]+:/ {
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
      if (permission_blocks == 0) {
        print "unset"
      } else if (permission_blocks != 1 || scalar_entries > 1 || requested_entries > 1) {
        print "invalid"
      } else if (scalar_entries == 1) {
        if (scalar == "read-all" || scalar == "write-all") {
          print scalar
        } else if (scalar == "{}") {
          print "none"
        } else {
          print "invalid"
        }
      } else if (requested_entries == 1) {
        print value
      } else {
        print "unset"
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

reject_pattern() {
	local block=$1
	local pattern=$2
	local message=$3
	if grep -Eq -- "$pattern" <<<"$block"; then
		fail "$message"
	fi
}

[ -f "$workflow" ] || fail "workflow not found: $workflow"

publish_macos=$(job_block publish-macos)
attach_release=$(job_block attach-release)
publish_ghcr=$(job_block publish-ghcr)
publish_release=$(job_block publish-release)
required_checks=$(job_block cd-required-checks)
workflow_env=$(workflow_block env)
workflow_defaults=$(workflow_block defaults)
workflow_permissions=$(workflow_block permissions)
literal_dollar='$'
aggregate_expression="${literal_dollar}{{ needs.attach-release.result }}"
expected_attach_release_sha256=90be022a9db17ad62cee1727b31424d87903ec3091392f5050224bf1a13fc5cd
actual_attach_release_sha256=$(printf '%s\n' "$attach_release" | shasum -a 256 | awk '{ print $1 }')
expected_publish_release_sha256=d5238170772e7ed374153715bb1392a4d7e064fe07a18871f4955e03efe50758
actual_publish_release_sha256=$(printf '%s\n' "$publish_release" | shasum -a 256 | awk '{ print $1 }')
expected_workflow_permissions=$'permissions:\n  contents: read'

reject_pattern "$workflow_env" '(^|[^[:alnum:]_])secrets([^[:alnum:]_]|$)' "workflow-level env must not expose secrets to publish-macos"
[ -z "$workflow_defaults" ] || fail "workflow-level defaults are forbidden because privileged run steps must use their audited shell"
[ "$workflow_permissions" = "$expected_workflow_permissions" ] || fail "workflow permissions must set only contents: read"
[ "$actual_attach_release_sha256" = "$expected_attach_release_sha256" ] || fail "attach-release structure changed; audit the complete privileged job and update its checksum deliberately"
[ "$actual_publish_release_sha256" = "$expected_publish_release_sha256" ] || fail "publish-release structure changed; audit the complete privileged job and update its checksum deliberately"

while IFS= read -r job; do
	block=$(job_block "$job")
	contents_permission=$(job_permission_value "$block" contents)
	[ "$contents_permission" != "invalid" ] || fail "$job has an unsupported or ambiguous permissions declaration"
	if [ "$contents_permission" = "write" ] || [ "$contents_permission" = "write-all" ]; then
		case "$job" in
		attach-release | publish-release) ;;
		*) fail "$job must not receive release-write repository contents permission" ;;
		esac
	fi
done < <(job_names)

[ "$(job_permission "$publish_macos" contents)" = "read" ] || fail "publish-macos must set only contents: read"
reject_pattern "$publish_macos" '(^|[^[:alnum:]_])secrets([^[:alnum:]_]|$)' "publish-macos must not consume repository secrets"
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
require_text "$attach_release" "ASSET=\"build/WorldAtRuin-\${TAG#v}-macOS-universal.zip\"" "attach-release must bind the handed-off zip to the canonical asset path"
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
