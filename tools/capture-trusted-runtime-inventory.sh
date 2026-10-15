#!/usr/bin/env bash
# Build-time observation, while APT's verified indexes still exist.
set -euo pipefail
export LC_ALL=C
out=/usr/share/war-trusted-runtime/inventory.tsv
mkdir -p "$(dirname "$out")"
printf 'WAR_RUNTIME_INVENTORY\t1\n' > "$out"
dpkg --print-architecture >> "$out"
dpkg-query -W -f='package\t${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n' | sort >> "$out"
inputs="$(mktemp)"
for directory in /var/lib/apt/lists /etc/apt/apt.conf.d /etc/apt/sources.list.d; do
  links="$(find "$directory" -maxdepth 1 -type l -print)"
  if [ -n "$links" ]; then
    echo 'runtime inventory refuses linked APT inputs' >&2; exit 1
  fi
  find "$directory" -maxdepth 1 -type f ! -name lock -print >> "$inputs"
done
if [ -e /etc/apt/sources.list ] || [ -L /etc/apt/sources.list ]; then printf '%s\n' /etc/apt/sources.list >> "$inputs"; fi
printf '%s\n' /usr/share/keyrings/ubuntu-archive-keyring.gpg /etc/ssl/certs/ca-certificates.crt >> "$inputs"
sort -u "$inputs" -o "$inputs"
while IFS= read -r file; do
  [ -f "$file" ] && [ ! -L "$file" ]
  digest="$(sha256sum "$file")"
  size="$(wc -c < "$file")"
  printf 'file\t%s\t%s\t%s\n' "${digest%% *}" "$size" "$file" >> "$out"
done < "$inputs"
rm "$inputs"
