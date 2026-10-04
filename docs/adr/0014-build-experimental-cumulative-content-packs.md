# ADR 0014: Build experimental cumulative content packs

Status: Accepted for explicitly enabled local tooling.

## Context

The released client is a whole application archive. The distribution contract requires a native
cumulative resource pack, protected recovery owners and exact-byte evidence before a future updater
can admit an overlay. Source-only packs miss imported textures and scenes, while exported bases can
redirect text resources to old compiled siblings.

## Decision

The offline Bash driver is disabled unless `--experimental` is explicit. Go selects the complete
reviewed content partition and snapshots a trusted local project into private staging. Godot imports
that snapshot and `PCKPacker` packages sorted source resources, their identity remaps and only the
generated import closure. Native resource serialization supplies deterministic imported-scene IDs.

`server/internal/contentpack/shell-resources.txt` declares exact recovery, trust and persistent-data
owners. Their sidecars and remap companions, the reserved `scripts/shell/` namespace, project
settings, test/tool trees and global class metadata cannot enter a replaceable pack. New protected
owners must be added deliberately. Selected links, unsupported file shapes and budget violations
refuse before publication.

The final build contains the PCK, an ordered resource inventory and a canonical receipt binding both
the pack's digest/size and every resource digest/size. The receipt is unsigned build evidence. It has
no update, delivery, signing or installation authority. Existing caller output is never replaced.

## Consequences

The exported-base fixture proves native overlay precedence, complete additions and imported
resources, protected recovery and a failing no-mount ablation. Two fresh builds must match exactly.
The same tooling is exercised over the actual game's imported scene closure.

Native import executes trusted local project code; this tool is not an untrusted-code sandbox.
The immutable base must already support the engine, global script class catalog and protected
owners needed by the candidate. New global classes, production bootstrap, retained pack admission,
health/quarantine, signing custody and delivery hosting remain separate activation work. Default
release exports and deferred update-manifest delivery fields retain their existing contract.
