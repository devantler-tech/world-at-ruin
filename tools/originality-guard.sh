#!/usr/bin/env bash
# Originality guard — named games are view-only references, never source data.
#
# Copyright protects original expression, not the abstract game idea, rule or
# method of play. That boundary still requires human judgment; this script
# enforces only repository facts that are objective:
#
#   R1  docs/art-direction contains link-only UTF-8 Markdown. Downloaded
#       screenshots, clips, audio and other reference media do not enter the
#       repository, even with a misleading .md extension.
#   R2  tools/artgen contains no tracked binary reference input. A generator
#       may consume owned/CC0 inputs under client/assets with provenance, but
#       never a copied screenshot or other game's asset.
#   R3  the player-facing dev log does not expose internal third-party game
#       comparisons.
#   R4  the canonical originality policy is linked from both agent and art
#       direction contracts, and the currently high-risk story proposal stays
#       explicitly quarantined until an independent rewrite.
#
# This guard cannot decide substantial similarity, fair use, trade mark
# confusion or legal clearance. docs/design/originality-boundary.md owns those
# human review gates.

set -euo pipefail

ART_DIRECTION="docs/art-direction"
POLICY="docs/design/originality-boundary.md"
STORY_PROPOSAL="docs/design/story-and-progression.md"
DEV_LOG="client/scripts/devlog.gd"
ARTGEN_ROOT="tools/artgen"

is_binary() {
	local file="$1" total stripped
	iconv -f UTF-8 -t UTF-8 <"$file" >/dev/null 2>&1 || return 0
	total=$(wc -c <"$file")
	stripped=$(LC_ALL=C tr -d '\000' <"$file" | wc -c)
	[ "$total" -ne "$stripped" ]
}

non_markdown_references=()
binary_references=()
binary_artgen_inputs=()
missing_contracts=()
player_reference_lines=()

if [ ! -d "$ART_DIRECTION" ]; then
	missing_contracts+=("$ART_DIRECTION is missing")
else
	while IFS= read -r -d '' file; do
		case "$file" in
		*.md) ;;
		*) non_markdown_references+=("$file") ;;
		esac
		if is_binary "$file"; then
			binary_references+=("$file")
		fi
	done < <(git ls-files -z -- "$ART_DIRECTION")
fi

if [ -d "$ARTGEN_ROOT" ]; then
	while IFS= read -r -d '' file; do
		if is_binary "$file"; then
			binary_artgen_inputs+=("$file")
		fi
	done < <(git ls-files -z -- "$ARTGEN_ROOT")
fi

[ -f "$POLICY" ] ||
	missing_contracts+=("$POLICY is missing")

if [ ! -f AGENTS.md ] || ! grep -Fq 'docs/design/originality-boundary.md' AGENTS.md; then
	missing_contracts+=("AGENTS.md does not link docs/design/originality-boundary.md")
fi

if [ ! -f "$ART_DIRECTION/README.md" ] ||
	! grep -Fq '../design/originality-boundary.md' "$ART_DIRECTION/README.md"; then
	missing_contracts+=("$ART_DIRECTION/README.md does not link ../design/originality-boundary.md")
fi

if [ ! -f "$STORY_PROPOSAL" ] || ! grep -Fq 'ORIGINALITY HOLD' "$STORY_PROPOSAL"; then
	missing_contracts+=("story proposal is missing ORIGINALITY HOLD")
fi

# These are internal comparison terms already used by the design corpus. They
# belong in docs and PR evidence, never in prose shown to a player. Keep the
# expression case-sensitive so ordinary words such as "wretch" remain usable.
if [ -f "$DEV_LOG" ]; then
	while IFS= read -r line; do
		player_reference_lines+=("$line")
	done < <(
		grep -nE \
			'World of Warcraft|WoW|WildStar|Guild Wars 2|Diablo IV|Elden Ring|Wretch reference|The Secret World|Numenera|Kingmakers|Fatekeeper|Horizon Zero Dawn|Planescape' \
			"$DEV_LOG" || true
	)
fi

failed=0

if [ ${#non_markdown_references[@]} -gt 0 ]; then
	failed=1
	echo "::error::art-direction references must stay link-only Markdown"
	printf '  - %s\n' "${non_markdown_references[@]}"
	echo
	echo "Link to an official source instead of committing its media. First-party World at"
	echo "Ruin frames belong under docs/evidence or docs/phase-0, never in the reference set."
	echo
fi

if [ ${#binary_references[@]} -gt 0 ]; then
	failed=1
	echo "::error::binary content under docs/art-direction is forbidden, regardless of extension"
	printf '  - %s\n' "${binary_references[@]}"
	echo
	echo "A renamed screenshot is still copied reference media. Keep the source view-only."
	echo
fi

if [ ${#binary_artgen_inputs[@]} -gt 0 ]; then
	failed=1
	echo "::error::binary reference input under tools/artgen is forbidden"
	printf '  - %s\n' "${binary_artgen_inputs[@]}"
	echo
	echo "Owned and CC0 inputs must use the sanctioned client/assets provenance path. Named-game"
	echo "screenshots, clips, audio, models and textures are never generator inputs."
	echo
fi

if [ ${#player_reference_lines[@]} -gt 0 ]; then
	failed=1
	echo "::error::third-party reference term in player-facing dev log"
	printf '  - %s\n' "${player_reference_lines[@]}"
	echo
	echo "Describe World at Ruin's own target or remaining gap without exposing the comparison title."
	echo
fi

if [ ${#missing_contracts[@]} -gt 0 ]; then
	failed=1
	echo "::error::originality contract is incomplete"
	printf '  - %s\n' "${missing_contracts[@]}"
	echo
	echo "The policy, agent link, art-direction link and story hold are one fail-closed boundary."
	echo
fi

[ "$failed" -eq 0 ] || exit 1

echo "originality-guard: OK — reference set is link-only Markdown; art generation has no binary reference inputs; player prose and policy anchors are clean."
