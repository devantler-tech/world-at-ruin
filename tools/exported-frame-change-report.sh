#!/usr/bin/env bash
# Render the pull request base as a macOS export, then report how the current
# exported-client frames differ from it. The report is advisory by design:
# callers make render-base continue-on-error, and report always explains when
# it cannot compare rather than failing the required capture job.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_timed() {
	local seconds="$1"
	shift
	perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}

usage() {
	printf 'usage: %s render-base <base-sha> <work-dir>\n' "$0" >&2
	printf '       %s report <work-dir> <head-shots-dir>\n' "$0" >&2
	exit 2
}

render_base() {
	local base_sha="$1" work_dir="$2"
	local started base_dir build_dir base_shots app_path elapsed capture_resolution
	started="$(date +%s)"
	base_dir="$work_dir/base"
	build_dir="$work_dir/base-build"
	base_shots="$work_dir/exported-shots-base"
	capture_resolution="${EXPORTED_CAPTURE_RESOLUTION:-1024x576}"

	if ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
		printf '::warning::PR base %s is unavailable; exported frames will carry no base comparison\n' "$base_sha" >&2
		return 1
	fi
	if ! command -v perl >/dev/null 2>&1; then
		printf '::warning::Perl is unavailable; the advisory base export cannot be bounded safely\n' >&2
		return 1
	fi

	mkdir -p "$work_dir" "$build_dir" "$base_shots"
	git worktree add --detach "$base_dir" "$base_sha"

	run_timed 600 godot --headless --editor --quit --path "$base_dir/client" 2>&1 |
		tee "$work_dir/base-import.log"
	run_timed 600 godot --headless --export-release "macOS" "$build_dir/WorldAtRuin.zip" \
		--path "$base_dir/client" 2>&1 | tee "$work_dir/base-export.log"
	if grep -qE 'SCRIPT ERROR|^ERROR' \
		"$work_dir/base-import.log" "$work_dir/base-export.log"; then
		printf '::warning::the PR base reported errors during import or export\n' >&2
		return 1
	fi
	if [ ! -s "$build_dir/WorldAtRuin.zip" ]; then
		printf '::warning::the PR base produced no macOS export\n' >&2
		return 1
	fi

	unzip -q "$build_dir/WorldAtRuin.zip" -d "$build_dir/app"
	app_path="$build_dir/app/World at Ruin.app/Contents/MacOS/World at Ruin"
	if [ ! -x "$app_path" ]; then
		printf '::warning::the PR base export contains no runnable macOS client\n' >&2
		return 1
	fi

	# Seed from the BASE tree. Using the head recipe would render the old game
	# with proposed player data and attribute that unrelated mismatch to the PR.
	if ! cp "$base_dir/client/recipes/wanderer.json" "$work_dir/probe_save_base.json"; then
		printf '::warning::could not seed the base export from its own wanderer recipe\n' >&2
		return 1
	fi

	# The exact-head #620 hosted run needed 296s for this same world capture;
	# the original 180s bound killed a healthy base render and left every head
	# frame uncompared. Keep roughly 40% measured headroom while still bounding
	# an old export that boots the wrong path and never exits.
	run_timed 420 env \
		WAR_CAPTURE=1 \
		WAR_SHOT_DIR="$base_shots" \
		WAR_SAVE_PATH="$work_dir/probe_save_base.json" \
		WAR_VAULT_PATH="$work_dir/probe_save_base_vault.json" \
		WAR_BOOT_RECOVERY_PATH="$work_dir/probe_save_base_recovery.json" \
		"$app_path" --resolution "$capture_resolution" 2>&1 |
		tee "$work_dir/base-exported-capture.log"
	if ! grep -q 'CAPTURE PASS' "$work_dir/base-exported-capture.log"; then
		printf '::warning::the PR base export did not report CAPTURE PASS\n' >&2
		return 1
	fi
	if ! grep -q 'BOOT_OK' "$work_dir/base-exported-capture.log"; then
		printf '::warning::the PR base export did not reach BOOT_OK\n' >&2
		return 1
	fi
	grep -vE 'timeout waiting for fence|drivers/metal/rendering_device_driver_metal' \
		"$work_dir/base-exported-capture.log" > "$work_dir/base-exported-capture.filtered.log" || true
	if grep -qE 'SCRIPT ERROR|^ERROR' "$work_dir/base-exported-capture.filtered.log"; then
		printf '::warning::the PR base export reported runtime errors during capture\n' >&2
		return 1
	fi

	# The head job always captures first-run UI because export-only filtering can
	# affect it independently of the seeded-save world. Render the same scenario
	# from the base so those player-visible frames receive measurements too.
	run_timed 180 env \
		WAR_CAPTURE=1 \
		WAR_SCENARIO=first_run \
		WAR_LAYERED_OUTFIT_PICKERS=1 \
		WAR_SHOT_DIR="$base_shots" \
		WAR_SAVE_PATH="$work_dir/no_such_save_base.json" \
		WAR_VAULT_PATH="$work_dir/no_such_save_base_vault.json" \
		WAR_BOOT_RECOVERY_PATH="$work_dir/no_such_save_base_recovery.json" \
		"$app_path" --resolution "$capture_resolution" 2>&1 |
		tee "$work_dir/base-exported-first-run.log"
	if ! grep -qE '[0-9]+ first-run vantages? written' \
		"$work_dir/base-exported-first-run.log"; then
		printf '::warning::the PR base export did not render its first-run UI\n' >&2
		return 1
	fi
	if ! grep -q 'BOOT_OK' "$work_dir/base-exported-first-run.log"; then
		printf '::warning::the PR base first-run capture did not reach BOOT_OK\n' >&2
		return 1
	fi
	grep -vE 'timeout waiting for fence|drivers/metal/rendering_device_driver_metal' \
		"$work_dir/base-exported-first-run.log" > "$work_dir/base-exported-first-run.filtered.log" || true
	if grep -qE 'SCRIPT ERROR|^ERROR' "$work_dir/base-exported-first-run.filtered.log"; then
		printf '::warning::the PR base export reported runtime errors during its first-run capture\n' >&2
		return 1
	fi

	elapsed=$(( $(date +%s) - started ))
	printf 'ADDED CI COST: base export and capture %ss\n' "$elapsed"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			printf '### Exported-client base comparison\n\n'
			printf 'Base export and capture: **%ss** (reporting only).\n' "$elapsed"
		} >> "$GITHUB_STEP_SUMMARY"
	fi
}

