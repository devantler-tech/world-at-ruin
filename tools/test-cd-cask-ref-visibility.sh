#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/cd.yaml"

# Exercise the exact function embedded in the CD run block rather than a
# test-only copy that could drift from production.
helper_source="$(
	sed -n \
		'/# BEGIN cask-ref-visibility-helper/,/# END cask-ref-visibility-helper/p' \
		"${workflow}"
)"
eval "${helper_source}"
if ! declare -F wait_for_cask_ref >/dev/null; then
	echo "missing wait_for_cask_ref production helper in ${workflow}" >&2
	exit 1
fi

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
attempt_file="${test_dir}/attempts"
sleep_file="${test_dir}/sleeps"

gh() {
	local attempts=0
	if [ -f "${attempt_file}" ]; then
		read -r attempts <"${attempt_file}"
	fi
	attempts=$((attempts + 1))
	printf '%s\n' "${attempts}" >"${attempt_file}"
	[ "${attempts}" -ge "${mock_visible_on}" ]
}

sleep() {
	printf '%s\n' "$1" >>"${sleep_file}"
}

mock_visible_on=3
wait_for_cask_ref "devantler-tech/homebrew-tap" "goreleaser/world-at-ruin"

read -r attempts <"${attempt_file}"
if [ "${attempts}" -ne 3 ]; then
	echo "visibility attempts = ${attempts}, want 3" >&2
	exit 1
fi
if [ "$(wc -l <"${sleep_file}" | tr -d ' ')" -ne 2 ]; then
	echo "sleep count should match the two delayed reads" >&2
	exit 1
fi

: >"${attempt_file}"
: >"${sleep_file}"
mock_visible_on=99
if terminal_output="$(
	wait_for_cask_ref \
		"devantler-tech/homebrew-tap" \
		"goreleaser/world-at-ruin" 2>&1
)"; then
	echo "wait_for_cask_ref succeeded when the ref never became visible" >&2
	exit 1
fi

read -r attempts <"${attempt_file}"
if [ "${attempts}" -ne 5 ]; then
	echo "terminal visibility attempts = ${attempts}, want bounded 5" >&2
	exit 1
fi
if [[ "${terminal_output}" != *"could not create or find goreleaser/world-at-ruin"* ]]; then
	echo "terminal failure did not name the invisible ref" >&2
	exit 1
fi
