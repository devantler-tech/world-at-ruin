#!/usr/bin/env bash
# Proves the lavapipe evidence lane refuses every confident-wrong capture:
# a non-Vulkan renderer, an off/ambiguous GPU verdict, zero hollow volumes,
# runtime/shader errors, or a run that emitted no inspectable frame.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/tools/lavapipe-capture-guard.sh"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

failures=0

t_fail() {
	printf 'lavapipe capture guard test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

make_valid_fixture() {
	local name="$1"
	local fixture="$SCRATCH_DIR/$name"
	mkdir -p "$fixture/shots"
	cat >"$fixture/capture.log" <<'EOF'
Godot Engine v4.7.1.stable.official
Vulkan 1.4.318 - Forward+ - Using Device #0: llvmpipe (LLVM 20.1.2, 256 bits)
VOLUMETRICS on — R32_Uint atomic storage image supported
HOLLOW FOG on — 3 drifting ash pools
BOOT_OK vdev
CAPTURE PASS — 4 vantages written
EOF
	printf 'not-a-real-png-but-nonempty' >"$fixture/shots/world.png"
	printf '%s' "$fixture"
}

expect_pass() {
	local label="$1" fixture="$2"
	if ! "$GUARD" "$fixture/capture.log" "$fixture/shots" >"$fixture/stdout" 2>"$fixture/stderr"; then
		t_fail "$label was refused: $(cat "$fixture/stderr")"
	fi
}

expect_refusal() {
	local label="$1" fixture="$2"
	if "$GUARD" "$fixture/capture.log" "$fixture/shots" >"$fixture/stdout" 2>"$fixture/stderr"; then
		t_fail "$label was accepted — the lane would publish evidence it did not produce"
	elif [ ! -s "$fixture/stderr" ]; then
		t_fail "$label was refused without a diagnostic"
	fi
}

valid="$(make_valid_fixture valid)"
expect_pass "a Vulkan capture with enabled volumetrics, three pools and a frame" "$valid"

non_vulkan="$(make_valid_fixture non-vulkan)"
sed -i.bak '/Vulkan .*Using Device/d' "$non_vulkan/capture.log"
expect_refusal "a capture with no Vulkan device proof" "$non_vulkan"

wrong_device="$(make_valid_fixture wrong-device)"
sed -i.bak 's/llvmpipe (LLVM 20.1.2, 256 bits)/SwiftShader Device/' "$wrong_device/capture.log"
expect_refusal "a Vulkan capture that did not use lavapipe" "$wrong_device"

probe_off="$(make_valid_fixture probe-off)"
sed -i.bak 's/VOLUMETRICS on.*/VOLUMETRICS off — unsupported/' "$probe_off/capture.log"
expect_refusal "the fallback volumetric path" "$probe_off"

probe_ambiguous="$(make_valid_fixture probe-ambiguous)"
printf '%s\n' 'VOLUMETRICS off — contradictory fallback' >>"$probe_ambiguous/capture.log"
expect_refusal "contradictory volumetric verdicts" "$probe_ambiguous"

no_pools="$(make_valid_fixture no-pools)"
sed -i.bak 's/HOLLOW FOG on.*/HOLLOW FOG off — no pools/' "$no_pools/capture.log"
expect_refusal "a world with no built hollow fog" "$no_pools"

zero_pools="$(make_valid_fixture zero-pools)"
sed -i.bak 's/HOLLOW FOG on — 3/HOLLOW FOG on — 0/' "$zero_pools/capture.log"
expect_refusal "an enabled marker reporting zero pools" "$zero_pools"

runtime_error="$(make_valid_fixture runtime-error)"
printf '%s\n' 'SCRIPT ERROR: Invalid call' >>"$runtime_error/capture.log"
expect_refusal "a capture containing a script error" "$runtime_error"

shader_error="$(make_valid_fixture shader-error)"
printf '%s\n' 'SHADER ERROR: compilation failed' >>"$shader_error/capture.log"
expect_refusal "a capture containing a shader error" "$shader_error"

no_pass="$(make_valid_fixture no-pass)"
sed -i.bak '/CAPTURE PASS/d' "$no_pass/capture.log"
expect_refusal "a run without the positive capture marker" "$no_pass"

no_boot="$(make_valid_fixture no-boot)"
sed -i.bak '/BOOT_OK/d' "$no_boot/capture.log"
expect_refusal "a run that never completed the real boot path" "$no_boot"

no_frames="$(make_valid_fixture no-frames)"
rm "$no_frames/shots/world.png"
expect_refusal "a capture with no non-empty PNG" "$no_frames"

if [ "$failures" -ne 0 ]; then
	printf 'lavapipe capture guard test: %d failure(s)\n' "$failures" >&2
	exit 1
fi

printf 'lavapipe capture guard test: OK\n'
