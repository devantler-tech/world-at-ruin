#!/usr/bin/env bash
# Originality guard — named games are view-only references, never source data.
#
# Copyright protects original expression, not the abstract game idea, rule or
# method of play. That boundary still requires human judgment; this script
# enforces only repository facts that are objective:
#
#   R1  docs/art-direction contains link-only UTF-8 Markdown. Downloaded
#       screenshots, clips, audio and other reference media do not enter the
#       repository, even with a misleading .md extension or text encoding.
#   R2  tools/artgen contains only reviewed source/configuration types. A
#       generator may consume owned/CC0 inputs under client/assets with
#       provenance, but never a copied screenshot, model or encoded media.
#   R3  the player-facing dev log does not expose internal third-party game
#       comparisons listed by the canonical reference-title inventory.
#   R4  the canonical originality policy is linked from both agent and art
#       direction contracts, and the currently high-risk story proposal stays
#       explicitly quarantined until an independent rewrite.
#   R5  tracked media outside client/assets is either the first-party app icon
#       or exact-byte-bound in the first-party capture manifest.
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
REFERENCE_TITLES="tools/originality-reference-titles.txt"
CAPTURE_MANIFEST="docs/first-party-captures.sha256"
REQUIRED_STORY_HOLD="ORIGINALITY HOLD (#359): DO NOT IMPLEMENT THE UNDYING WORK OR FORMER LIVES CONCEPT."

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
encoded_documentation_media=()
unsupported_artgen_inputs=()
unreviewed_media=()
invalid_capture_entries=()
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

# A copied payload remains reference media when moved elsewhere under docs.
# Scan repository documentation rather than trusting a directory name.
while IFS= read -r -d '' file; do
	if ! is_binary "$file" &&
		grep -Ein \
			'(<svg([[:space:]>])|data:(image|audio|video|model)/[^;,]+;base64,|[A-Za-z0-9+/]{128,}={0,2}|^[[:space:]]*(v|vn|vt|f)[[:space:]]+(-?[0-9]+([.][0-9]+)?[[:space:]]+){2})' \
			"$file" >/dev/null; then
		encoded_documentation_media+=("$file")
	fi
done < <(git ls-files -z -- docs)

if [ -d "$ARTGEN_ROOT" ]; then
	while IFS= read -r -d '' file; do
		if is_binary "$file"; then
			binary_artgen_inputs+=("$file")
		fi
		case "$file" in
		*.py | *.sh | *.md | *.json) ;;
		*) unsupported_artgen_inputs+=("$file") ;;
		esac
	done < <(git ls-files -z -- "$ARTGEN_ROOT")
fi

[ -f "$POLICY" ] ||
	missing_contracts+=("$POLICY is missing")

[ -f "$REFERENCE_TITLES" ] ||
	missing_contracts+=("$REFERENCE_TITLES is missing")

[ -f "$CAPTURE_MANIFEST" ] ||
	missing_contracts+=("$CAPTURE_MANIFEST is missing")

if [ ! -f AGENTS.md ] || ! grep -Fq 'docs/design/originality-boundary.md' AGENTS.md; then
	missing_contracts+=("AGENTS.md does not link docs/design/originality-boundary.md")
fi

if [ ! -f "$ART_DIRECTION/README.md" ] ||
	! grep -Fq '../design/originality-boundary.md' "$ART_DIRECTION/README.md"; then
	missing_contracts+=("$ART_DIRECTION/README.md does not link ../design/originality-boundary.md")
fi

if [ ! -f "$STORY_PROPOSAL" ] || ! grep -Fq "$REQUIRED_STORY_HOLD" "$STORY_PROPOSAL"; then
	missing_contracts+=("story proposal is missing the exact ORIGINALITY HOLD directive")
fi

# Internal comparison terms belong in docs and PR evidence, never in prose
# shown to a player. Keep matching case-sensitive so ordinary words remain
# available. The inventory is reviewed beside the policy's reference audit.
if [ -f "$DEV_LOG" ] && [ -f "$REFERENCE_TITLES" ]; then
	while IFS= read -r title || [ -n "$title" ]; do
		case "$title" in
		"" | \#*) continue ;;
		esac
		while IFS= read -r line; do
			player_reference_lines+=("$line")
		done < <(grep -nF "$title" "$DEV_LOG" || true)
	done <"$REFERENCE_TITLES"
fi

# Asset provenance owns client/assets. The app icon is reviewed source art.
# Every other tracked media/model file must match the first-party capture
# manifest exactly, so adding a screenshot is a visible, reviewable act.
while IFS= read -r -d '' file; do
	lower_file=$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')
	case "$lower_file" in
	*.png | *.jpg | *.jpeg | *.gif | *.webp | *.bmp | *.tif | *.tiff | *.svg | \
		*.mp3 | *.wav | *.ogg | *.flac | *.mp4 | *.mov | *.webm | \
		*.gltf | *.glb | *.fbx | *.obj | *.blend)
		case "$file" in
		client/assets/* | client/icon.svg) continue ;;
		esac
		if [ ! -f "$CAPTURE_MANIFEST" ]; then
			unreviewed_media+=("$file")
			continue
		fi
		hash=$(shasum -a 256 "$file" | awk '{print $1}')
		grep -Fqx "$hash  $file" "$CAPTURE_MANIFEST" ||
			unreviewed_media+=("$file")
		;;
	esac
done < <(git ls-files -z)

if [ -f "$CAPTURE_MANIFEST" ]; then
	while IFS= read -r entry || [ -n "$entry" ]; do
		case "$entry" in
		"" | \#*) continue ;;
		esac
		hash=${entry%%  *}
		file=${entry#*  }
		if [ "$file" = "$entry" ] || [ ! -f "$file" ] ||
			[ "$(shasum -a 256 "$file" | awk '{print $1}')" != "$hash" ]; then
			invalid_capture_entries+=("$entry")
		fi
	done <"$CAPTURE_MANIFEST"
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

if [ ${#encoded_documentation_media[@]} -gt 0 ]; then
	failed=1
	echo "::error::encoded or inline media in repository documentation is forbidden"
	printf '  - %s\n' "${encoded_documentation_media[@]}"
	echo
	echo "Documentation may contain prose and external links, never inline SVG, encoded media or"
	echo "text-encoded model data."
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

if [ ${#unsupported_artgen_inputs[@]} -gt 0 ]; then
	failed=1
	echo "::error::unsupported tracked input under tools/artgen"
	printf '  - %s\n' "${unsupported_artgen_inputs[@]}"
	echo
	echo "Keep generator implementation and configuration here. Models, media and other source"
	echo "inputs belong under the exact-byte-bound client/assets provenance contract."
	echo
fi

if [ ${#unreviewed_media[@]} -gt 0 ]; then
	failed=1
	echo "::error::tracked media is outside a reviewed provenance boundary"
	printf '  - %s\n' "${unreviewed_media[@]}"
	echo
	echo "Use client/assets with asset provenance, or record a first-party World at Ruin capture"
	echo "by exact SHA-256 in $CAPTURE_MANIFEST."
	echo
fi

if [ ${#invalid_capture_entries[@]} -gt 0 ]; then
	failed=1
	echo "::error::first-party capture manifest contains stale or invalid entries"
	printf '  - %s\n' "${invalid_capture_entries[@]}"
	echo
	echo "Each entry must be: <sha256><two spaces><tracked repository-relative path>."
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

echo "originality-guard: OK — references stay external; generator inputs and tracked media are provenance-bound; player prose and policy anchors are clean."
