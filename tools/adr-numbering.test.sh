#!/usr/bin/env bash
# Keep new ADR numbers unique without breaking the two historical filename pairs.
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failures=0

# Refuse an observation whose completeness or regular-file boundary is unknown.
unknown() {
  printf 'ADR numbering: UNKNOWN — %s\n' "$1" >&2
  exit 2
}

# Validate one complete directory inventory; return 1 for collisions, 2 for UNKNOWN.
check_numbering() (
  directory="$1"
  [[ -d "$directory" && ! -L "$directory" ]] || unknown 'missing or linked directory'
  work="$(mktemp -d)" || unknown 'cannot prepare inventory'
  trap 'rm -rf "$work"' EXIT
  # Arguments retain filename boundaries, including newlines. A failed find,
  # validation batch or write refuses the entire inventory before classification.
  if ! find "$directory" -mindepth 1 -maxdepth 1 -name '*.md' -exec bash -c '
    for file do
      [[ -f "$file" && ! -L "$file" ]] || exit 2
      name="${file##*/}"
      [[ "$name" != README.md ]] || continue
      [[ "$name" =~ ^[0-9]{4}-[A-Za-z0-9][A-Za-z0-9._-]*\.md$ ]] || exit 2
      printf "%s\n" "$name" || exit 2
    done
  ' _ {} + > "$work/names"; then
    unknown 'incomplete or unsafe inventory'
  fi
  [[ -s "$work/names" ]] || unknown 'empty inventory'
  status=0
  awk '
    { number = substr($0, 1, 4); count[number]++; member[number SUBSEP $0] = 1 }
    END {
      for (number in count) {
        if (count[number] < 2) continue
        if (number == "0002" && count[number] == 2 &&
            member[number SUBSEP "0002-seal-zone-admission-secrets-before-readiness.md"] &&
            member[number SUBSEP "0002-use-ecdsa-p256-for-client-update-trust.md"]) continue
        if (number == "0013" && count[number] == 2 &&
            member[number SUBSEP "0013-publish-update-signatures-with-offline-opt-in-tooling.md"] &&
            member[number SUBSEP "0013-retain-inactive-authoritative-mastery-transactions.md"]) continue
        printf "ADR numbering: duplicate number %s\n", number
        failed = 1
      }
      if (failed) exit 1
    }
  ' "$work/names" || status=$?
  [[ "$status" -lt 2 ]] || unknown 'inventory classification failed'
  exit "$status"
)

# Keep every control's failure visible while exercising the remaining cases.
fail() {
  printf 'ADR numbering test: FAIL — %s\n' "$1" >&2
  failures=$((failures + 1))
}

mkdir -p "$scratch/unique" "$scratch/legacy" "$scratch/duplicate"
touch "$scratch/unique/0001-first.md" "$scratch/unique/0003-second.md"
check_numbering "$scratch/unique" || fail 'refused unique numbers'

for name in \
  0002-seal-zone-admission-secrets-before-readiness.md \
  0002-use-ecdsa-p256-for-client-update-trust.md \
  0013-publish-update-signatures-with-offline-opt-in-tooling.md \
  0013-retain-inactive-authoritative-mastery-transactions.md; do
  touch "$scratch/legacy/$name"
done
check_numbering "$scratch/legacy" || fail 'refused the exact historical pairs'

touch "$scratch/duplicate/0001-first.md" "$scratch/duplicate/0001-second.md"
status=0
check_numbering "$scratch/duplicate" > "$scratch/control.log" 2>&1 || status=$?
[[ "$status" == 1 ]] || fail 'accepted a new duplicate number'
grep -Fxq 'ADR numbering: duplicate number 0001' "$scratch/control.log" || fail 'new collision was not identified'

for number in 0002 0013; do
  touch "$scratch/legacy/$number-third.md"
  status=0
  check_numbering "$scratch/legacy" > "$scratch/control.log" 2>&1 || status=$?
  [[ "$status" == 1 ]] || fail "accepted a third record for $number"
  grep -Fxq "ADR numbering: duplicate number $number" "$scratch/control.log" || fail 'historical collision was not identified'
  rm "$scratch/legacy/$number-third.md"
done

mv "$scratch/legacy/0002-use-ecdsa-p256-for-client-update-trust.md" "$scratch/legacy/0002-replacement.md"
status=0
check_numbering "$scratch/legacy" > "$scratch/control.log" 2>&1 || status=$?
[[ "$status" == 1 ]] || fail 'accepted a replacement historical filename'
grep -Fxq 'ADR numbering: duplicate number 0002' "$scratch/control.log" || fail 'replacement collision was not identified'

mkdir "$scratch/empty"
for directory in "$scratch/empty" "$scratch/absent"; do
  status=0
  check_numbering "$directory" 2>/dev/null || status=$?
  [[ "$status" == 2 ]] || fail 'missing or empty inventory was not UNKNOWN'
done
ln -s "$scratch/unique" "$scratch/linked"
status=0
check_numbering "$scratch/linked" 2>/dev/null || status=$?
[[ "$status" == 2 ]] || fail 'linked directory was not UNKNOWN'

ln -s "$scratch/unique/0001-first.md" "$scratch/unique/0004-linked.md"
status=0
check_numbering "$scratch/unique" 2>/dev/null || status=$?
[[ "$status" == 2 ]] || fail 'linked ADR was not UNKNOWN'
rm "$scratch/unique/0004-linked.md"

mkdir "$scratch/bin"
cat > "$scratch/bin/find" <<'FIND'
#!/usr/bin/env bash
/usr/bin/find "$@"
exit 42
FIND
chmod +x "$scratch/bin/find"
status=0
PATH="$scratch/bin:$PATH" check_numbering "$scratch/unique" 2>/dev/null || status=$?
[[ "$status" == 2 ]] || fail 'failed inventory producer was accepted after valid-looking output'

check_numbering "$root/docs/adr" || fail 'repository ADR numbering is invalid'
[[ "$failures" == 0 ]] || exit 1
printf 'TEST PASS — ADR numbers are unique except the exact historical pairs\n'
