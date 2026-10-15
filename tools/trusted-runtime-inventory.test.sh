#!/usr/bin/env bash
# Run the actual cold builder with bounded command observations.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
mkdir -p "$state/bin"
cat > "$state/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TRACE"
case "$1 $2" in
 'build --pull') exit 0;;
 'image inspect')
   if [[ "$*" = *'.Os'* ]]; then
     cat "$IMAGE_JSON"
     [ "${OBSERVATION:-}" != inspect-failed ]
   else printf 'sha256:%064d\n' 1; fi;;
 'run --rm')
   if [ "${OBSERVATION:-}" = timeout ]; then sleep 30; fi
   cat "$INVENTORY_FIXTURE"
   [ "${OBSERVATION:-}" != extract-failed ];;
 'rm --force') exit 0;;
 'ps --all') if [ "${OBSERVATION:-}" = cleanup-failed ]; then echo retained-container; fi;;
 *) exit 91;;
esac
DOCKER
printf '#!/bin/sh\nprintf fake-engine\\n\n' > "$state/bin/godot"
chmod +x "$state/bin/docker" "$state/bin/godot"
export TRACE="$state/trace"
PATH="$state/bin:$PATH" WAR_TRUSTED_RUNTIME_INVENTORY=0 bash "$root/tools/build-trusted-regression-runtime.sh" > "$state/out"
grep -qx 'sha256:0000000000000000000000000000000000000000000000000000000000000001' "$state/out"
if PATH="$state/bin:$PATH" WAR_TRUSTED_RUNTIME_INVENTORY=bogus bash "$root/tools/build-trusted-regression-runtime.sh" > "$state/bad" 2>/dev/null; then
 echo 'unknown inventory mode accepted' >&2; exit 1
fi
[ ! -s "$state/bad" ]
export IMAGE_JSON="$state/image.json" INVENTORY_FIXTURE="$state/inventory.tsv"
export GODOT_VERSION=4.7.1 GODOT_SHA512
GODOT_SHA512="$(printf '%0128d' 1)"
printf '[{"Id":"sha256:%064d","Os":"linux","Architecture":"amd64","Config":{"User":"1001:1001","WorkingDir":"/project","Entrypoint":["/usr/local/bin/godot"]}}]\n' 1 > "$IMAGE_JSON"
{
  printf 'WAR_RUNTIME_INVENTORY\t1\namd64\n'
  for pin in libfontconfig1=2.15.0-1.1ubuntu2 libx11-6=2:1.8.7-1build1 libxcursor1=1:1.2.1-1build1 libxinerama1=2:1.1.4-3build1 libgl1=1.7.0-1build1 libxi6=2:1.8.1-1build1 libxrandr2=2:1.5.2-2build1 libwayland-client0=1.22.0-2.1build1 libxkbcommon0=1.6.0-1build1 libdbus-1-3=1.14.10-4ubuntu4.1 base-files=13ubuntu10.3; do
    printf 'package\t%s\t%s\tamd64\tinstalled\n' "${pin%%=*}" "${pin#*=}"
  done
  for file in /var/lib/apt/lists/snapshot_InRelease /var/lib/apt/lists/snapshot_main_binary-amd64_Packages.lz4 /etc/apt/sources.list.d/ubuntu.sources /etc/apt/apt.conf.d/50snapshot /usr/share/keyrings/ubuntu-archive-keyring.gpg /etc/ssl/certs/ca-certificates.crt; do
    printf 'file\t%064d\t123\t%s\n' 1 "$file"
  done
  engine="$(shasum -a 256 "$state/bin/godot")"
  printf 'engine\t%s\nEND\n' "${engine%% *}"
} > "$INVENTORY_FIXTURE"
mkdir "$state/tmp"
PATH="$state/bin:$PATH" TMPDIR="$state/tmp" WAR_TRUSTED_RUNTIME_INVENTORY=1 bash "$root/tools/build-trusted-regression-runtime.sh" > "$state/out" 2> "$state/report"
grep -q '^TRUSTED_RUNTIME_INVENTORY {"schema":1,' "$state/report"
grep '^TRUSTED_RUNTIME_INVENTORY ' "$state/report" | sed 's/^TRUSTED_RUNTIME_INVENTORY //' | jq -e '.evidence=="observed-cold-build-inventory-only" and (.inventory.installed_packages|length)==11 and (.recipe_files|length)==10' >/dev/null
for observation in inspect-failed extract-failed cleanup-failed timeout; do
  if PATH="$state/bin:$PATH" TMPDIR="$state/tmp" OBSERVATION="$observation" WAR_TRUSTED_INSPECT_SECONDS=2 WAR_TRUSTED_RUNTIME_INVENTORY=1 bash "$root/tools/build-trusted-regression-runtime.sh" > "$state/out" 2> "$state/report"; then
    echo "accepted failed $observation observation" >&2; exit 1
  fi
  [ ! -s "$state/out" ]
  if grep -q '^TRUSTED_RUNTIME_INVENTORY ' "$state/report"; then echo 'published incomplete inventory' >&2; exit 1; fi
done
echo 'trusted runtime inventory selection, complete-read, timeout and cleanup controls passed'
