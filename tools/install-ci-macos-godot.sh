#!/usr/bin/env bash
# Shared macOS source-evidence setup; never install an unverified engine.
set -euo pipefail
curl -fsSL -o godot.zip "https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION:?}-stable/Godot_v${GODOT_VERSION}-stable_macos.universal.zip"
echo "${GODOT_MACOS_SHA512:?}  godot.zip" | shasum -a 512 -c -
unzip -q godot.zip
printf '#!/bin/sh\nexec "%s/Godot.app/Contents/MacOS/Godot" "$@"\n' "${PWD}" | sudo tee /usr/local/bin/godot >/dev/null
sudo chmod +x /usr/local/bin/godot
