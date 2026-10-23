#!/usr/bin/env bash
# Exercise real archive-byte guards; command doubles never install host packages.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="$root/tools/install-ci-lavapipe.sh"
[[ -f $installer ]] || {
  echo 'FAIL: verified Mesa installer is missing' >&2
  exit 1
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
printf 'good archive' >"$work/good"
printf 'evil archive' >"$work/bad"
digest=$(sha256sum "$work/good")
digest=${digest%% *}
bytes=$(wc -c <"$work/good" | tr -d ' ')
cat >"$work/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
[[ $1 == apt-get ]] || exit 90
exec "$@"
SUDO
cat >"$work/bin/apt-get" <<'APT'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
'update --error-on=any') echo update >>"$TRACE"; exit "${UPDATE_EXIT:-0}" ;;
'-o Acquire::ForceHash=SHA256 --print-uris download mesa-vulkan-drivers')
  echo plan >>"$TRACE"
  name=mesa-vulkan-drivers_25.2.8-0ubuntu0.24.04.4_amd64.deb
  uri="mirror+file:/etc/apt/apt-mirrors.txt/pool/main/m/mesa/$name"
  size=$ARCHIVE_BYTES
  hash="SHA256:$ARCHIVE_DIGEST"
  case ${PLAN_KIND:-valid} in
    wrong-size) size=$((size+1)) ;;
    wrong-package) name=unrelated_1_amd64.deb ;;
    wrong-arch) name=mesa-vulkan-drivers_1_arm64.deb ;;
    unknown-origin) uri="https://untrusted.invalid/pool/main/m/mesa/$name" ;;
    unsafe-path) name=../outside.deb ;;
    encoded-path) name=mesa-vulkan-drivers_..%2fescape_amd64.deb; uri="mirror+file:/etc/apt/apt-mirrors.txt/pool/main/m/mesa/$name" ;;
    weak-hash) hash=MD5Sum:00000000000000000000000000000000 ;;
    malformed-hash) hash=SHA256:unknown ;;
    missing-hash) hash= ;;
    invalid-size) size=unknown ;;
    huge-size) size=999999999 ;;
    empty) exit 0 ;;
  esac
  printf "'%s' %s %s %s\n" "$uri" "$name" "$size" "$hash"
  [[ ${PLAN_KIND:-valid} != multiple ]] || printf "'%s' %s %s %s\n" "$uri" "$name" "$size" "$hash"
  exit "${PLAN_EXIT:-0}"
  ;;
*)
  [[ $# == 7 && $1 == install && $2 == --yes && $3 == --no-install-recommends &&
    $4 == "$RUNNER_TEMP"/*/mesa.deb && $5 == vulkan-tools && $6 == xauth && $7 == xvfb ]] || exit 91
  echo install >>"$TRACE"
  cmp "$ARCHIVE_GOOD" "$4"
  ;;
esac
APT
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
echo download >>"$TRACE"
output= url=
while [[ $# != 0 ]]; do
  case $1 in
    --fail|--show-error|--silent|--location|--retry-all-errors) shift ;;
    --retry) [[ $2 == 3 ]]; shift 2 ;;
    --retry-delay) [[ $2 == 1 ]]; shift 2 ;;
    --connect-timeout) [[ $2 == 10 ]]; shift 2 ;;
    --max-time) [[ $2 == 60 ]]; shift 2 ;;
    --max-filesize) [[ $2 =~ ^[1-9][0-9]*$ ]]; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --) [[ $# == 2 ]]; url=$2; shift 2 ;;
    *) exit 92 ;;
  esac
done
[[ $url == https://archive.ubuntu.com/ubuntu/pool/main/m/mesa/mesa-vulkan-drivers_25.2.8-0ubuntu0.24.04.4_amd64.deb &&
  $output == "$RUNNER_TEMP"/*/mesa.deb ]] || exit 93
if [[ ${CORRUPT_ARCHIVE:-false} == true ]]; then cp "$ARCHIVE_BAD" "$output"; else cp "$ARCHIVE_GOOD" "$output"; fi
exit "${DOWNLOAD_EXIT:-0}"
CURL
chmod +x "$work/bin/sudo" "$work/bin/apt-get" "$work/bin/curl"
case_number=0
run() {
  case_number=$((case_number + 1))
  dir="$work/case-$case_number"
  mkdir "$dir"
  env PATH="$work/bin:$PATH" TRACE="$dir/trace" RUNNER_TEMP="$dir" \
    ARCHIVE_GOOD="$work/good" ARCHIVE_BAD="$work/bad" ARCHIVE_BYTES="$bytes" ARCHIVE_DIGEST="$digest" \
    "$@" bash "$installer" >"$dir/output" 2>&1
}
run
[[ $(paste -sd, "$dir/trace") == update,plan,download,install ]] || {
  echo 'FAIL: valid authenticated bytes were not installed' >&2
  exit 1
}
for refused in UPDATE_EXIT=17 PLAN_EXIT=17 DOWNLOAD_EXIT=17 CORRUPT_ARCHIVE=true \
  PLAN_KIND=wrong-size PLAN_KIND=wrong-package PLAN_KIND=wrong-arch PLAN_KIND=unknown-origin \
  PLAN_KIND=unsafe-path PLAN_KIND=encoded-path PLAN_KIND=weak-hash PLAN_KIND=malformed-hash PLAN_KIND=missing-hash PLAN_KIND=invalid-size \
  PLAN_KIND=huge-size PLAN_KIND=empty PLAN_KIND=multiple; do
  if run "$refused"; then
    echo "FAIL: accepted $refused" >&2
    exit 1
  fi
  if grep -Fxq install "$dir/trace"; then
    echo "FAIL: $refused reached package execution" >&2
    exit 1
  fi
  case $refused in
  PLAN_KIND=wrong-size | DOWNLOAD_EXIT=17 | CORRUPT_ARCHIVE=true) ;;
  *) if grep -Fxq download "$dir/trace"; then
    echo "FAIL: $refused reached download" >&2
    exit 1
  fi ;;
  esac
done
echo 'PASS: Mesa installation requires complete authenticated planning and exact real archive bytes'
