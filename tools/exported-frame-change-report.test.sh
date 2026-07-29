#!/usr/bin/env bash
# Proves the exported-frame change report renders the base EXPORT rather than
# the editor project, seeds that capture from the base tree, remains advisory
# when the base cannot render, and is wired into the exported capture job.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORTER="$ROOT/tools/exported-frame-change-report.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"

failures=0
SCRATCH_DIR=''

t_fail() {
	printf 'exported frame change report test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

cleanup() {
	[ -n "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT

if [ ! -x "$REPORTER" ]; then
	t_fail "production reporter is missing or not executable"
	printf 'exported frame change report test: %d failure(s)\n' "$failures" >&2
	exit 1
fi

SCRATCH_DIR="$(mktemp -d)"
FIXTURE="$SCRATCH_DIR/repo"
FAKE_BIN="$SCRATCH_DIR/bin"
mkdir -p "$FIXTURE/client/recipes" "$FAKE_BIN"

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email t@example.com
git -C "$FIXTURE" config user.name t
printf 'BASE\n' > "$FIXTURE/client/recipes/wanderer.json"
printf '[application]\nconfig/name="fixture"\n' > "$FIXTURE/client/project.godot"
printf '[preset.0]\nname="macOS"\n' > "$FIXTURE/client/export_presets.cfg"
git -C "$FIXTURE" add client
git -C "$FIXTURE" commit -q -m base
BASE_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"

# The head recipe deliberately differs. A reporter that seeds the base capture
# from the head tree makes the fake exported app refuse, which catches the same
# false-diff bug that the editor report already guards against.
printf 'HEAD\n' > "$FIXTURE/client/recipes/wanderer.json"
git -C "$FIXTURE" add client/recipes/wanderer.json
git -C "$FIXTURE" commit -q -m head

cat > "$FAKE_BIN/godot" <<'FAKE_GODOT'
#!/usr/bin/env bash
set -euo pipefail

export_path=''
while [ "$#" -gt 0 ]; do
	if [ "$1" = "--export-release" ]; then
		shift
		[ "$#" -gt 0 ] && shift
		[ "$#" -gt 0 ] || exit 2
		export_path="$1"
		break
	fi
	if [ "$1" = "res://tools/frame_diff.tscn" ]; then
		printf 'DIFF exported_world — changed 45.67%% of pixels, mean |dRGB| 0.0123, max 0.5000\n'
		printf 'UNCOMPARED: head-only.png\n'
		printf 'DIFF PASS (1 frame(s))\n'
		exit 0
	fi
	shift
done

if [ -z "$export_path" ]; then
	printf 'FAKE IMPORT PASS\n'
	exit 0
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/World at Ruin.app/Contents/MacOS/World at Ruin"
mkdir -p "$(dirname "$app")" "$(dirname "$export_path")"
cat > "$app" <<'FAKE_APP'
#!/usr/bin/env bash
set -euo pipefail
if [ "${WAR_SCENARIO:-}" != "first_run" ] &&
		! grep -Fxq BASE "$WAR_SAVE_PATH"; then
	printf 'ERROR: base export received the head recipe\n' >&2
	exit 2
fi
mkdir -p "$WAR_SHOT_DIR"
if [ "${WAR_SCENARIO:-}" = "first_run" ]; then
	dd if=/dev/zero of="$WAR_SHOT_DIR/first_run.png" bs=1024 count=12 2>/dev/null
	printf 'base exported first-run frame\n' > "$WAR_SHOT_DIR/first_run.txt"
	printf '1 first-run vantage written\n'
else
	dd if=/dev/zero of="$WAR_SHOT_DIR/exported_world.png" bs=1024 count=12 2>/dev/null
	printf 'base exported frame\n' > "$WAR_SHOT_DIR/exported_world.txt"
fi
printf 'VOLUMETRICS off\n'
printf 'HOLLOW FOG off\n'
printf 'BOOT_OK vtest\n'
if [ "${FAKE_GODOT_BAD_CAPTURE:-0}" != "1" ]; then
	printf 'CAPTURE PASS\n'
fi
FAKE_APP
chmod +x "$app"
(cd "$stage" && zip -qr "$export_path" "World at Ruin.app")
FAKE_GODOT
chmod +x "$FAKE_BIN/godot"

WORK="$SCRATCH_DIR/report"
if ! render_output="$(
	cd "$FIXTURE" &&
		PATH="$FAKE_BIN:$PATH" "$REPORTER" render-base "$BASE_SHA" "$WORK" 2>&1
)"; then
	t_fail "a valid base export and capture should succeed: $render_output"
fi
if [ ! -s "$WORK/exported-shots-base/exported_world.png" ]; then
	t_fail "render-base did not produce the exported base frame"
fi
if [ ! -f "$WORK/probe_save_base.json" ] ||
		! grep -Fxq BASE "$WORK/probe_save_base.json"; then
	t_fail "render-base did not seed the capture from the base tree's recipe"
fi
if ! printf '%s\n' "$render_output" | grep -qE 'ADDED CI COST: base export and capture [0-9]+s'; then
	t_fail "render-base did not report the added CI cost"
fi

# Missing CAPTURE PASS is a real base-render failure. The production script
# must return non-zero so the workflow can annotate it through an explicitly
# advisory step rather than quietly treating an empty base as evidence.
BAD_WORK="$SCRATCH_DIR/bad-report"
if (
	cd "$FIXTURE" &&
		FAKE_GODOT_BAD_CAPTURE=1 PATH="$FAKE_BIN:$PATH" \
			"$REPORTER" render-base "$BASE_SHA" "$BAD_WORK"
) >/dev/null 2>&1; then
	t_fail "render-base accepted an exported app that never reported CAPTURE PASS"
fi

HEAD_SHOTS="$SCRATCH_DIR/head-shots"
mkdir -p "$HEAD_SHOTS"
dd if=/dev/zero of="$HEAD_SHOTS/exported_world.png" bs=1024 count=12 2>/dev/null

if ! report_output="$(
	cd "$FIXTURE" &&
		PATH="$FAKE_BIN:$PATH" "$REPORTER" report "$WORK" "$HEAD_SHOTS" 2>&1
)"; then
	t_fail "the reporting phase must remain advisory: $report_output"
fi
if ! printf '%s\n' "$report_output" | grep -q 'DIFF PASS'; then
	t_fail "report did not run the real frame-diff entry point"
fi
if ! printf '%s\n' "$report_output" |
		grep -q 'DIFF exported_world.*changed 45.67%'; then
	t_fail "report did not preserve the exported frame's non-zero measurement"
fi
if ! printf '%s\n' "$report_output" |
		grep -q '::warning::some exported-client frames carry no base comparison'; then
	t_fail "report did not surface UNCOMPARED exported frames as an annotation"
fi

if ! missing_output="$(
	cd "$FIXTURE" &&
		PATH="$FAKE_BIN:$PATH" "$REPORTER" report "$SCRATCH_DIR/missing" "$HEAD_SHOTS" 2>&1
)"; then
	t_fail "a missing base must warn without failing the required job"
