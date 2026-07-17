#!/usr/bin/env bash
# Installs the pinned MPFB extension into the local Blender AND downloads the
# pinned CC0 asset packs the equipment bake consumes — the one-time setup for
# the humanoid-kit bake (see README.md). Blender itself must already be
# installed (CI downloads its own pinned copy; see artgen.yaml). Packs land in
# ./packs/ (gitignored): GPL tools and source packs never enter the tree, only
# baked output does.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPFB_VERSION="2.0.16"
MPFB_SHA256="b5cdc8b08147e0c6463e4faa01147491b13a0b062f73415363f029debd11c934"
MPFB_URL="https://extensions.blender.org/download/sha256:${MPFB_SHA256}/add-on-mpfb-v${MPFB_VERSION}.zip"
BLENDER="${BLENDER:-blender}"

check_sha() { # <sha> <file>
  if command -v sha256sum > /dev/null; then
    echo "$1  $2" | sha256sum -c -
  else
    echo "$1  $2" | shasum -a 256 -c -
  fi
}

echo "Blender: $("${BLENDER}" --version | head -1)"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL "${MPFB_URL}" -o "${tmp}/mpfb.zip"
check_sha "${MPFB_SHA256}" "${tmp}/mpfb.zip"

"${BLENDER}" --background --command extension install-file -r user_default "${tmp}/mpfb.zip"
echo "MPFB ${MPFB_VERSION} installed."

# CC0 asset packs (equipment + skin sources), pinned by sha256 in
# manifest.json — the manifest stays the single source of truth for what the
# kit is made of.
jq -r '.asset_packs | to_entries[] | "\(.key) \(.value.sha256) \(.value.url) \(.value.mirror)"' \
    "${KIT_DIR}/manifest.json" | while read -r name sha url mirror; do
  dest="${KIT_DIR}/packs/${name}"
  marker="${dest}/.sha256"
  if [[ -f "${marker}" && "$(cat "${marker}")" == "${sha}" ]]; then
    echo "pack ${name}: cached."
    continue
  fi
  echo "pack ${name}: downloading..."
  zip="${tmp}/${name}.zip"
  curl -fsSL "${url}" -o "${zip}" || curl -fsSL "${mirror}" -o "${zip}"
  check_sha "${sha}" "${zip}"
  rm -rf "${dest}"
  mkdir -p "${dest}"
  unzip -q "${zip}" -d "${dest}"
  echo "${sha}" > "${marker}"
  echo "pack ${name}: installed."
done
echo "Asset packs ready."
