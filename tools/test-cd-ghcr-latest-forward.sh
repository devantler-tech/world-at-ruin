#!/usr/bin/env bash
# Exercise the exact GHCR latest-tag helper embedded in CD. The registry is a
# stateful local double: the helper still parses real manifest JSON with jq and
# its observable contract is the tag the registry exposes, not a mocked call.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/cd.yaml"

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

helper_file="${test_dir}/ghcr-latest-forward-helper.sh"
sed -n \
	'/# BEGIN ghcr-latest-forward-helper/,/# END ghcr-latest-forward-helper/p' \
	"${workflow}" >"${helper_file}"
# shellcheck source=/dev/null
source "${helper_file}"
if ! declare -F advance_latest_tag >/dev/null; then
	echo "missing advance_latest_tag production helper in ${workflow}" >&2
	exit 1
fi

tags_file="${test_dir}/tags"
latest_file="${test_dir}/latest"
calls_file="${test_dir}/calls"
repo_tags_rc=0
publish_newer_after_first_tag=""

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

reset_registry() {
	: >"${tags_file}"
	: >"${latest_file}"
	: >"${calls_file}"
	repo_tags_rc=0
	publish_newer_after_first_tag=""
}

set_tags() {
	printf '%s\n' "$@" >"${tags_file}"
}

set_latest() {
	printf '%s\n' "$1" >"${latest_file}"
}

latest() {
	local value=""
	if [ -s "${latest_file}" ]; then
		read -r value <"${latest_file}"
	fi
	printf '%s\n' "${value}"
}

tag_calls() {
	grep -c '^tag ' "${calls_file}" || true
}

# Stateful stand-in for the registry boundary. It mirrors the three ORAS
# commands the production helper uses and changes the visible latest tag on a
# real tag operation.
oras() {
	printf '%s\n' "$*" >>"${calls_file}"

	if [ "$1" = "repo" ] && [ "$2" = "tags" ]; then
		cat "${tags_file}"
		return "${repo_tags_rc}"
	fi

	if [ "$1" = "manifest" ] && [ "$2" = "fetch" ]; then
		local current
		current="$(latest)"
		[ -n "${current}" ] || return 1
		printf '{"annotations":{"org.opencontainers.image.version":"%s"}}\n' "${current}"
		return 0
	fi

	if [ "$1" = "tag" ]; then
		local source="$2"
		local destination="$3"
		local version="${source##*:}"
		[ "${destination}" = "latest" ] || return 2
		set_latest "${version}"
		if [ -n "${publish_newer_after_first_tag}" ]; then
			printf '%s\n' "${publish_newer_after_first_tag}" >>"${tags_file}"
			publish_newer_after_first_tag=""
		fi
		return 0
	fi

	return 2
}

artifact="ghcr.io/devantler-tech/world-at-ruin/client"

# A first publication establishes latest.
reset_registry
set_tags "0.80.0"
out="$(advance_latest_tag "${artifact}" "0.80.0")" ||
	fail "first publication did not establish latest"
[ "$(latest)" = "0.80.0" ] || fail "first publication exposed $(latest), want 0.80.0"
[ "$(tag_calls)" -eq 1 ] || fail "first publication should tag exactly once"
[[ "${out}" == *"advanced latest to 0.80.0"* ]] ||
	fail "first publication did not report the version it exposed"

# An older overlapping run may not move latest backwards.
reset_registry
set_tags "0.79.0" "0.80.0" "latest"
set_latest "0.80.0"
out="$(advance_latest_tag "${artifact}" "0.79.0")" ||
	fail "older publication failed instead of preserving the newer latest"
[ "$(latest)" = "0.80.0" ] || fail "older publication moved latest back to $(latest)"
[ "$(tag_calls)" -eq 0 ] || fail "older publication issued a tag write"
[[ "${out}" == *"left latest at newer 0.80.0"* ]] ||
	fail "older publication did not say why it left latest untouched"

# A newer latest remains a monotonic floor even if its immutable tag catalogue
# entry is temporarily invisible. Retagging from the partial catalogue would
# turn a read defect into a real rollback.
reset_registry
set_tags "0.79.0"
set_latest "0.80.0"
out="$(advance_latest_tag "${artifact}" "0.79.0")" ||
	fail "newer latest without a visible bare tag was not preserved"
[ "$(latest)" = "0.80.0" ] ||
	fail "partial catalogue moved latest back to $(latest)"
[ "$(tag_calls)" -eq 0 ] ||
	fail "partial catalogue issued a backward tag write"

# A present but malformed latest annotation cannot be ordered, so the helper
# must fail closed rather than guessing that the immutable catalogue is newer.
reset_registry
set_tags "0.80.0"
set_latest "not-a-version"
if advance_latest_tag "${artifact}" "0.80.0" >/dev/null 2>&1; then
	fail "a malformed current latest version was treated as safe to replace"
fi
[ "$(tag_calls)" -eq 0 ] ||
	fail "malformed current latest still issued a tag write"
[ "$(latest)" = "not-a-version" ] ||
	fail "malformed current latest was replaced"

# A newer publication advances latest.
reset_registry
set_tags "0.79.0" "0.80.0" "latest"
set_latest "0.79.0"
out="$(advance_latest_tag "${artifact}" "0.80.0")" ||
	fail "newer publication did not advance latest"
[ "$(latest)" = "0.80.0" ] || fail "newer publication exposed $(latest), want 0.80.0"
[ "$(tag_calls)" -eq 1 ] || fail "newer publication should tag exactly once"
grep -qF "tag ${artifact}:0.80.0 latest" "${calls_file}" ||
	fail "the newer publication did not tag the newest immutable version"

# A newer immutable version that appears while an older run is tagging must be
# noticed on the verification pass and become the converged latest value.
reset_registry
set_tags "0.79.0"
publish_newer_after_first_tag="0.80.0"
out="$(advance_latest_tag "${artifact}" "0.79.0")" ||
	fail "overlap convergence failed"
[ "$(latest)" = "0.80.0" ] ||
	fail "overlap convergence left latest at $(latest), want 0.80.0"
[ "$(tag_calls)" -eq 2 ] ||
	fail "overlap convergence should write the old candidate then repair to the new one"
grep -qF "tag ${artifact}:0.80.0 latest" "${calls_file}" ||
	fail "overlap convergence never repaired latest to the newly visible version"

# An unreadable tag catalogue is unknown state, never permission to retag.
reset_registry
set_tags "0.80.0"
repo_tags_rc=1
if advance_latest_tag "${artifact}" "0.80.0" >/dev/null 2>&1; then
	fail "an unreadable tag catalogue was treated as safe to mutate"
fi
[ "$(tag_calls)" -eq 0 ] || fail "catalogue failure still issued a tag write"
[ -z "$(latest)" ] || fail "catalogue failure changed latest"

echo "ok"
