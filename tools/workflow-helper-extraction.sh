#!/usr/bin/env bash
# Extraction only. Callers source the bytes in their own original scope.
extract_marked_workflow_helpers() {
 local workflow="$1" output="$2" marker
 shift 2
 [ -r "$workflow" ] && [ "$#" -gt 0 ] || return 1
 : > "$output" || return 1
 for marker in "$@"; do
  case "$marker" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
  awk -v marker="$marker" '
   {
    trimmed = $0
    sub(/^[[:space:]]*/, "", trimmed)
    sub(/[[:space:]]*$/, "", trimmed)
    if (trimmed == "# BEGIN " marker) {
     if (opened || completed) { invalid = 1; exit 1 }
     opened = 1
    }
    if (opened) print
    if (trimmed == "# END " marker) {
     if (!opened) { invalid = 1; exit 1 }
     opened = 0
     completed = 1
    }
   }
   END { if (invalid || opened || !completed) exit 1 }
  ' "$workflow" >> "$output" || return 1
 done
 bash -n "$output"
}
