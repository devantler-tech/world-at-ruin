#!/usr/bin/env bash
# Provenance guard — every asset directory must carry a PROVENANCE.md.
#
# AGENTS.md (Structure) states the law: `client/assets/` is the one sanctioned
# exception to "no binary assets", and "every asset directory carries a
# PROVENANCE.md with licence chain and checksums". The risk register (#16)
# lists licence and provenance drift as a standing risk whose mitigation is
# enforcement in CI — "a fact to enforce, not remember". This is that
# enforcement.
#
# A directory needs coverage when it holds at least one non-Markdown file:
# Markdown is documentation, never a shipped asset, so a stray README does not
# demand a licence chain while every binary and data file does. Coverage may
# come from the directory itself or from any ancestor inside the asset root —
# `humanoid_kit/skins/` is covered by the kit's own PROVENANCE.md, and
# splitting one licence chain across a kit's subdirectories would be worse
# documentation, not better.
#
# The rule is stated as "what is NOT an asset" on purpose. A list of asset
# extensions would fail open the first time a new format lands; this fails
# closed, which is the only useful direction for a guard standing in front of
# a proprietary claim.
#
# Usage: tools/provenance-guard.sh [asset-root]   (default: client/assets)

set -euo pipefail

ASSET_ROOT="${1:-client/assets}"

if [ ! -d "$ASSET_ROOT" ]; then
	echo "provenance-guard: no asset root at '$ASSET_ROOT' — nothing to check."
	exit 0
fi

# Is $1, or any ancestor up to and including the asset root, carrying a PROVENANCE.md?
# Scoped locals: this walk must not touch the caller's loop variable, or an
# uncovered directory gets reported as whatever the walk ended on.
covered_by_provenance() {
	local candidate="$1"
	local parent
	while :; do
		[ -f "$candidate/PROVENANCE.md" ] && return 0
		[ "$candidate" = "$ASSET_ROOT" ] && return 1
		parent="$(dirname "$candidate")"
		# Defensive: never walk out past the asset root.
		[ "$parent" = "$candidate" ] && return 1
		candidate="$parent"
	done
}

uncovered=""
checked=0

while IFS= read -r dir; do
	# Does this directory hold anything that counts as an asset?
	if ! find "$dir" -maxdepth 1 -type f ! -name '*.md' -print -quit | grep -q .; then
		continue
	fi
	checked=$((checked + 1))
	if ! covered_by_provenance "$dir"; then
		uncovered="${uncovered}${dir}"$'\n'
	fi
done < <(find "$ASSET_ROOT" -type d | sort)

if [ -n "$uncovered" ]; then
	echo "::error::asset directories without a PROVENANCE.md — every asset directory must carry one (AGENTS.md, Structure)"
	printf '%s' "$uncovered" | while IFS= read -r dir; do
		[ -n "$dir" ] || continue
		echo "  - $dir"
	done
	echo
	echo "Add a PROVENANCE.md to the directory (or to a parent inside $ASSET_ROOT that"
	echo "covers it) recording the licence chain and checksums of the source data:"
	echo "  * where the bytes came from, with a pinned version and sha256"
	echo "  * the licence of that source data, and why it permits shipping here"
	echo "  * the licence of the output, and the checksum of what was baked"
	echo "See $ASSET_ROOT/characters/humanoid_kit/PROVENANCE.md for the shape."
	exit 1
fi

echo "provenance-guard: OK — $checked asset director$([ "$checked" = 1 ] && echo y || echo ies) covered by a PROVENANCE.md."