fi
if ! printf '%s\n' "$missing_output" |
		grep -q '::warning::no exported base frames'; then
	t_fail "a missing base produced no explicit warning"
fi

# The behavior above earns no value if the exported capture job never calls it.
exported_block="$(sed -n '/^  frame-capture-exported:/,/^  ci-required-checks:/p' "$WORKFLOW")"
export_gate="$(sed -n '/# Export-affecting paths get a THIRD/,/# A FOURTH gate/p' "$WORKFLOW")"
if ! printf '%s\n' "$exported_block" |
		grep -q 'tools/exported-frame-change-report\.sh render-base'; then
	t_fail "frame-capture-exported does not render the base through the tested reporter"
fi
if ! printf '%s\n' "$exported_block" |
		grep -q 'tools/exported-frame-change-report\.sh report'; then
	t_fail "frame-capture-exported does not publish the tested change report"
fi
if ! printf '%s\n' "$exported_block" | grep -q 'fetch-depth: 0'; then
	t_fail "frame-capture-exported cannot reach the PR base because its checkout is shallow"
fi
if ! printf '%s\n' "$exported_block" |
		grep -q 'ADDED CI COST: base Godot and templates install'; then
	t_fail "the added Godot and export-template installation cost is not recorded"
fi
if ! printf '%s\n' "$export_gate" |
		grep -Fq '^client/(project\.godot|export_presets\.cfg)$' ||
		! printf '%s\n' "$export_gate" | grep -q 'export_affecting=true'; then
	t_fail "an export-presets-only change does not select the exported capture and comparison"
fi
if ! grep -q './tools/exported-frame-change-report.test.sh' "$WORKFLOW"; then
	t_fail "the reporter regression test is not wired into ci.yaml"
fi

if [ "$failures" -ne 0 ]; then
	printf 'exported frame change report test: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf 'exported frame change report test: OK\n'
