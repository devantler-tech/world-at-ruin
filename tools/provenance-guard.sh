#!/usr/bin/env bash
# Provenance guard — asset bytes live in one place, and that place is documented.
#
# AGENTS.md (Structure) states the law: `client/assets/` is "the one sanctioned
# exception to 'no binary assets'", and "every asset directory carries a
# PROVENANCE.md with licence chain and checksums". The risk register (#16)
# lists licence and provenance drift as a standing risk to enforce in CI —
# "a fact to enforce, not remember". This is that enforcement, in three rules:
#
#   R1  No binary file anywhere under client/ may sit OUTSIDE client/assets/.
#       `export_presets.cfg` ships with `export_filter="all_resources"`, so
#       every resource under client/ reaches the player whatever directory it
#       is in. Without this rule the guard is trivially evaded by putting an
#       unprovenanced asset in client/models/ instead.
#
#   R2  Every directory under client/assets/ holding a non-Markdown file must
#       be covered by a PROVENANCE.md, at itself or at an ancestor within the
#       asset root. Markdown is documentation, never a shipped asset, so a
#       stray README does not demand a licence chain.
#
#   R3  Every tracked non-Markdown file under client/assets/ must be named in
#       its covering PROVENANCE.md with the SHA-256 of the exact indexed bytes:
#
#           <64 lowercase hex characters><two spaces><record-relative path>
#
#       The path is relative to the directory containing that PROVENANCE.md.
#       This binds the prose licence/source chain to every shipped file and
#       catches both an unrecorded addition and a silent replacement.
#
# WHY BINARY-BY-CONTENT RATHER THAN BY EXTENSION: an extension allowlist fails
# open the first time a new format lands, and has to be maintained forever.
# Testing for a NUL byte needs no list and catches any future binary format on
# the day it appears. It also keeps text sources correct without special cases —
# `client/icon.svg` is a hand-authored 452-byte SVG, and treating it as an
# unprovenanced asset would be a false positive.
#
# The documented residual: an asset encoded as TEXT (base64 in a .json, or
# third-party SVG artwork) satisfies R1, because the law's words are "no binary
# assets". Tightening that means judging what a text file depicts, which is a
# different and much harder check than this one.
#
# Ancestor coverage in R2 is deliberate: skins/ and equipment/ inherit their
# kit's licence chain, and splitting one chain across a kit's subdirectories
# would be worse documentation, not better.
#
# Traversal is NUL-delimited throughout: git permits a newline in a directory
# name, and a line-delimited walk would split such a name into paths that do
# not exist, whose `find` errors read as "no assets here" — an evasion that
# exits 0. A newline cannot be represented unambiguously in R3's line-oriented
# manifest, so such an asset path is rejected rather than silently exempted.
#
# SCOPE: files TRACKED BY GIT, not the working tree. The question this guard
# answers is what enters the repository and ships from it, and the working tree
# also holds Godot's local import cache (client/.godot/), which is generated,
# ignored, and full of binary .ctex/.scn — scanning it would fail every run for
# files that are not in the repository at all.
#
# Usage: tools/provenance-guard.sh [client-root]   (default: client)

set -euo pipefail

CLIENT_ROOT="${1:-client}"
ASSET_ROOT="$CLIENT_ROOT/assets"

if [ ! -d "$CLIENT_ROOT" ]; then
	echo "provenance-guard: no client root at '$CLIENT_ROOT' — nothing to check."
	exit 0
fi

