# Retained mastery reader

The retained whole-app rollback reader for capability-7 mastery is the published
[v0.93.1 release](https://github.com/devantler-tech/world-at-ruin/releases/tag/v0.93.1).
Its immutable asset is `WorldAtRuin-0.93.1-macOS-universal.zip` (asset `545689413`), with SHA-256:

```text
1c2ca1c69eb2b1030896b942f8de74d0c55589ce00b6ef974c117abd80fbfe27
```

The downloaded archive matches GitHub's asset digest. Release creation and
[CD run 33960482289](https://github.com/devantler-tech/world-at-ruin/actions/runs/33960482289)
completed successfully at commit `9429d1f8b660224180ea83fc9957e8301af9068c`; the release became
public and immutable on 2026-09-05 at 10:25:55 UTC. The build-derived update manifest advertises
read capability 7 while write capability remains 6. Its empty `rollback_targets` array describes
the future mountable-pack tier, not this retained whole-app ZIP.

The unmodified app boots with the literal-boundary vault below at its isolated path, reporting
`BOOT_OK v0.93.1` without errors, and preserves the complete mastery snapshot while adding the
ordinary starter-cave discovery. Its shipped `mastery_restore_boot_test.tscn` also
passes: the negative-control boot originates no mastery, and the seeded boot restores both
weapon tracks and the standing bloodstain while unrelated writes preserve them.

The official export executable disables scene-path overrides. The restoration assertions therefore
run from its unmodified shipped PCK using the identical official Godot engine version,
`4.7.1.stable.official.a13da4feb`. The separate unmodified-app boot proves the shipped executable
accepts the document; the PCK assertions prove that acceptance reaches the live ledger.

To reproduce after downloading, verifying and extracting that exact archive, set `app` to the
extracted `World at Ruin.app` and `probe` to a fresh temporary directory. From the repository root:

```sh
cp docs/evidence/issue-658-mastery-retention/boundary_vault.json "$probe/vault.json"
WAR_SAVE_PATH="$probe/character.json" \
  WAR_VAULT_PATH="$probe/vault.json" \
  WAR_BOOT_RECOVERY_PATH="$probe/recovery.json" \
  "$app/Contents/MacOS/World at Ruin" --headless --quit-after 60 \
  --log-file "$probe/boot.log"

WAR_VAULT_PATH="$probe/vault.json" godot --headless --path client \
  --script "$(pwd)/docs/evidence/issue-658-mastery-retention/verify_boundary.gd"

WAR_SAVE_PATH="$probe/assert-character.json" \
  WAR_VAULT_PATH="$probe/assert-vault.json" \
  WAR_BOOT_RECOVERY_PATH="$probe/assert-recovery.json" \
  godot --headless --main-pack "$app/Contents/Resources/World at Ruin.pck" \
  --log-file "$probe/restore.log" res://tests/mastery_restore_boot_test.tscn
```

Require `BOOT_OK v0.93.1` from the executable, and `TEST PASS` from both assertion commands, with
no `TEST FAIL`, `SCRIPT ERROR` or `ERROR`. The boundary assertion uses Godot's own JSON parser:
quest progress must remain `9007199254740991`, mastery bank `9007199254740900`, unbanked points
`91`, and bloodstain points `1`. It also requires the discovery written during boot. Keep the
verified archive available to reproduce this whole-app reader; it is not a mountable-pack target.

The earlier v0.91.0 baseline is not a lossless rollback target. Its verified archive has SHA-256
`48fed3a099e0ff7ec33522d55b4d429664554d41aabacdd0e508f3c7359dd237`. The same literal-boundary
probe lets that unmodified app boot successfully, but its rewritten quest token becomes
`9007199254740991.0`, which Godot decodes as `9007199254740990`. The boundary assertion rejects
that output and accepts v0.93.1, which contains the precision repair from #802. A clean `BOOT_OK`
alone does not prove progression preservation.
