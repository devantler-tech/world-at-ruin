#!/usr/bin/env bash
# Preserve APT's exact Mesa choice, using its strong digest at Ubuntu's HTTPS origin.
set -euo pipefail
umask 077
export LC_ALL=C
fail() {
  echo "::error::lavapipe installation: $*" >&2
  exit 1
}
[[ $# == 0 && ${RUNNER_TEMP:-} == /* && -d $RUNNER_TEMP && ! -L $RUNNER_TEMP ]] || fail 'expected a fresh native runner directory'
started=$SECONDS
sudo apt-get update --error-on=any
plan=$(apt-get -o Acquire::ForceHash=SHA256 --print-uris download mesa-vulkan-drivers) || fail 'APT archive planning failed'
[[ -n $plan && ${#plan} -le 2048 && $plan != *$'\n'* ]] || fail 'expected one complete archive plan'
read -r uri filename bytes hash extra <<<"$plan"
[[ -z $extra && $uri == \'*\' &&
  $filename =~ ^mesa-vulkan-drivers_[0-9A-Za-z.+~:-]+_amd64\.deb$ &&
  $bytes =~ ^[1-9][0-9]{0,8}$ && $hash =~ ^SHA256:[0-9a-f]{64}$ ]] || fail 'invalid package identity, size or strong digest'
[[ $bytes -le 134217728 ]] || fail 'archive exceeds the bounded package size'
uri=${uri#\'}
uri=${uri%\'}
case $uri in
http://azure.archive.ubuntu.com/ubuntu/pool/main/m/mesa/"$filename" | \
  https://azure.archive.ubuntu.com/ubuntu/pool/main/m/mesa/"$filename" | \
  http://archive.ubuntu.com/ubuntu/pool/main/m/mesa/"$filename" | \
  https://archive.ubuntu.com/ubuntu/pool/main/m/mesa/"$filename" | \
  http://security.ubuntu.com/ubuntu/pool/main/m/mesa/"$filename" | \
  https://security.ubuntu.com/ubuntu/pool/main/m/mesa/"$filename" | \
  mirror+file:/etc/apt/apt-mirrors.txt/pool/main/m/mesa/"$filename" | \
  mirror+file:/etc/apt/apt-mirrors-security.txt/pool/main/m/mesa/"$filename") ;;
*) fail 'unrecognized Ubuntu archive origin' ;;
esac
scratch=$(mktemp -d "$RUNNER_TEMP/lavapipe-package.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
archive="$scratch/mesa.deb"
download_started=$SECONDS
curl --fail --show-error --silent --location --retry 3 --retry-delay 1 --retry-all-errors \
  --connect-timeout 10 --max-time 60 --max-filesize "$bytes" --output "$archive" \
  -- "https://archive.ubuntu.com/ubuntu/pool/main/m/mesa/$filename" || fail 'archive download failed'
[[ -f $archive && ! -L $archive ]] || fail 'download is not a regular archive'
[[ $(wc -c <"$archive") -eq $bytes ]] || fail 'archive size differs from authenticated metadata'
actual=$(sha256sum "$archive") || fail 'archive digest could not be read'
[[ ${actual%% *} == "${hash#SHA256:}" ]] || fail 'archive digest differs from authenticated metadata'
printf 'MESA_ARCHIVE filename=%s bytes=%s sha256=%s download_seconds=%s\n' \
  "$filename" "$bytes" "${hash#SHA256:}" "$((SECONDS - download_started))"
# Only this public, verified archive becomes readable by APT's sandbox account.
chmod 755 "$scratch"
chmod 644 "$archive"
sudo apt-get install --yes --no-install-recommends "$archive" vulkan-tools xauth xvfb
printf 'LAVAPIPE_SETUP seconds=%s\n' "$((SECONDS - started))"
