#!/usr/bin/env bash
# Native exported base + cumulative overlay, with an executable no-mount ablation.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# shellcheck source=tools/contentpack-native.sh
source "$root/tools/contentpack-native.sh"
probe=$(mktemp -d)
trap 'rm -rf -- "$probe"' EXIT
go -C "$root/server" build -o "$probe/contentpack" ./cmd/contentpack
fixture="$probe/fixture"
mkdir -p "$fixture/assets" "$fixture/scenes" "$fixture/scripts/shell"
cat > "$fixture/project.godot" <<'PROJECT'
config_version=5
[application]
config/name="Content pack proof"
run/main_scene="res://scenes/proof.tscn"
[rendering]
renderer/rendering_method="gl_compatibility"
PROJECT
cat > "$fixture/export_presets.cfg" <<'PRESET'
[preset.0]
name="Fixture"
platform="macOS"
runnable=true
export_filter="all_resources"
include_filter="*.txt"
exclude_filter=""
export_path=""
[preset.0.options]
codesign/codesign=0
PRESET
cat > "$fixture/scenes/proof.tscn" <<'SCENE'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/shell/proof.gd" id="1"]
[node name="Proof" type="Node"]
script = ExtResource("1")
SCENE
cp "$root/tools/contentpack-mount-probe.gd" "$fixture/scripts/shell/proof.gd"
cat > "$fixture/scripts/boot_recovery.gd" <<'RECOVERY'
extends RefCounted
static func identity() -> String:
	return "base recovery"
RECOVERY
printf 'immutable recovery\n' > "$fixture/scripts/shell/identity.txt"
cat > "$fixture/assets/material.tres" <<'MATERIAL'
[gd_resource type="StandardMaterial3D" format=3]
[resource]
resource_name = "base"
MATERIAL
run_native "$probe/import-base.log" --headless --editor --import --path "$fixture"
run_native "$probe/export.log" --headless --path "$fixture" --export-pack Fixture "$probe/base.pck"
test -s "$probe/base.pck"
printf 'candidate must not replace recovery\n' > "$fixture/scripts/shell/identity.txt"
sed 's/base recovery/candidate recovery/' "$fixture/scripts/boot_recovery.gd" > "$probe/recovery.new"
mv "$probe/recovery.new" "$fixture/scripts/boot_recovery.gd"
printf '[remap]\npath="res://assets/hijack.gd"\n' > "$fixture/scripts/boot_recovery.gd.remap"
cat > "$fixture/assets/hijack.gd" <<'HIJACK'
extends RefCounted
static func identity() -> String:
	return "candidate recovery"
HIJACK
test ! -e "$fixture/assets/hijack.gd.uid"
sed 's/resource_name = "base"/resource_name = "candidate"/' "$fixture/assets/material.tres" > "$probe/material.new"
mv "$probe/material.new" "$fixture/assets/material.tres"
printf 'new cumulative content\n' > "$fixture/assets/added.txt"
# Native generation keeps the temporary image out of repository text and assets.
cat > "$probe/create-texture.gd" <<'TEXTURE'
extends SceneTree
func _initialize() -> void:
	var image := Image.create(3, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	if image.save_png("res://assets/pixel.png") != OK:
		quit(1)
		return
	quit(0)
TEXTURE
run_native "$probe/texture.log" --headless --path "$fixture" --script "$probe/create-texture.gd"
test -s "$fixture/assets/pixel.png"
if bash "$root/tools/build-contentpack.sh" "$fixture" "$probe/default-off"; then
 echo 'content pack builder ran without opt-in' >&2; exit 1
fi
test ! -e "$probe/default-off"
for build in one two; do
 bash "$root/tools/build-contentpack.sh" --experimental "$fixture" "$probe/$build"
 "$probe/contentpack" -experimental -operation verify -output "$probe/$build"
done
cmp "$probe/one/content.pck" "$probe/two/content.pck"
cmp "$probe/one/receipt.json" "$probe/two/receipt.json"
run_native "$probe/mount.log" --headless --main-pack "$probe/base.pck" -- "$probe/one/content.pck"
grep -q 'PACK MOUNT PASS' "$probe/mount.log"
if grep -qE 'SCRIPT ERROR|^ERROR:' "$probe/mount.log"; then exit 1; fi
if run_native "$probe/ablate.log" --headless --main-pack "$probe/base.pck" -- "$probe/one/content.pck" ablate; then
 echo 'overlay proof remained green when loading was removed' >&2; exit 1
fi
grep -q 'PACK MOUNT REFUSED' "$probe/ablate.log"
printf 'caller-owned' > "$probe/existing"
if bash "$root/tools/build-contentpack.sh" --experimental "$fixture" "$probe/existing"; then exit 1; fi
test "$(cat "$probe/existing")" = caller-owned
printf 'unsupported shape' > "$fixture/assets/refused.exe"
if bash "$root/tools/build-contentpack.sh" --experimental "$fixture" "$probe/failed"; then exit 1; fi
test ! -e "$probe/failed"
cat > "$probe/hang.gd" <<'HANG'
extends SceneTree
func _initialize() -> void:
	print("NATIVE HANG CONTROL STARTED")
	while true:
		pass
HANG
if CONTENTPACK_NATIVE_TIMEOUT_SECONDS=1 run_native "$probe/hang.log" --headless --path "$fixture" --script "$probe/hang.gd"; then
 echo 'hung native process escaped its time budget' >&2; exit 1
fi
grep -q 'NATIVE HANG CONTROL STARTED' "$probe/hang.log"
test -f "$probe/hang.log.timeout"
printf 'altered pack' >> "$probe/one/content.pck"
if "$probe/contentpack" -experimental -operation verify -output "$probe/one"; then
 echo 'altered pack receipt verified' >&2; exit 1
fi
echo 'TEST PASS — native cumulative build, deterministic bytes, protected shell, receipt and no-mount ablation'
