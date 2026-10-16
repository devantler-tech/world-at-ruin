#!/usr/bin/env bash
# Selected cold-build observation; an acquisition plan is not independent archive authority.
set -euo pipefail
export LC_ALL=C
mode="${1:?inventory selection required}"
shift
case "$mode" in 0) exec "$@";; 1) ;; *) exit 2;; esac
[ "$#" -ge 5 ] && [ "$1 $2 $3 $4" = 'apt-get install -y --no-install-recommends' ]
expected=/tmp/expected-packages.tsv
out=/usr/share/war-trusted-runtime/transaction.tsv
[ -f "$expected" ] && [ ! -L "$expected" ]
[ ! -e "$out" ] && [ ! -L "$out" ]
state="$(mktemp -d)"
cleanup() {
  local status=$?
  rm -rf "$state" || status=1
  exit "$status"
}
trap cleanup EXIT
# Permit APT's _apt downloader to traverse this disposable container-local directory.
chmod 0755 "$state"
cache="$state/archives"
mkdir -m 0755 "$cache"
cache_option="Dir::Cache::archives=$cache"
bounded_capture() {
  local destination=$1
  shift
  "$@" | head -c 1048577 > "$destination"
  [ "$(wc -c < "$destination")" -le 1048576 ]
}
installed() {
  # shellcheck disable=SC2016 # dpkg expands its own field template.
  bounded_capture "$1" dpkg-query -W -f='package\t${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n'
  sort "$1" -o "$1"
  [ -s "$1" ]
}
installed "$state/before"
version="$(dpkg-query -W -f='${Version}\n' apt)"
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9+.:~_-]*$ ]]
printf 'apt-version\t%s\n' "$version" > "$state/result"
sed 's/^package/base-package/' "$state/before" >> "$state/result"
for pin in "${@:5}"; do
  [[ "$pin" =~ ^[a-z0-9][a-z0-9+.-]*=[A-Za-z0-9][A-Za-z0-9+.:~_-]*$ ]]
  printf 'argument\t%s\n' "$pin" >> "$state/result"
done
# Very quiet print-URIs has no progress preamble. Every line must be accounted for.
bounded_capture "$state/plan" "$@" -qq --print-uris -o Acquire::ForceHash=sha256 -o "$cache_option"
[ -s "$state/plan" ]
terminal="$(tail -c 1 "$state/plan")"
[ -z "$terminal" ]
: > "$state/names"
: > "$state/requests"
: > "$state/acquired"
: > "$state/package-names"
plan_pattern="^'([^'[:space:]]+)' ([A-Za-z0-9][A-Za-z0-9+.:~%_-]*[.]deb) ([1-9][0-9]*) SHA256:([0-9a-f]{64})$"
count=0
total=0
while IFS= read -r row; do
  [[ "$row" =~ $plan_pattern ]]
  uri=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]} bytes=${BASH_REMATCH[3]} hash=${BASH_REMATCH[4]}
  [[ "$uri" =~ ^https?://[^[:space:]]+$ ]]
  [ "$bytes" -le 67108864 ]
  if grep -Fxq "$name" "$state/names"; then echo 'duplicate archive destination refused' >&2; exit 1; fi
  printf '%s\n' "$name" >> "$state/names"
  printf '%s\t%s\t%s\t%s\n' "$uri" "$name" "$bytes" "$hash" >> "$state/requests"
  printf 'plan\t%s\t%s\t%s\t%s\n' "$uri" "$name" "$bytes" "$hash" >> "$state/result"
  count=$((count+1))
  total=$((total+bytes))
  [ "$count" -le 1024 ] && [ "$total" -le 268435456 ]
done < "$state/plan"
[ "$count" -gt 0 ]
"$@" --download-only -o "$cache_option"
while IFS=$'\t' read -r uri name bytes hash; do
  archive="$cache/$name"
  [ -f "$archive" ] && [ ! -L "$archive" ]
  [ "$(stat -c %h "$archive")" = 1 ]
  [ "$(wc -c < "$archive")" -eq "$bytes" ]
  observed="$(sha256sum "$archive")"
  [ "${observed%% *}" = "$hash" ]
  # shellcheck disable=SC2016 # dpkg-deb expands its own field template.
  identity="$(dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}\n' "$archive")"
  IFS=$'\t' read -r package version architecture extra <<< "$identity"
  [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] && [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9+.:~_-]*$ ]]
  [ -z "${extra:-}" ] && { [ "$architecture" = amd64 ] || [ "$architecture" = all ]; }
  # Require the complete metadata record, including the original delimiter count.
  [ "$identity" = "$(printf '%s\t%s\t%s' "$package" "$version" "$architecture")" ]
  record="$(printf 'package\t%s\t%s\t%s\tinstalled' "$package" "$version" "$architecture")"
  grep -Fxq "$record" "$expected"
  if grep -Fxq "$package" "$state/package-names"; then exit 1; fi
  printf '%s\n' "$package" >> "$state/package-names"
  if grep -Fxq "$record" "$state/before"; then echo 'redundant inherited archive refused' >&2; exit 1; fi
  printf '%s\n' "$record" >> "$state/acquired"
  printf 'archive\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$package" "$version" "$architecture" "$bytes" "$hash" >> "$state/result"
done < "$state/requests"
# Reject all unaccounted cache entries; APT owns only its regular lock and partial directory.
find "$cache" -mindepth 1 -maxdepth 1 ! -name lock ! -name partial -exec basename {} \; | sort > "$state/actual-names"
sort "$state/names" -o "$state/names"
cmp "$state/names" "$state/actual-names"
[ -f "$cache/lock" ] && [ ! -L "$cache/lock" ] && [ "$(stat -c %h "$cache/lock")" = 1 ]
[ ! -L "$cache/partial" ] && [ -d "$cache/partial" ]
find "$cache/partial" -mindepth 1 -print > "$state/partial"
[ ! -s "$state/partial" ]
# Upgrades replace the old tuple; every inherited/new tuple must explain the reviewed final set.
awk -F '\t' 'NR==FNR {replacement[$2]=$0; next} !($2 in replacement) {print} END {for (name in replacement) print replacement[name]}' "$state/acquired" "$state/before" | sort > "$state/expected-final"
cmp "$expected" "$state/expected-final"
installed "$state/unchanged"
cmp "$state/before" "$state/unchanged"
[ "$(wc -c < "$state/result")" -le 1048000 ]
# No fallback or missing-package tolerance: the same cache/arguments must install offline.
"$@" --no-download -o "$cache_option"
printf 'transaction-complete\n' >> "$state/result"
mkdir -p "$(dirname "$out")"
cp "$state/result" "$out"
printf 'TRUSTED_RUNTIME_TRANSACTION archives=%s plan-matched-before-install=true\n' "$count"
