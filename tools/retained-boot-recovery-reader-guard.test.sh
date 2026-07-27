#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFIER="$ROOT/tools/verify-retained-boot-recovery-reader.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"
EXPECTED_TAG='v0.51.1'
EXPECTED_SHA256='291ac62a3d972656de1c1cca9255807ca08a9092a57be00cb34099c1e427119d'

fail() {
	printf 'retained boot-recovery reader guard: FAIL — %s\n' "$1" >&2
	exit 1
}

[ -x "$VERIFIER" ] || fail 'the executable retained-reader verifier is missing'

grep -Fq "RETAINED_TAG='$EXPECTED_TAG'" "$VERIFIER" \
	|| fail "the verifier does not pin retained reader $EXPECTED_TAG"
grep -Fq "RETAINED_SHA256='$EXPECTED_SHA256'" "$VERIFIER" \
	|| fail 'the verifier does not pin the retained archive digest'
grep -Fq 'client/tests/data/golden_boot_recovery_v1.json' "$VERIFIER" \
	|| fail 'the verifier does not seed the shipped recovery-v1 golden'

for seam in WAR_SAVE_PATH WAR_VAULT_PATH WAR_BOOT_RECOVERY_PATH; do
	grep -Fq "$seam=" "$VERIFIER" \
		|| fail "the verifier does not isolate $seam"
done

grep -Fq 'tools/retained-boot-recovery-reader-guard.test.sh' "$WORKFLOW" \
	|| fail 'CI does not run the structural retained-reader guard'
grep -Fq 'tools/verify-retained-boot-recovery-reader.sh' "$WORKFLOW" \
	|| fail 'CI does not exercise the retained reader artifact'

printf 'retained boot-recovery reader guard: PASS\n'
