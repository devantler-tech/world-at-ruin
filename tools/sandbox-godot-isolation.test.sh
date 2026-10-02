#!/usr/bin/env bash
# Exercise the real engine under the same containment as the product gate.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/work/client/tests"
mkdir -p "$tmp/work/server/wire" "$tmp/work/.github/workflows"
printf 'source data\n' >"$tmp/work/server/wire/wire.go"
printf 'source data\n' >"$tmp/work/.github/workflows/ci.yaml"
printf 'host-only sentinel\n' >"$tmp/host-only"
cat >"$tmp/work/client/project.godot" <<'PROJECT'
config_version=5
[application]
config/name="Trusted runtime isolation probe"
[rendering]
renderer/rendering_method="gl_compatibility"
PROJECT
cat >"$tmp/work/client/tests/probe.gd" <<'GODOT'
extends SceneTree

func _initialize() -> void:
	var failures := []
	for source in ["res://../server/wire/wire.go", "res://../.github/workflows/ci.yaml"]:
		if FileAccess.get_file_as_string(source) != "source data\n":
			failures.append("readonly source data unavailable")
		if FileAccess.open(source, FileAccess.WRITE) != null:
			failures.append("source data writable")
	if OS.get_environment("GITHUB_TOKEN") != "":
		failures.append("inherited host credential environment")
	if FileAccess.file_exists("HOST_SENTINEL"):
		failures.append("host workspace exposed")
	if FileAccess.file_exists("/var/run/docker.sock"):
		failures.append("host Docker socket")
	if FileAccess.open("res://tests/probe.gd", FileAccess.WRITE) != null:
		failures.append("trusted harness writable")
	var output := []
	if OS.execute("/bin/sh", ["-c", "printf rewritten > /project/client/tests/probe.gd"], output, true) == 0:
		failures.append("child process rewrote trusted harness")
	# Inspect kernel interfaces; Godot can list alternate loopback spellings.
	var interfaces := []
	OS.execute("/bin/sh", ["-c", "ls /sys/class/net"], interfaces)
	if interfaces.size() != 1 or str(interfaces[0]).strip_edges() != "lo":
		failures.append("external network interface")
	var routes := []
	OS.execute("/bin/cat", ["/proc/net/route"], routes)
	if routes.size() != 1 or str(routes[0]).strip_edges().split("\n").size() != 1:
		failures.append("external network route")
	output.clear()
	OS.execute("/usr/bin/id", ["-u"], output)
	if str(output[0]).strip_edges() == "0":
		failures.append("root execution")
	output.clear()
	OS.execute("/bin/cat", ["/proc/self/status"], output)
	var status := str(output[0])
	if not status.contains("CapEff:\t0000000000000000") or not status.contains("NoNewPrivs:\t1"):
		failures.append("capabilities or privilege escalation")
	if FileAccess.open("/tmp/private-state", FileAccess.WRITE) == null:
		failures.append("private state unavailable")
	if not failures.is_empty():
		print("TEST FAIL -- sandbox isolation: ", failures)
		quit(1)
		return
	print("TEST PASS -- real sandbox refuses harness writes, host credentials and external networking")
	quit(0)
GODOT
sed -i "s|HOST_SENTINEL|$tmp/host-only|" "$tmp/work/client/tests/probe.gd"
original="$(sha256sum "$tmp/work/client/tests/probe.gd" | cut -d' ' -f1)"
GOTOOLCHAIN=local GOWORK=off go build -o "$tmp/cache-guard" "$root/tools/trusted-regression-cache.go"
export GODOT_SANDBOX_CACHE_GUARD="$tmp/cache-guard"
image="$(bash "$root/tools/build-trusted-regression-runtime.sh")"
cd "$tmp/work"
probe_failure() {
  cat "$tmp/import.log" "$tmp/run.log" 2>/dev/null || true
  exit 1
}
GODOT_SANDBOX_IMAGE="$image" GITHUB_TOKEN=host-only-sentinel \
  bash "$root/tools/sandbox-godot.sh" --headless --editor --quit --path client >"$tmp/import.log" 2>&1 || probe_failure
GODOT_SANDBOX_IMAGE="$image" GITHUB_TOKEN=host-only-sentinel \
  bash "$root/tools/sandbox-godot.sh" --headless --path client --script res://tests/probe.gd >"$tmp/run.log" 2>&1 || probe_failure
grep -q 'TEST PASS -- real sandbox refuses' "$tmp/run.log" || probe_failure
if grep -Eq 'TEST FAIL|SCRIPT ERROR|^ERROR' "$tmp/import.log" "$tmp/run.log"; then
  cat "$tmp/import.log" "$tmp/run.log"
  exit 1
fi
test "$(sha256sum client/tests/probe.gd | cut -d' ' -f1)" = "$original"
test "$(cat "$tmp/host-only")" = 'host-only sentinel'
echo 'TEST PASS -- real runtime containment and immutable harness readback'

# Exercise the production controller and every real scene under that same boundary.
# This candidate-controlled CI trial is evidence, not the base-owned required verdict.
bash "$root/tools/run-sandboxed-trusted-regressions.sh" "$root" "$root"