report() {
	local work_dir="$1" head_shots="$2"
	local base_shots="$work_dir/exported-shots-base"
	local diff_log="$work_dir/exported-frame-diff.log"
	local diff_status

	if [ ! -d "$base_shots" ] ||
		[ -z "$(find "$base_shots" -name '*.png' -print -quit 2>/dev/null)" ]; then
		printf '::warning::no exported base frames; this PR'\''s exported frames carry no change measurement\n'
		return 0
	fi
	if [ ! -d "$head_shots" ]; then
		printf '::warning::no exported head frames; the required capture should have failed before this report\n'
		return 0
	fi

	set +e
	run_timed 180 env \
		WAR_DIFF_BASE="$base_shots" \
		WAR_DIFF_HEAD="$head_shots" \
		godot --headless --path "$ROOT/client" res://tools/frame_diff.tscn 2>&1 |
		tee "$diff_log"
	diff_status="${PIPESTATUS[0]}"
	set -e

	if [ "$diff_status" -ne 0 ] || ! grep -q 'DIFF PASS' "$diff_log"; then
		printf '::warning::the exported-client change report did not complete; these frames carry no reliable base comparison\n'
	fi
	if grep -q 'REMOVED:' "$diff_log"; then
		printf '::warning::an exported vantage present in the base is missing from this PR'\''s capture; see the REMOVED lines\n'
	fi
	if grep -q 'UNCOMPARED:' "$diff_log"; then
		printf '::warning::some exported-client frames carry no base comparison and are NOT evidence for this PR; see the UNCOMPARED line\n'
	fi
	return 0
}

case "${1:-}" in
	render-base)
		[ "$#" -eq 3 ] || usage
		render_base "$2" "$3"
		;;
	report)
		[ "$#" -eq 3 ] || usage
		report "$2" "$3"
		;;
	*)
		usage
		;;
esac
