# Retained mastery reader

The whole-app rollback target for capability-7 mastery writes is the published
[v0.91.0 release](https://github.com/devantler-tech/world-at-ruin/releases/tag/v0.91.0).
Its immutable asset is `WorldAtRuin-0.91.0-macOS-universal.zip`, with SHA-256:

```text
48fed3a099e0ff7ec33522d55b4d429664554d41aabacdd0e508f3c7359dd237
```

The downloaded archive matches GitHub's asset digest. The unmodified app boots with
`golden_vault_v5.json` at its isolated vault path, reporting `BOOT_OK v0.91.0` without errors,
and preserves the complete mastery snapshot. Its shipped `mastery_restore_boot_test.tscn` also
passes: the negative-control boot originates no mastery, and the seeded boot restores both
weapon tracks and the standing bloodstain while unrelated writes preserve them.

The official export executable disables scene-path overrides. The restoration assertions therefore
run from its unmodified shipped PCK using the identical official Godot engine version,
`4.7.1.stable.official.a13da4feb`. The separate unmodified-app boot proves the shipped executable
accepts the document; the PCK assertions prove that acceptance reaches the live ledger.

To reproduce after downloading, verifying and extracting that exact archive, set `app` to the
extracted `World at Ruin.app` and `probe` to a fresh temporary directory. From the repository root:

```sh
cp client/tests/data/golden_vault_v5.json "$probe/vault.json"
WAR_SAVE_PATH="$probe/character.json" \
  WAR_VAULT_PATH="$probe/vault.json" \
  WAR_BOOT_RECOVERY_PATH="$probe/recovery.json" \
  "$app/Contents/MacOS/World at Ruin" --headless --quit-after 60 \
  --log-file "$probe/boot.log"

WAR_SAVE_PATH="$probe/assert-character.json" \
  WAR_VAULT_PATH="$probe/assert-vault.json" \
  WAR_BOOT_RECOVERY_PATH="$probe/assert-recovery.json" \
  godot --headless --main-pack "$app/Contents/Resources/World at Ruin.pck" \
  --log-file "$probe/restore.log" res://tests/mastery_restore_boot_test.tscn
```

Require `BOOT_OK v0.91.0` from the first command and `TEST PASS` from the second, with no
`TEST FAIL`, `SCRIPT ERROR` or `ERROR` in either log. Compare the first command's resulting
`mastery` object with the golden as an additional preservation check. Keep the verified archive
available as the whole-app rollback; it is not a mountable-pack rollback target.