# A file counts as BINARY if it is not valid UTF-8, or if it contains a NUL.
#
# Testing for NUL alone was fail-open: a binary stream that happens to carry no
# 0x00 would pass, which is exactly the file a motivated author would choose.
# The UTF-8 test closes that — an image or mesh does not decode cleanly as
# UTF-8 by accident.
#
# Deliberately NOT rejecting other control bytes. That was tried and was too
# strict: `client/tests/data/jcs_vectors.json` is valid UTF-8 carrying two DEL
# (0x7F) bytes, because RFC 8785 canonicalization has to handle them, and a
# guard that calls its own test vectors binary is wrong about the repository
# rather than right about the rule. Nor "anything not printable" — under
# LC_ALL=C every byte of a multi-byte UTF-8 character is non-printable, so that
# would call every source file here binary; they are full of em dashes.
is_binary() {
	local file="$1" total stripped
	# Invalid UTF-8 → binary. This is what catches the NUL-free binary formats;
	# an image or mesh that decodes cleanly as UTF-8 is not a thing that
	# happens by accident.
	iconv -f UTF-8 -t UTF-8 <"$file" >/dev/null 2>&1 || return 0
	# A NUL byte → binary. Octal range through `tr`, NOT a grep bracket
	# expression: BSD grep rejects \xNN ranges outright.
	total=$(wc -c <"$file")
	stripped=$(LC_ALL=C tr -d '\000' <"$file" | wc -c)
	[ "$total" -ne "$stripped" ]
}

# Print the PROVENANCE.md that covers $1, searching $1 and then its ancestors
# up to the asset root. Scoped locals: this walk must not touch the caller's
# loop variable, or an uncovered directory gets reported as whatever the walk
# ended on.
provenance_record_for() {
	local candidate="$1"
	local parent
	while :; do
		if [ -f "$candidate/PROVENANCE.md" ]; then
			printf '%s\n' "$candidate/PROVENANCE.md"
			return 0
		fi
		[ "$candidate" = "$ASSET_ROOT" ] && return 1
		# Parameter expansion, NOT $(dirname ...): command substitution strips
		# trailing newlines, so an ancestor whose name ends in one would be
		# rewritten to a DIFFERENT existing directory and its PROVENANCE.md
		# would be credited to a path it does not cover.
		parent="${candidate%/*}"
		# Defensive: never walk out past the asset root.
		[ "$parent" = "$candidate" ] && return 1
		[ -n "$parent" ] || return 1
		candidate="$parent"
	done
}

recorded_checksum_for() {
	local record="$1"
	local relative="$2"
	local line recorded_path candidate

	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		*"  "*) ;;
		*) continue ;;
		esac
		recorded_path="${line#*  }"
		[ "$recorded_path" = "$relative" ] || continue
		candidate="${line%%  *}"
		[ "${#candidate}" -eq 64 ] || continue
		case "$candidate" in
		*[!0-9a-f]*) continue ;;
		esac
		printf '%s\n' "$candidate"
		return 0
	done <"$record"

	return 1
}

stray=()
uncovered=()
unaccounted=()
checksum_mismatch=()
unrepresentable=()
checked=0
accounted=0

