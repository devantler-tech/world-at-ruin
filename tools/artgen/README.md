# artgen — the headless art pipeline (Phase 0)

Procedural art generation in **pure Go** (`qmuntal/gltf` for export) — the
portfolio's bash/Go-only scripting rule holds here after all: geometry is just
math, and glTF is just a file format. Nothing in this stage needs Blender.

Rules of the directory:

- **Deterministic or it doesn't merge.** Geometry derives only from `-seed`
  (a seeded permutation table drives the noise field itself), so the same seed
  produces **byte-identical** `.glb` output; CI runs each generator twice and
  compares bytes. Unit tests pin determinism, seed divergence, and shape
  invariants.
- **No downloads at generate time.** Materials are procedural glTF PBR factors
  for now; CC0 texture sets (Poly Haven / ambientCG) arrive in a later stage as
  *committed*, licence-checked assets, never as network fetches in CI.
- **Output is never committed.** Generated glTF lands in
  `client/assets/generated/` (gitignored); CI regenerates it and uploads the
  `.glb` as a workflow artifact so a human can look at it — the Phase 0 taste
  gate is a maintainer judgement, not a test.

Generate the cave locally (Go ≥ the version in `go.mod`):

```sh
cd tools/artgen
go run ./cmd/cave -seed 42 -out ../../client/assets/generated/cave.glb
```

Stage map (issue #1's machine-verifiable half, tracked as #20):

1. **`cmd/cave`** — one procedural cave chamber: noise-carved icosphere shell,
   flattened floor band, cut entrance, interior-facing windings, procedural
   rock material. Exported as `.glb`, imported headlessly by Godot in CI.
2. Character (next) — **open tooling decision, flagged on #20**: MPFB2/Rigify
   quality lives in Blender, whose only scripting surface is Python (it would
   need a narrow, isolated exception the maintainer explicitly re-approves);
   the alternative is parametric body generation in Go at real art-quality
   risk. Decide when the stage starts — the cave stage deliberately avoids
   spending that exception.
3. Materials — committed CC0 PBR sets + SDFGI-lit look development.
