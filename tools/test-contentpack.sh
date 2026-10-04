#!/usr/bin/env bash
# Native exported base + cumulative overlay, with an executable no-mount ablation.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
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
godot --headless --editor --import --path "$fixture" > "$probe/import-base.log" 2>&1
godot --headless --path "$fixture" --export-pack Fixture "$probe/base.pck" > "$probe/export.log" 2>&1
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
cat > "$fixture/assets/pixel.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="3" height="2"><rect width="3" height="2" fill="red"/></svg>
SVG
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
mount_status=0
godot --headless --main-pack "$probe/base.pck" -- "$probe/one/content.pck" > "$probe/mount.log" 2>&1 || mount_status=$?
cat "$probe/mount.log"
if [ "$mount_status" -ne 0 ]; then exit "$mount_status"; fi
grep -q 'PACK MOUNT PASS' "$probe/mount.log"
if grep -qE 'SCRIPT ERROR|^ERROR:' "$probe/mount.log"; then exit 1; fi
if godot --headless --main-pack "$probe/base.pck" -- "$probe/one/content.pck" ablate > "$probe/ablate.log" 2>&1; then
 echo 'overlay proof remained green when loading was removed' >&2; exit 1
fi
grep -q 'PACK MOUNT REFUSED' "$probe/ablate.log"
printf 'caller-owned' > "$probe/existing"
if bash "$root/tools/build-contentpack.sh" --experimental "$fixture" "$probe/existing"; then exit 1; fi
test "$(cat "$probe/existing")" = caller-owned
printf 'unsupported shape' > "$fixture/assets/refused.exe"
if bash "$root/tools/build-contentpack.sh" --experimental "$fixture" "$probe/failed"; then exit 1; fi
test ! -e "$probe/failed"
printf 'altered pack' >> "$probe/one/content.pck"
if "$probe/contentpack" -experimental -operation verify -output "$probe/one"; then
 echo 'altered pack receipt verified' >&2; exit 1
fi
echo 'TEST PASS — native cumulative build, deterministic bytes, protected shell, receipt and no-mount ablation'
