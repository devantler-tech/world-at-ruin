#!/usr/bin/env bash
# Integration regressions for originality-guard.sh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/originality-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/war-originality-guard.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

failures=0

new_repo() {
	local name="$1"
	local repo="$TEST_ROOT/$name"
	mkdir -p \
		"$repo/client/scripts" \
		"$repo/docs/art-direction" \
		"$repo/docs/design" \
		"$repo/docs/evidence" \
		"$repo/tools/artgen"
	git -C "$repo" init -q
	git -C "$repo" config user.email "originality-guard@example.invalid"
	git -C "$repo" config user.name "Originality Guard Test"
	printf '%s\n' "$repo"
}

write_valid_contract() {
	local repo="$1"
	printf '%s\n' \
		'# Agent contract' \
		'' \
		'Follow [the originality boundary](docs/design/originality-boundary.md).' \
		>"$repo/AGENTS.md"
	printf '%s\n' \
		'# Art direction' \
		'' \
		'Follow [the originality boundary](../design/originality-boundary.md).' \
		>"$repo/docs/art-direction/README.md"
	printf '%s\n' \
		'# Originality boundary' \
		'' \
		'Independent expression only.' \
		>"$repo/docs/design/originality-boundary.md"
	printf '%s\n' \
		'# Story proposal' \
		'' \
		'**ORIGINALITY HOLD (#359): DO NOT IMPLEMENT THE UNDYING WORK OR FORMER LIVES CONCEPT.**' \
		>"$repo/docs/design/story-and-progression.md"
	printf '%s\n' \
		'# Named-game references prohibited from player prose' \
		'World of Warcraft' \
		'Outer Wilds' \
		'Return of the Obra Dinn' \
		'Wretch reference' \
		>"$repo/tools/originality-reference-titles.txt"
	: >"$repo/docs/first-party-captures.sha256"
	printf '%s\n' \
		'extends Node' \
		'' \
		'const ENTRIES := [{"gap": "The cloth needs more material detail."}]' \
		>"$repo/client/scripts/devlog.gd"
	git -C "$repo" add \
		AGENTS.md \
		client/scripts/devlog.gd \
		docs/art-direction/README.md \
		docs/design/originality-boundary.md \
		docs/design/story-and-progression.md \
		docs/first-party-captures.sha256 \
		tools/originality-reference-titles.txt
}

run_guard() {
	local repo="$1"
	if [ ! -x "$GUARD" ]; then
		echo "originality-guard test failure: guard is missing or not executable" >&2
		return 1
	fi
	(cd "$repo" && "$GUARD")
}

expect_failure() {
	local name="$1"
	local expected="$2"
	local repo="$3"
	local output

	if output=$(run_guard "$repo" 2>&1); then
		printf 'FAIL: %s — guard accepted the fixture\n' "$name" >&2
		failures=$((failures + 1))
		return
	fi
	if ! printf '%s\n' "$output" | grep -Fq -- "$expected"; then
		printf 'FAIL: %s — missing diagnostic %s\n%s\n' "$name" "$expected" "$output" >&2
		failures=$((failures + 1))
		return
	fi
	printf 'PASS: %s\n' "$name"
}

expect_success() {
	local name="$1"
	local repo="$2"
	local output

	if ! output=$(run_guard "$repo" 2>&1); then
		printf 'FAIL: %s — guard rejected the fixture\n%s\n' "$name" "$output" >&2
		failures=$((failures + 1))
		return
	fi
	printf 'PASS: %s\n' "$name"
}

repo=$(new_repo reference_media)
write_valid_contract "$repo"
printf '\377\330\377\000reference bytes\n' >"$repo/docs/art-direction/reference.jpg"
git -C "$repo" add docs/art-direction/reference.jpg
expect_failure \
	"downloaded reference media is rejected" \
	"art-direction references must stay link-only Markdown" \
	"$repo"

repo=$(new_repo disguised_media)
write_valid_contract "$repo"
printf '\377\000not markdown\n' >"$repo/docs/art-direction/reference.md"
git -C "$repo" add docs/art-direction/reference.md
expect_failure \
	"binary reference media cannot hide behind a Markdown extension" \
	"binary content under docs/art-direction" \
	"$repo"

repo=$(new_repo artgen_media)
write_valid_contract "$repo"
printf '\211PNG\r\n\032\nreference bytes\n' >"$repo/tools/artgen/reference.png"
git -C "$repo" add tools/artgen/reference.png
expect_failure \
	"reference media cannot become an art-generation input" \
	"binary reference input under tools/artgen" \
	"$repo"

