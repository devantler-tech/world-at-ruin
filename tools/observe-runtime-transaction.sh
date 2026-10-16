#!/usr/bin/env bash
# Selected cold-build observation; an acquisition plan is not independent archive authority.
set -euo pipefail
export LC_ALL=C
mode="${1:?inventory selection required}"
shift
case "$mode" in 0) exec "$@";; 1) ;; *) exit 2;; esac
if [ "$#" -lt 5 ] || [ "$1 $2 $3 $4" != 'apt-get install -y --no-install-recommends' ]; then exit 2; fi
expected=/tmp/expected-packages.tsv
out=/usr/share/war-trusted-runtime/transaction.tsv
origin_helper=/tmp/trusted-runtime-origin
if [ ! -f "$expected" ] || [ -L "$expected" ]; then exit 1; fi
if [ ! -x "$origin_helper" ] || [ -L "$origin_helper" ]; then exit 1; fi
if [ -e "$out" ] || [ -L "$out" ]; then exit 1; fi
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
  if ! "$@" | head -c 1048577 > "$destination"; then return 1; fi
  if [ "$(wc -c < "$destination")" -gt 1048576 ]; then return 1; fi
}
installed() {
  # shellcheck disable=SC2016 # dpkg expands its own field template.
  if ! bounded_capture "$1" dpkg-query -W -f='package\t${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n'; then return 1; fi
  sort "$1" -o "$1"
  [ -s "$1" ] || return 1
}
if ! installed "$state/before"; then exit 1; fi
if ! version="$(dpkg-query -W -f='${Version}\n' apt)"; then exit 1; fi
if ! [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9+.:~_-]*$ ]]; then exit 1; fi
printf 'apt-version\t%s\n' "$version" > "$state/result"
sed 's/^package/base-package/' "$state/before" >> "$state/result"
for pin in "${@:5}"; do
  if ! [[ "$pin" =~ ^[a-z0-9][a-z0-9+.-]*=[A-Za-z0-9][A-Za-z0-9+.:~_-]*$ ]]; then exit 1; fi
  printf 'argument\t%s\n' "$pin" >> "$state/result"
done
# Very quiet print-URIs has no progress preamble. Every line must be accounted for.
if ! bounded_capture "$state/plan" "$@" -qq --print-uris -o Acquire::ForceHash=sha256 -o "$cache_option"; then exit 1; fi
if [ ! -s "$state/plan" ]; then exit 1; fi
terminal="$(tail -c 1 "$state/plan")"
if [ -n "$terminal" ]; then exit 1; fi
: > "$state/names"
: > "$state/requests"
: > "$state/acquired"
: > "$state/archive-identities"
: > "$state/package-names"
plan_pattern="^'([^'[:space:]]+)' ([A-Za-z0-9][A-Za-z0-9+.:~%_-]*[.]deb) ([1-9][0-9]*) SHA256:([0-9a-f]{64})$"
uri_pattern='^https?://[^/@?#[:space:]]+(/[^?#[:space:]]*)?$'
count=0
total=0
while IFS= read -r row; do
  if ! [[ "$row" =~ $plan_pattern ]]; then exit 1; fi
  uri=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]} bytes=${BASH_REMATCH[3]} hash=${BASH_REMATCH[4]}
  if ! [[ "$uri" =~ $uri_pattern ]]; then exit 1; fi
  if [ "$bytes" -gt 67108864 ]; then exit 1; fi
  if grep -Fxq "$name" "$state/names"; then echo 'duplicate archive destination refused' >&2; exit 1; fi
  printf '%s\n' "$name" >> "$state/names"
  printf '%s\t%s\t%s\t%s\n' "$uri" "$name" "$bytes" "$hash" >> "$state/requests"
  printf 'plan\t%s\t%s\t%s\t%s\n' "$uri" "$name" "$bytes" "$hash" >> "$state/result"
  count=$((count+1))
  total=$((total+bytes))
  if [ "$count" -gt 1024 ] || [ "$total" -gt 268435456 ]; then exit 1; fi
