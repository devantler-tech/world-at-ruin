# World at Ruin

<img width="750" alt="image" src="https://github.com/user-attachments/assets/c637c97e-bf1c-4c2c-89f6-193943af4292" />

A **source-available, cloud-native MMORPG built almost entirely by AI agents** — authored as code,
built headlessly, and grown in public over years. This is the newest product of
[devantler-tech](https://github.com/devantler-tech), a first-class member of the portfolio, and
every visible change lands in the in-game dev log so progress can be watched by *playing*.

**The fiction:** a far-future world laid waste by a mystical disaster, now at rebirth. You wake in
a cave with nothing but ragged clothes and bare hands, fight your way to the surface, and step into
a barren world coming back to life — wasteland beside lush zones, new lifeforms and monsters,
humanoids and aliens, iron swords beside laser blades. Medieval-futuristic, and the medieval feel
wins.

> **Status: pre-alpha — "Ashfall Reach".** You wake in the starter cave, shape your character
> (body, face, equipment, skin — all persisted forward-only per the product law), and step out
> into a procedurally generated ruin field: the Wardens' shrine, a seeded settlement, and
> drifters in the open land. No combat, no networking yet — those arrive issue by issue via the
> [roadmap](https://github.com/devantler-tech/world-at-ruin/issues?q=label%3Aroadmap); the
> in-game dev log (`L`) is the precise changelog.

**Want to see it without installing anything?** [Phase 0 — the taste gate](docs/phase-0/) has
frames of the character and the cave, rendered from the running game.

## Play it

**macOS only for now** — one universal build covers Apple Silicon and Intel, and needs macOS 11 or
newer. Windows and Linux builds aren't exported yet.

**Homebrew** is the easiest way in, and the only one that keeps you on the newest build:

```sh
brew tap devantler-tech/tap
brew trust --cask devantler-tech/tap/world-at-ruin
brew install --cask world-at-ruin
```

From then on `brew upgrade --cask world-at-ruin` pulls each new release. (`brew trust` matters only
if your Homebrew is set to require trusting third-party taps — running it either way is harmless.
It's scoped to this one cask on purpose: trusting the whole tap would also cover everything else
it ships, now and in future.)

Manual GitHub Release downloads are not currently supported. The build is ad-hoc signed rather
than notarized, so macOS will quarantine it; do not clear that quarantine yourself on an unverified
download. Use the Homebrew cask above: it verifies the pinned release checksum, then removes
quarantine for those verified bytes. Or run the game from source below.

**Or run it from source** — requires [Godot 4.7+](https://godotengine.org)
(macOS: `brew install --cask godot`):

```sh
git clone https://github.com/devantler-tech/world-at-ruin.git
cd world-at-ruin
godot client   # or: /Applications/Godot.app/Contents/MacOS/Godot client
```

To build your own `.app` instead, export with the `macOS` preset in `client/export_presets.cfg`
(needs the 4.7.1 export templates installed in the Godot editor).

**Controls:** `WASD` move · `Shift` sprint · `Space` jump · `E` interact · mouse look ·
`C` reshape character · `L`/`F1` dev log · `Esc` release mouse.

**Watch the world grow:** press `L` in-game. Every player-visible change is a dev-log entry,
newest first — replaying after each build shows exactly what the agents grew.

**Ragged-cloth material preview:** launch from source with
`WAR_RAGGED_CLOTH_DETAIL=1 godot --path client`, or prefix the installed app's
executable with the same environment setting. In the creator, leave the wardrobe
bare to inspect the immutable base cloth. This opt-in previews woven fibres,
worn sewing, broad gathered folds and rounded folded-edge lighting. The angular
cut, thick waist silhouette, fraying and cloth motion remain unfinished.
[Before/after frames and fold-only controls](docs/evidence/issue-958-gathered-wrap/README.md)
show the current gap. Ordinary launches keep the shipped material and all saved
characters retain their existing equipment and shapes.

**Ragged-wrap geometry preview:** independently opt into
`WAR_RAGGED_CLOTH_DRAPE=1` for static outward folds and a softer hanging outline.
The hanging panels join the fixed waist gradually. Combine it with the material
setting above to inspect both. Ordinary launches
keep the shipped mesh. [Front, rear, profile and gameplay comparisons](docs/evidence/issue-949-ragged-drape/README.md)
show the remaining rigid-panel and waist-band gaps. The
[rear coverage repair](docs/evidence/issue-952-rear-coverage/README.md) closes the
preview's small body opening below the belt. This is an
unfinished preview, with a separate accept-or-retire decision due 2026-11-01.

**Private server trial:** the owner can observe the developing server through the
[verified localhost tunnel](docs/zone-tunnel.md). It shows scripted replicas with a
separate temporary character; shared controls and online progression remain in development.

## What this is (and isn't)

- **Everything is text-authored** — scenes, world generation, materials, and characters are code,
  built headlessly in CI. If an agent can't author it in a diff, it doesn't get built.
- **No resets, no silent loss** — the design forbids wipes, seasons, and stat squishes. An early
  character keeps playing as the world evolves: the game can be migrated, but only without breaking
  your character, or through a deprecation that tells you first what is changing or going away.
  Unfinished features are opt-in. The CI guards for this exist before the first player does.
- **Source-available, not open source** — see [LICENSE.md](LICENSE.md). Reading is welcome;
  copying and redistribution are not permitted. Playing a distributed build is governed by the
  [EULA](EULA.md), and contributing requires signing the [CLA](CLA.md) (copyright assignment) —
  the CLA check on your first pull request explains how to sign.

The full settled design — engine choice, art pipeline, server architecture, economy laws, and
combat design — lives in [AGENTS.md](AGENTS.md).
