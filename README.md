# World at Ruin

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

**Or download the app yourself:** take `WorldAtRuin-<version>-macOS-universal.zip` from the
[latest release](https://github.com/devantler-tech/world-at-ruin/releases/latest), unzip it, and
move `World at Ruin.app` into `/Applications`. The build is ad-hoc signed rather than notarized,
so macOS quarantines the download and refuses to open it — clear that flag once and it starts
normally:

```sh
xattr -dr com.apple.quarantine "/Applications/World at Ruin.app"
```

The Homebrew cask runs exactly that for you, which is why it needs no extra step.

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