repo=$(new_repo text_artgen_model)
write_valid_contract "$repo"
printf '%s\n' \
	'# copied ASCII model' \
	'v 0.0 0.0 0.0' \
	'v 1.0 0.0 0.0' \
	'f 1 2 3' \
	>"$repo/tools/artgen/reference.obj"
git -C "$repo" add tools/artgen/reference.obj
expect_failure \
	"text-encoded models cannot become art-generation inputs" \
	"unsupported tracked input under tools/artgen" \
	"$repo"

repo=$(new_repo encoded_reference)
write_valid_contract "$repo"
printf '%s\n' \
	'# Reference' \
	'' \
	'<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h10v10z"/></svg>' \
	>"$repo/docs/art-direction/reference.md"
git -C "$repo" add docs/art-direction/reference.md
expect_failure \
	"inline media cannot hide inside a Markdown reference" \
	"encoded or inline media under docs/art-direction" \
	"$repo"

repo=$(new_repo unreviewed_media)
write_valid_contract "$repo"
printf '\211PNG\r\n\032\nreference bytes\n' >"$repo/docs/evidence/reference.png"
git -C "$repo" add docs/evidence/reference.png
expect_failure \
	"tracked media outside an exact first-party or asset provenance boundary is rejected" \
	"tracked media is outside a reviewed provenance boundary" \
	"$repo"

repo=$(new_repo first_party_capture)
write_valid_contract "$repo"
printf '\211PNG\r\n\032\nfirst-party frame\n' >"$repo/docs/evidence/frame.png"
hash=$(shasum -a 256 "$repo/docs/evidence/frame.png" | awk '{print $1}')
printf '%s  %s\n' "$hash" "docs/evidence/frame.png" \
	>"$repo/docs/first-party-captures.sha256"
git -C "$repo" add docs/evidence/frame.png docs/first-party-captures.sha256
expect_success \
	"exact-byte-bound first-party capture is accepted" \
	"$repo"
printf 'changed\n' >>"$repo/docs/evidence/frame.png"
expect_failure \
	"changed first-party capture invalidates its reviewed manifest entry" \
	"first-party capture manifest contains stale or invalid entries" \
	"$repo"

repo=$(new_repo player_comparison)
write_valid_contract "$repo"
printf '%s\n' \
	'extends Node' \
	'' \
	'const ENTRIES := [{"gap": "The cloth still needs work to approach the Wretch reference."}]' \
	>"$repo/client/scripts/devlog.gd"
git -C "$repo" add client/scripts/devlog.gd
expect_failure \
	"player-facing prose cannot name a reference game element" \
	"third-party reference term in player-facing dev log" \
	"$repo"

repo=$(new_repo audited_player_comparison)
write_valid_contract "$repo"
printf '%s\n' \
	'extends Node' \
	'' \
	'const ENTRIES := [{"gap": "The journal structure still resembles Outer Wilds."}]' \
	>"$repo/client/scripts/devlog.gd"
git -C "$repo" add client/scripts/devlog.gd
expect_failure \
	"every audited reference title is excluded from player-facing prose" \
	"third-party reference term in player-facing dev log" \
	"$repo"

repo=$(new_repo missing_hold)
write_valid_contract "$repo"
printf '%s\n' '# Story proposal' >"$repo/docs/design/story-and-progression.md"
git -C "$repo" add docs/design/story-and-progression.md
expect_failure \
	"high-risk story proposal stays quarantined" \
	"story proposal is missing the exact ORIGINALITY HOLD directive" \
	"$repo"

repo=$(new_repo lifted_hold)
write_valid_contract "$repo"
printf '%s\n' \
	'# Story proposal' \
	'' \
	'ORIGINALITY HOLD lifted; implementation approved.' \
	>"$repo/docs/design/story-and-progression.md"
git -C "$repo" add docs/design/story-and-progression.md
expect_failure \
	"story quarantine cannot be satisfied by saying the hold was lifted" \
	"story proposal is missing the exact ORIGINALITY HOLD directive" \
	"$repo"

repo=$(new_repo valid)
write_valid_contract "$repo"
expect_success "link-only references and required policy anchors pass" "$repo"

if [ "$failures" -ne 0 ]; then
	printf 'originality-guard tests: %d failure(s)\n' "$failures" >&2
	exit 1
fi

printf 'originality-guard tests: PASS\n'
