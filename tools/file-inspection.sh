#!/usr/bin/env bash
# Source-only lexical inspection: preserve caller diagnostics and read policy.
inspect_regular_file() {
 local path="$1" part="$1"
 if [ ! -f "$path" ]; then
  printf 'missing\n'
  return
 fi
 while :; do
  if [ -L "$part" ]; then
   printf 'symlink\n'
   return
  fi
  [ "$part" != "${part%/*}" ] || break
  part="${part%/*}"
 done
 printf 'ok\n'
}
