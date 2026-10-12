#!/usr/bin/env bash
# Every Linux client proof uses this checksum-verified engine installation.
set -euo pipefail
curl -fsSL -o godot.zip "https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION:?}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
echo "${GODOT_SHA512:?}  godot.zip" | sha512sum -c -
unzip -q godot.zip
sudo mv "Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot
