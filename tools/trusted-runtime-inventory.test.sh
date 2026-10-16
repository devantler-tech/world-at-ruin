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
  for pin in libfontconfig1=2.15.0-1.1ubuntu2 libx11-6=2:1.8.7-1build1 libxcursor1=1:1.2.1-1build1 libxinerama1=2:1.1.4-3build1 libgl1=1.7.0-1build1 libxi6=2:1.8.1-1build1 libxrandr2=2:1.5.2-2build1 libwayland-client0=1.22.0-2.1build1 libxkbcommon0=1.6.0-1build1 libdbus-1-3=1.14.10-4ubuntu4.1 base-files=13ubuntu10.3 apt=2.8.3; do
    printf 'package\t%s\t%s\tamd64\tinstalled\n' "${pin%%=*}" "${pin#*=}"
  done
  printf 'apt-version\t2.8.3\nbase-package\tbase-files\t13ubuntu10.3\tamd64\tinstalled\nbase-package\tapt\t2.8.3\tamd64\tinstalled\n'
  printf 'target\thttps://snapshot.ubuntu.com/dists/noble/main/binary-amd64/Packages\t/var/lib/apt/lists/snapshot_main_binary-amd64_Packages\t456\t%064d\thttps://snapshot.ubuntu.com/\thttps://snapshot.ubuntu.com/dists/noble/\tnoble\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble\tnoble\t/var/lib/apt/lists/snapshot_InRelease\t789\t%064d\n' 3 4
  for pin in libfontconfig1=2.15.0-1.1ubuntu2 libx11-6=2:1.8.7-1build1 libxcursor1=1:1.2.1-1build1 libxinerama1=2:1.1.4-3build1 libgl1=1.7.0-1build1 libxi6=2:1.8.1-1build1 libxrandr2=2:1.5.2-2build1 libwayland-client0=1.22.0-2.1build1 libxkbcommon0=1.6.0-1build1 libdbus-1-3=1.14.10-4ubuntu4.1; do
    name=${pin%%=*}
    printf 'argument\t%s\nplan\thttps://snapshot.ubuntu.com/test/%s.deb\t%s.deb\t123\t%064d\narchive\t%s.deb\t%s\t%s\tamd64\t123\t%064d\n' "$pin" "$name" "$name" 1 "$name" "$name" "${pin#*=}" 1
    printf 'origin\t%s.deb\t%s\t%s\tamd64\ttest/%s.deb\thttps://snapshot.ubuntu.com/\thttps://snapshot.ubuntu.com/dists/noble/\tnoble\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble\tnoble\thttps://snapshot.ubuntu.com/dists/noble/main/binary-amd64/Packages\t/var/lib/apt/lists/snapshot_main_binary-amd64_Packages\t456\t%064d\t/var/lib/apt/lists/snapshot_InRelease\t789\t%064d\n' "$name" "$name" "${pin#*=}" "$name" 3 4
  done
  printf 'transaction-complete\n'
  for file in /var/lib/apt/lists/snapshot_InRelease /var/lib/apt/lists/snapshot_main_binary-amd64_Packages /etc/apt/sources.list.d/ubuntu.sources /etc/apt/apt.conf.d/50snapshot /usr/share/keyrings/ubuntu-archive-keyring.gpg /etc/ssl/certs/ca-certificates.crt; do
    digest=1 size=123
    case "$file" in *_InRelease) digest=4 size=789;; *_Packages) digest=3 size=456;; esac
    printf 'file\t%064d\t%s\t%s\n' "$digest" "$size" "$file"
  done
  engine="$(shasum -a 256 "$state/bin/godot")"
  printf 'engine\t%s\nEND\n' "${engine%% *}"
} > "$INVENTORY_FIXTURE"
mkdir "$state/tmp"
PATH="$state/bin:$PATH" TMPDIR="$state/tmp" WAR_TRUSTED_RUNTIME_INVENTORY=1 bash "$root/tools/build-trusted-regression-runtime.sh" > "$state/out" 2> "$state/report"
grep -q '^TRUSTED_RUNTIME_INVENTORY {"schema":1,' "$state/report"
grep '^TRUSTED_RUNTIME_INVENTORY ' "$state/report" | sed 's/^TRUSTED_RUNTIME_INVENTORY //' | jq -e '.evidence=="observed-cold-build-inventory-only" and (.inventory.installed_packages|length)==12 and (.recipe_files|length)==19 and (.inventory.transaction.apt_targets|length)==1 and (.inventory.transaction.downloaded_archives|length)==10 and (.inventory.transaction.downloaded_archives | all((.apt_origins|length)==1 and all(.apt_origins[]; .trusted == true)))' >/dev/null
for observation in inspect-failed extract-failed cleanup-failed timeout; do
  if PATH="$state/bin:$PATH" TMPDIR="$state/tmp" OBSERVATION="$observation" WAR_TRUSTED_INSPECT_SECONDS=2 WAR_TRUSTED_RUNTIME_INVENTORY=1 bash "$root/tools/build-trusted-regression-runtime.sh" > "$state/out" 2> "$state/report"; then
    echo "accepted failed $observation observation" >&2; exit 1
  fi
  [ ! -s "$state/out" ]
  if grep -q '^TRUSTED_RUNTIME_INVENTORY ' "$state/report"; then echo 'published incomplete inventory' >&2; exit 1; fi
done
echo 'trusted runtime inventory selection, complete-read, timeout and cleanup controls passed'
# Exercise failed empty link inspection through the actual capture command.
cat > "$state/bin/dpkg" <<'DPKG'
#!/bin/sh
printf 'amd64\n'
DPKG
cat > "$state/bin/dpkg-query" <<'QUERY'
#!/bin/sh
printf 'package\tbase-files\t1\tamd64\tinstalled\n'
QUERY
cat > "$state/bin/find" <<'FIND'
#!/bin/sh
case "$*" in *'-type l'*) exit 9;; esac
exit 0
FIND
chmod +x "$state/bin/dpkg" "$state/bin/dpkg-query" "$state/bin/find"
# Relocate only the fixed output for the macOS fixture; observation code is unchanged.
sed "s|out=/usr/share/war-trusted-runtime/inventory.tsv|out=$state/capture.tsv|" "$root/tools/capture-trusted-runtime-inventory.sh" > "$state/capture.sh"
capture_status=0
PATH="$state/bin:$PATH" bash "$state/capture.sh" >/dev/null 2>&1 || capture_status=$?
if [ "$capture_status" -ne 9 ]; then
  echo 'failed link inspection status was lost' >&2; exit 1
fi
