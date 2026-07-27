#!/usr/bin/env bash
set -euo pipefail

readonly RETAINED_TAG='v0.51.1'
readonly RETAINED_ASSET='WorldAtRuin-0.51.1-macOS-universal.zip'
readonly RETAINED_SHA256='291ac62a3d972656de1c1cca9255807ca08a9092a57be00cb34099c1e427119d'
readonly RETAINED_URL="https://github.com/devantler-tech/world-at-ruin/releases/download/${RETAINED_TAG}/${RETAINED_ASSET}"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
golden="$root/client/tests/data/golden_boot_recovery_v1.json"
workdir=$(mktemp -d "${TMPDIR:-/tmp}/war-retained-reader.XXXXXX")

cleanup() {
	case "${workdir:-}" in
		"${TMPDIR:-/tmp}"/war-retained-reader.*)
			rm -rf -- "$workdir"
			;;
	esac
}
trap cleanup EXIT

for tool in curl jq shasum unzip; do
	command -v "$tool" >/dev/null 2>&1 \
		|| {
			printf "retained-reader gate: required tool '%s' is unavailable\n" "$tool" >&2
			exit 1
		}
done

[ -f "$golden" ] \
	|| {
		printf 'retained-reader gate: shipped v1 golden is missing at %s\n' "$golden" >&2
		exit 1
	}

archive="$workdir/$RETAINED_ASSET"
if [ -n "${WAR_RETAINED_READER_ARCHIVE:-}" ]; then
	cp "$WAR_RETAINED_READER_ARCHIVE" "$archive"
else
	curl -fsSL --retry 3 --retry-all-errors -o "$archive" "$RETAINED_URL"
fi
printf '%s  %s\n' "$RETAINED_SHA256" "$archive" | shasum -a 256 -c -

unzip -q "$archive" -d "$workdir/app"
executable="$workdir/app/World at Ruin.app/Contents/MacOS/World at Ruin"
[ -x "$executable" ] \
	|| {
		printf 'retained-reader gate: released app executable is missing\n' >&2
		exit 1
	}

recovery="$workdir/boot_recovery.json"
cp "$golden" "$recovery"
WAR_SAVE_PATH="$workdir/character.json" \
WAR_VAULT_PATH="$workdir/vault.json" \
WAR_BOOT_RECOVERY_PATH="$recovery" \
	"$executable" --headless --quit-after 60 2>&1 | tee "$workdir/boot.log"

grep -Fq "BOOT_OK v${RETAINED_TAG#v} " "$workdir/boot.log" \
	|| {
		printf 'retained-reader gate: released app did not boot with its pinned version\n' >&2
		exit 1
	}
if grep -qE 'SCRIPT ERROR|^ERROR' "$workdir/boot.log"; then
	printf 'retained-reader gate: released app reported an error while consuming recovery v1\n' >&2
	exit 1
fi

# A boot marker is deliberately safe to ignore when unreadable, so BOOT_OK by
# itself is not proof. Require the retained app to clear the v1 golden's marker,
# quarantine that failed version, and preserve every other field.
jq -e '
	.version == 1
	and .marker == null
	and .quarantined == ["0.27.0", "0.28.0"]
	and .last_good == "0.26.0"
' "$recovery" >/dev/null

printf 'retained-reader gate: PASS — %s consumed and reconciled recovery v1\n' "$RETAINED_TAG"
