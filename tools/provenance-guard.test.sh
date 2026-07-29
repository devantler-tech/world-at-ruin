#!/usr/bin/env bash
# Integration regressions for provenance-guard.sh.
#
# Each case creates a tiny tracked client tree. The guard deliberately works
# from Git's index, so these tests stage every fixture exactly as CI would see
# it rather than relying on untracked working-tree files.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/provenance-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/war-provenance-guard.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

failures=0

new_repo() {
	local name="$1"
	local repo="$TEST_ROOT/$name"
	mkdir -p "$repo/client/assets/pack"
	git -C "$repo" init -q
	git -C "$repo" config user.email "provenance-guard@example.invalid"
	git -C "$repo" config user.name "Provenance Guard Test"
	printf '%s\n' "$repo"
}

index_sha256() {
	local repo="$1"
	local path="$2"
	git -C "$repo" cat-file blob ":$path" | shasum -a 256 | awk '{print $1}'
}

write_pack_provenance() {
	local repo="$1"
	shift
	local path sha

	{
		printf '%s\n' \
			'# Provenance' \
			'' \
			'Source: original work. Licence: owned outright.' \
			'' \
			'```text'
		for path in "$@"; do
			sha=$(index_sha256 "$repo" "client/assets/pack/$path")
			printf '%s  %s\n' "$sha" "$path"
		done
		printf '%s\n' '```'
	} >"$repo/client/assets/pack/PROVENANCE.md"
	git -C "$repo" add client/assets/pack/PROVENANCE.md
}

expect_failure() {
	local name="$1"
	local expected="$2"
	local repo="$3"
	local output

	if output=$(cd "$repo" && "$GUARD" 2>&1); then
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

	if ! output=$(cd "$repo" && "$GUARD" 2>&1); then
		printf 'FAIL: %s — guard rejected the fixture\n%s\n' "$name" "$output" >&2
		failures=$((failures + 1))
		return
	fi
	printf 'PASS: %s\n' "$name"
}

repo=$(new_repo unaccounted)
printf 'asset-v1\n' >"$repo/client/assets/pack/hero.bin"
printf '%s\n' \
	'# Provenance' \
	'' \
	'Source: original work. Licence: owned outright. Source checksum recorded separately.' \
	>"$repo/client/assets/pack/PROVENANCE.md"
git -C "$repo" add client/assets/pack/hero.bin client/assets/pack/PROVENANCE.md
expect_failure \
	"tracked asset needs an exact provenance entry" \
	"client/assets/pack/hero.bin" \
	"$repo"

repo=$(new_repo changed)
printf 'asset-v1\n' >"$repo/client/assets/pack/hero.bin"
git -C "$repo" add client/assets/pack/hero.bin
sha=$(index_sha256 "$repo" client/assets/pack/hero.bin)
printf '%s\n' \
	'# Provenance' \
	'' \
	'Source: original work. Licence: owned outright.' \
	'' \
	'```text' \
	"$sha  hero.bin" \
	'```' \
	>"$repo/client/assets/pack/PROVENANCE.md"
git -C "$repo" add client/assets/pack/PROVENANCE.md
printf 'asset-v2\n' >"$repo/client/assets/pack/hero.bin"
git -C "$repo" add client/assets/pack/hero.bin
expect_failure \
	"replacement needs its recorded checksum updated" \
	"checksum does not match" \
	"$repo"

repo=$(new_repo accounted)
printf 'asset-v1\n' >"$repo/client/assets/pack/hero.bin"
git -C "$repo" add client/assets/pack/hero.bin
sha=$(index_sha256 "$repo" client/assets/pack/hero.bin)
printf '%s\n' \
	'# Provenance' \
	'' \
	'Source: original work. Licence: owned outright.' \
	'' \
	'```text' \
	"$sha  hero.bin" \
	'```' \
	>"$repo/client/assets/pack/PROVENANCE.md"
git -C "$repo" add client/assets/pack/PROVENANCE.md
expect_success "exact path and checksum are accepted" "$repo"

repo=$(new_repo inherited)
mkdir -p "$repo/client/assets/pack/sub"
printf 'asset-v1\n' >"$repo/client/assets/pack/sub/hero.bin"
git -C "$repo" add client/assets/pack/sub/hero.bin
sha=$(index_sha256 "$repo" client/assets/pack/sub/hero.bin)
printf '%s\n' \
	'# Provenance' \
	'' \
	'Source: original work. Licence: owned outright.' \
	'' \
	'```text' \
	"$sha  sub/hero.bin" \
	'```' \
	>"$repo/client/assets/pack/PROVENANCE.md"
git -C "$repo" add client/assets/pack/PROVENANCE.md
expect_success "ancestor record uses a record-relative path" "$repo"

