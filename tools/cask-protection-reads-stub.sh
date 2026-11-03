#!/usr/bin/env bash
# Shared by the cask helper tests' `gh` stubs. It answers the two
# branch-protection reads the REST delivery makes: the tap branch's required
# checks and the head's combined status.
#
# The fixtures are passed as arguments rather than read from the caller's
# variables, so this helper depends on no caller's names. Bash's dynamic
# scoping is why that matters: a stub that reads a global such as `statuses`
# silently picks up a production helper's empty local of the same name.
#
# answer_cask_protection_read PATH REQUIRED_RULES_JSON COMBINED_STATUS_JSON
# Prints the matching fixture and returns 0 when PATH is one of the two reads.
# Returns 1 without printing anything otherwise, so the caller keeps dispatching.
answer_cask_protection_read() {
	local request_path="$1" required_rules="$2" combined_status="$3"

	case "${request_path}" in
	*/rules/branches/*) printf '%s\n' "${required_rules}" ;;
	*/status) printf '%s\n' "${combined_status}" ;;
	*) return 1 ;;
	esac
}
