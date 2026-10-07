# Experimental cumulative content packs

This is trusted local operator tooling, disabled unless explicitly enabled. It does not alter the
released client or offer players an update.

```bash
bash tools/build-contentpack.sh --experimental client /private/tmp/new-game-pack
go -C server run ./cmd/contentpack -experimental -operation verify -output /private/tmp/new-game-pack
bash tools/test-contentpack.sh
bash tools/test-game-contentpack.sh
```

Use a new output directory outside the source project. Each build imports a new private snapshot;
the source cache is not used as pack input or modified by the driver. Native work is bounded to
three minutes per process. The snapshot and selected resource counts are bounded before import,
each resource is at most 32 MiB, and cumulative resource bytes are at most 256 MiB.
Every import, export and mount uses the shared native process guard. A real infinite-loop control
lowers its budget to one second and proves forceful termination with visible diagnostics.

The pack contains every supported resource under abilities, assets, devlog, recipes, registries,
scenes, scripts and shaders, including attribution metadata and shader includes. Exact protected
owners and all their companions are excluded by the embedded shell inventory. The whole reserved
shell namespace, settings, tests/tools and global import metadata stay base-owned. Links and unknown
file shapes fail selection. Native-generated script UID sidecars join the packaged resource closure;
the two-build fixture includes a fresh script absent from the old base.

Imported model scenes are reserialized by the native engine with stable subresource and node IDs.
Scenes with unsupported node-ID references fail instead of having their reference semantics changed.
The full-game proof compares two clean builds and loads the main scene and an imported creature
from a base containing only protected owners and freshly imported class metadata. Its no-pack
ablation must fail; no game content in the base can supply the asserted resources.

The builder adds fresh import remaps and generated scene/texture targets, then explicit identity
remaps for text scenes, resources and scripts so exported-base compiled siblings cannot hide the
candidate. It independently reads back every staged resource before publication. A complete output
has `content.pck`, `resources.json` and the final `receipt.json`; incomplete staging is not a build.

Receipt verification requires the exact pack and retained inventory. Altered bytes, mismatched
resources, protected additions, unknown receipt fields and noncanonical receipts fail. Anyone can
create unsigned build evidence, so a matching receipt never substitutes for root/leaf signatures,
independent freshness, compatibility, rollback admission or installer authorization.

The candidate must fit the immutable base's engine and global-class catalog. Existing resources
may be replaced; introducing a class unknown to the base requires separate compatible shell work.
Runtime mounting, health/quarantine, production key custody and retained delivery are tracked in
the distribution issues. No delivery URL, rollback target or shell download is populated here.
The path inventory does not prove a transitive immutable execution boundary. Auditing protected
owners' dependencies after mounting remains an activation prerequisite in #1114.