# R4 — a texture the editor cannot detect in a committed 3D resource must
# declare its mip chain explicitly. A runtime load() alone does not trigger
# Godot's detect_3d import pass, so accepting this fixture would ship the same
# permanent non-mipmapped import that caused #489.
repo=$(new_repo runtime_texture_without_mipmaps)
mkdir -p "$repo/client/scripts"
printf 'texture-v1\n' >"$repo/client/assets/pack/runtime_skin.png"
printf '%s\n' \
	'[remap]' \
	'importer="texture"' \
	'type="CompressedTexture2D"' \
	'' \
	'[params]' \
	'mipmaps/generate=false' \
	>"$repo/client/assets/pack/runtime_skin.png.import"
printf '%s\n' \
	'extends Node' \
	'var runtime_skin := load("res://assets/pack/runtime_skin.png")' \
	>"$repo/client/scripts/runtime_loader.gd"
git -C "$repo" add \
	client/assets/pack/runtime_skin.png \
	client/assets/pack/runtime_skin.png.import \
	client/scripts/runtime_loader.gd
write_pack_provenance "$repo" runtime_skin.png runtime_skin.png.import
expect_failure \
	"runtime-loaded texture needs an explicit mip chain" \
	"mipmaps/generate=true" \
	"$repo"

repo=$(new_repo runtime_texture_with_mipmaps)
mkdir -p "$repo/client/scripts"
printf 'texture-v1\n' >"$repo/client/assets/pack/runtime_skin.png"
printf '%s\n' \
	'[remap]' \
	'importer="texture"' \
	'type="CompressedTexture2D"' \
	'' \
	'[params]' \
	'mipmaps/generate=true' \
	>"$repo/client/assets/pack/runtime_skin.png.import"
printf '%s\n' \
	'extends Node' \
	'var runtime_skin := load("res://assets/pack/runtime_skin.png")' \
	>"$repo/client/scripts/runtime_loader.gd"
git -C "$repo" add \
	client/assets/pack/runtime_skin.png \
	client/assets/pack/runtime_skin.png.import \
	client/scripts/runtime_loader.gd
write_pack_provenance "$repo" runtime_skin.png runtime_skin.png.import
expect_success "runtime-loaded texture with an explicit mip chain is accepted" "$repo"

repo=$(new_repo newline)
newline_path='client/assets/pack/hero
copy.bin'
printf 'asset-v1\n' >"$repo/$newline_path"
printf '%s\n' \
	'# Provenance' \
	'' \
	'Source: original work. Licence: owned outright.' \
	>"$repo/client/assets/pack/PROVENANCE.md"
git -C "$repo" add "$newline_path" client/assets/pack/PROVENANCE.md
expect_failure \
	"unrepresentable paths fail closed" \
	"cannot be represented in a provenance manifest" \
	"$repo"

# R1 — the binary test decides on the decoded BYTES, not on iconv's exit status.
#
# BSD iconv reports failure on a file it decoded perfectly when a multi-byte
# character straddles its first 1024-byte read boundary and stdout is a
# character device: the status carries a stale ENOTTY from an ioctl on the
# device, not a decode error. Both fixtures below are built to that shape, so a
# status-based test classifies the valid one as binary on macOS while CI's GNU
# iconv stays green — the two must agree.
straddling_multibyte_file() {
	# An em dash (E2 80 94) at offset 1022 occupies bytes 1022-1024, so it spans
	# the boundary. Everything else is ASCII, so the file is valid UTF-8 whole.
	{
		head -c 1022 /dev/zero | tr '\0' 'a'
		printf '\342\200\224'
		head -c 200 /dev/zero | tr '\0' 'b'
		printf '\n'
	} >"$1"
}

repo=$(new_repo utf8_straddle)
mkdir -p "$repo/client/scripts"
straddling_multibyte_file "$repo/client/scripts/long_text.gd"
git -C "$repo" add client/scripts/long_text.gd
expect_success "valid UTF-8 spanning iconv's read boundary is not an asset" "$repo"

# The positive control for the same rule: narrowing that false positive must not
# cost R1 its reason to exist. These bytes carry no NUL, so the NUL test cannot
# catch them and only the UTF-8 test stands between them and a silent ship.
repo=$(new_repo utf8_invalid)
mkdir -p "$repo/client/scripts"
{
	head -c 1022 /dev/zero | tr '\0' 'a'
	printf '\377\376'
	head -c 200 /dev/zero | tr '\0' 'b'
} >"$repo/client/scripts/not_text.gd"
git -C "$repo" add client/scripts/not_text.gd
expect_failure \
	"NUL-free undecodable bytes are still binary" \
	"client/scripts/not_text.gd" \
	"$repo"

if [ "$failures" -ne 0 ]; then
	printf 'provenance-guard tests: %d failure(s)\n' "$failures" >&2
	exit 1
fi

printf 'provenance-guard tests: PASS\n'
