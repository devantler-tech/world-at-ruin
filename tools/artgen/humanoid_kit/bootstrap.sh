#!/usr/bin/env bash
# Installs the pinned MPFB extension into the local Blender — the one-time
# setup for the humanoid-kit bake (see README.md). Blender itself must already
# be installed (CI downloads its own pinned copy; see artgen.yaml).
set -euo pipefail

MPFB_VERSION="2.0.16"
MPFB_SHA256="b5cdc8b08147e0c6463e4faa01147491b13a0b062f73415363f029debd11c934"
MPFB_URL="https://extensions.blender.org/download/sha256:${MPFB_SHA256}/add-on-mpfb-v${MPFB_VERSION}.zip"
BLENDER="${BLENDER:-blender}"

echo "Blender: $("${BLENDER}" --version | head -1)"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL "${MPFB_URL}" -o "${tmp}/mpfb.zip"
if command -v sha256sum > /dev/null; then
  echo "${MPFB_SHA256}  ${tmp}/mpfb.zip" | sha256sum -c -
else
  echo "${MPFB_SHA256}  ${tmp}/mpfb.zip" | shasum -a 256 -c -
fi

"${BLENDER}" --background --command extension install-file -r user_default "${tmp}/mpfb.zip"
echo "MPFB ${MPFB_VERSION} installed."
