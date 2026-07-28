# Issue #466 — the pre-release block, as a player reads it

![The bottom of the F1 dev log: entries 0.1.1 and 0.1.0 rendered without a leading v, each followed
by "never released; first shipped in v0.1.15"](devlog-prerelease-block.png)

This 1600×900 frame is rendered by the actual Godot `Hud` and `DevLog` classes at the PR head, by
`client/tools/devlog_capture.tscn`. It shows the **bottom** of the log — the oldest entries, which
are what this change alters. The default scroll position shows the newest entries instead, so a shot
of the panel as it opens would be a frame of the log rather than a frame of the change.

- **Art-direction reference:** [`UI and UX (#227)`](../../art-direction/README.md#ui-and-ux-227) —
  the interface belongs to the world, with typographic hierarchy carrying the meaning.
- **Visible result:** `0.1.1` and `0.1.0` render **without the leading `v`**, and each carries a
  dimmed `never released; first shipped in v0.1.15`. Every entry above the block is unchanged and
  still reads `v0.66.x — …`, so the two classes are distinguishable at a glance: a `v` means a build
  that existed, no `v` means a note from before the first release.
- **Before this change:** the same two entries rendered `v0.1.1 — …` and `v0.1.0 — …`, identical in
  form to a real release, dating that work to builds that were never cut.

## Remaining gap

- The dimmed note **wraps mid-phrase** at this viewport — `… · never` / `released; first shipped in
  v0.1.15`. It is legible and wraps like any other long line in the panel, but it is not a
  deliberate typographic break. Giving the note its own line would read cleaner at the cost of a
  line per entry; not taken here, and recorded rather than claimed as finished.
- The panel is still an undecorated dark rectangle — the framed-panel, material and iconography
  target in the reference above is untouched by this change, which is prose and typography only.
- The entries' own text is unchanged. Several of the oldest read as terse development notes rather
  than the player-facing voice the newer entries use; that is a separate content pass.