# R1 — binary bytes outside the sanctioned asset directory.
while IFS= read -r -d '' file; do
	case "$file" in
	"$ASSET_ROOT"/*) continue ;;
	esac
	if is_binary "$file"; then
		stray+=("$file")
	fi
done < <(git -C . ls-files -z -- "$CLIENT_ROOT")

# R2 — asset directories without a covering PROVENANCE.md.
#
# Derived from the TRACKED file list, not from `find -type f`. A directory
# holding only symlinks was skipped entirely by the find form, because a
# symlink is not -type f — so an asset directory could be created with links
# and inherit no provenance requirement at all. git tracks symlinks as files,
# so taking the directory set from the index closes that and keeps R1 and R2
# working from the same definition of "in the repository".
if [ -d "$ASSET_ROOT" ]; then
	# NUL-delimited sort -zu rather than an associative array: this has to run
	# on the maintainer's macOS bash 3.2, which has neither `declare -A` nor
	# `${!array[@]}` over string keys, and NUL keeps the newline-safety.
	while IFS= read -r -d '' dir; do
		checked=$((checked + 1))
		if ! provenance_record_for "$dir" >/dev/null; then
			uncovered+=("$dir")
		fi
	done < <(
		git ls-files -z -- "$ASSET_ROOT" | while IFS= read -r -d '' file; do
			if [ "${file##*.}" != "md" ]; then
				printf '%s\0' "${file%/*}"
			fi
		done | sort -zu
	)

	# R3 — each tracked asset is bound to the exact bytes and to the prose
	# source/licence chain in its nearest covering provenance record.
	while IFS= read -r -d '' file; do
		[ "${file##*.}" = "md" ] && continue

		case "$file" in
		*'
'*)
			unrepresentable+=("$file")
			continue
			;;
		esac

		record=$(provenance_record_for "${file%/*}") || continue
		record_dir="${record%/*}"
		record_prefix="$record_dir/"
		relative="${file#"$record_prefix"}"
		index_sha=$(git cat-file blob ":$file" | shasum -a 256 | awk '{print $1}')

		if grep -Fqx -- "$index_sha  $relative" "$record"; then
			accounted=$((accounted + 1))
			continue
		fi

		if recorded_sha=$(recorded_checksum_for "$record" "$relative"); then
			checksum_mismatch+=("$file (recorded $recorded_sha, indexed $index_sha in $record)")
		else
			unaccounted+=("$file (expected in $record)")
		fi
	done < <(git ls-files -z -- "$ASSET_ROOT")
fi

failed=0

if [ ${#stray[@]} -gt 0 ]; then
	failed=1
	echo "::error::binary assets outside $ASSET_ROOT — the only sanctioned home for asset bytes (AGENTS.md, Structure)"
	printf '  - %s\n' "${stray[@]}"
	echo
	echo "Everything under $CLIENT_ROOT ships (export_filter=\"all_resources\"), so an asset"
	echo "outside $ASSET_ROOT reaches players with no licence chain recorded. Move it under"
	echo "$ASSET_ROOT and give its directory a PROVENANCE.md."
	echo
fi

if [ ${#uncovered[@]} -gt 0 ]; then
	failed=1
	echo "::error::asset directories without a PROVENANCE.md — every asset directory must carry one (AGENTS.md, Structure)"
	printf '  - %s\n' "${uncovered[@]}"
	echo
	echo "Add a PROVENANCE.md to the directory (or to a parent inside $ASSET_ROOT that"
	echo "covers it) recording the licence chain and checksums of the source data:"
	echo "  * where the bytes came from, with a pinned version and sha256"
	echo "  * the licence of that source data, and why it permits shipping here"
	echo "  * the licence of the output, and the checksum of what was baked"
	echo "See $ASSET_ROOT/characters/humanoid_kit/PROVENANCE.md for the shape."
fi

if [ ${#unaccounted[@]} -gt 0 ]; then
	failed=1
	echo "::error::tracked assets missing from their provenance manifest — every shipped file must be accounted for"
	printf '  - %s\n' "${unaccounted[@]}"
	echo
	echo "Add an exact manifest line to the covering PROVENANCE.md:"
	echo "  <sha256 of the indexed file><two spaces><path relative to the record>"
	echo "The surrounding prose must identify the source and licence chain; a checksum-only"
	echo "list does not establish permission to ship the bytes."
	echo
fi

if [ ${#checksum_mismatch[@]} -gt 0 ]; then
	failed=1
	echo "::error::asset checksum does not match its provenance manifest — the tracked bytes changed"
	printf '  - %s\n' "${checksum_mismatch[@]}"
	echo
	echo "Re-verify the source and licence before updating the recorded checksum. A changed"
	echo "digest is never self-justifying provenance."
	echo
fi

if [ ${#unrepresentable[@]} -gt 0 ]; then
	failed=1
	echo "::error::asset path cannot be represented in a provenance manifest — newlines are forbidden"
	printf '  - %q\n' "${unrepresentable[@]}"
	echo
	echo "Rename the tracked asset to a line-safe path, then account for it in PROVENANCE.md."
	echo
fi

[ "$failed" -eq 0 ] || exit 1

echo "provenance-guard: OK — no binary assets outside $ASSET_ROOT; $checked asset director$([ "$checked" = 1 ] && echo y || echo ies) covered; $accounted tracked asset file$([ "$accounted" = 1 ] && echo '' || echo s) individually checksummed."