done < "$state/plan"
if [ "$count" -eq 0 ]; then exit 1; fi
if ! "$@" --download-only -o "$cache_option"; then exit 1; fi
while IFS=$'\t' read -r uri name bytes hash; do
  archive="$cache/$name"
  if [ ! -f "$archive" ] || [ -L "$archive" ]; then exit 1; fi
  if [ "$(stat -c %h "$archive")" != 1 ] || [ "$(wc -c < "$archive")" -ne "$bytes" ]; then exit 1; fi
  if ! observed="$(sha256sum "$archive")"; then exit 1; fi
  if [ "${observed%% *}" != "$hash" ]; then exit 1; fi
  # shellcheck disable=SC2016 # dpkg-deb expands its own field template.
  if ! identity="$(dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}\n' "$archive")"; then exit 1; fi
  IFS=$'\t' read -r package version architecture extra <<< "$identity"
  if ! [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || ! [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9+.:~_-]*$ ]]; then exit 1; fi
  if [ -n "${extra:-}" ] || { [ "$architecture" != amd64 ] && [ "$architecture" != all ]; }; then exit 1; fi
  # Require the complete metadata record, including the original delimiter count.
  if [ "$identity" != "$(printf '%s\t%s\t%s' "$package" "$version" "$architecture")" ]; then exit 1; fi
  record="$(printf 'package\t%s\t%s\t%s\tinstalled' "$package" "$version" "$architecture")"
  if ! grep -Fxq "$record" "$expected"; then exit 1; fi
  if grep -Fxq "$package" "$state/package-names"; then exit 1; fi
  printf '%s\n' "$package" >> "$state/package-names"
  if grep -Fxq "$record" "$state/before"; then echo 'redundant inherited archive refused' >&2; exit 1; fi
  printf '%s\n' "$record" >> "$state/acquired"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$uri" "$name" "$package" "$version" "$architecture" "$bytes" "$hash" >> "$state/archive-identities"
  printf 'archive\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$package" "$version" "$architecture" "$bytes" "$hash" >> "$state/result"
done < "$state/requests"
# Reject all unaccounted cache entries; APT owns only its regular lock and partial directory.
find "$cache" -mindepth 1 -maxdepth 1 ! -name lock ! -name partial -exec basename {} \; | sort > "$state/actual-names"
sort "$state/names" -o "$state/names"
if ! cmp "$state/names" "$state/actual-names"; then exit 1; fi
if [ ! -f "$cache/lock" ] || [ -L "$cache/lock" ] || [ "$(stat -c %h "$cache/lock")" != 1 ]; then exit 1; fi
if [ -L "$cache/partial" ] || [ ! -d "$cache/partial" ]; then exit 1; fi
find "$cache/partial" -mindepth 1 -print > "$state/partial"
if [ -s "$state/partial" ]; then exit 1; fi
# Keep the exact APT 2.8 target interface as evidence. The helper reads every
# authenticated Packages target and refuses a missing, conflicting, invalid or repeated
# join before the offline installation can execute package scripts.
# shellcheck disable=SC2016 # APT expands its own target placeholders.
target_format='$(FILENAME)'$'\t''$(URI)'$'\t''$(REPO_URI)'$'\t''$(BASE_URI)'$'\t''$(RELEASE)'$'\t''$(COMPONENT)'$'\t''$(ARCHITECTURE)'$'\t''$(TRUSTED)'$'\t''$(CODENAME)'$'\t''$(SUITE)'$'\t''$(ORIGIN)'$'\t''$(LABEL)'
if ! bounded_capture "$state/targets" apt-get indextargets 'Identifier: Packages' --format "$target_format"; then exit 1; fi
if [ ! -s "$state/targets" ]; then exit 1; fi
if ! "$origin_helper" "$state/archive-identities" "$state/targets" >> "$state/result"; then exit 1; fi
# Upgrades replace the old tuple; every inherited/new tuple must explain the reviewed final set.
awk -F '\t' 'NR==FNR {replacement[$2]=$0; next} !($2 in replacement) {print} END {for (name in replacement) print replacement[name]}' "$state/acquired" "$state/before" | sort > "$state/expected-final"
if ! cmp "$expected" "$state/expected-final"; then exit 1; fi
if ! installed "$state/unchanged"; then exit 1; fi
if ! cmp "$state/before" "$state/unchanged"; then exit 1; fi
if [ "$(wc -c < "$state/result")" -gt 1048000 ]; then exit 1; fi
# No fallback or missing-package tolerance: the same cache/arguments must install offline.
if ! "$@" --no-download -o "$cache_option"; then exit 1; fi
printf 'transaction-complete\n' >> "$state/result"
out_parent="$(dirname "$out")"
if ! mkdir -p "$out_parent"; then exit 1; fi
if [ ! -d "$out_parent" ] || [ -L "$out_parent" ]; then exit 1; fi
# Package maintainer scripts ran as root; recheck their destination before publishing evidence.
if [ -e "$out" ] || [ -L "$out" ]; then exit 1; fi
if ! install -m 0644 "$state/result" "$out"; then exit 1; fi
if [ ! -f "$out" ] || [ -L "$out" ] || [ "$(stat -c %h "$out")" != 1 ]; then exit 1; fi
printf 'TRUSTED_RUNTIME_TRANSACTION archives=%s plan-matched-before-install=true\n' "$count"
