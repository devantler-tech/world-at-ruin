# World at Ruin

A **source-available, cloud-native MMORPG built almost entirely by AI agents** — authored as code,
built headlessly, and grown in public over years. This is the newest and lowest-priority product of
[devantler-tech](https://github.com/devantler-tech): agents pick it up when nothing else demands
attention, and every visible change lands in the in-game dev log so progress can be watched by
*playing*.

> **Status: pre-alpha `v0.1.0` — "Ashfall Reach".** A first walkable slice: a procedurally
> generated ruin field, the Wardens' shrine, and a wanderer with third-person movement. No combat,
> no networking, no persistence yet — those arrive issue by issue via the
> [roadmap](https://github.com/devantler-tech/world-at-ruin/issues?q=label%3Aroadmap).

## Play it

**Without the editor (macOS):** every `main` build exports an ad-hoc-signed
universal `World at Ruin.app` — grab the `WorldAtRuin-macOS-universal` artifact
from the latest
[`main` CI run](https://github.com/devantler-tech/world-at-ruin/actions/workflows/ci.yaml?query=branch%3Amain+event%3Apush)
(use that filtered list, not a PR run — PR artifacts carry unmerged code).
Unzip the download **twice** (GitHub wraps the artifact in an outer ZIP; inside
it is `WorldAtRuin.zip`, which contains the app), then right-click → **Open**
the first time (the app is ad-hoc signed, not notarized, so Gatekeeper asks
once). Or export it yourself with the `macOS` preset in
`client/export_presets.cfg` (needs the 4.7.1 export templates installed in the
Godot editor).

**From the project** — requires [Godot 4.7+](https://godotengine.org) (macOS: `brew install --cask godot`):

```sh
git clone https://github.com/devantler-tech/world-at-ruin.git
cd world-at-ruin
godot client   # or: /Applications/Godot.app/Contents/MacOS/Godot client
```

**Controls:** `WASD` move · `Shift` sprint · `Space` jump · mouse look · `L`/`F1` dev log ·
`Esc` release mouse.

**Watch the world grow:** press `L` in-game. Every player-visible change is a dev-log entry,
newest first — replaying after each build shows exactly what the agents grew.

## What this is (and isn't)

- **Everything is text-authored** — scenes, world generation, materials, and (eventually)
  characters are code, built headlessly in CI. If an agent can't author it in a diff, it doesn't
  get built.
- **Forward-only, no resets** — the design forbids wipes, seasons, and stat squishes. An early
  character keeps playing as the world evolves. The CI guards for this exist before the first
  player does.
- **Source-available, not open source** — see [LICENSE.md](LICENSE.md). Reading is welcome;
  copying and redistribution are not permitted.

The full settled design — engine choice, art pipeline, server architecture, economy laws, and
combat design — lives in [AGENTS.md](AGENTS.md).
