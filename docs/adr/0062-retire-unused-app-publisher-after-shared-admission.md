# ADR 0062: Retire the unused App publisher after shared admission adoption

- Status: Accepted
- Date: 2026-10-25
- Delivery issue: [#746](https://github.com/devantler-tech/world-at-ruin/issues/746)

## Decision

The active required source is
`devantler-tech/.github/.github/workflows/repository-pr-admission.yaml` at
`refs/heads/main`. This cross-product runner resolves GitHub's immutable product
base and invokes the fixed `.github/actions/pr-admission` from that reviewed
base. World owns its complete evaluator, scenes, fixture exceptions, containment,
cleanup and deadline; candidate files cannot select or replace these controls.
The default-branch repository result binding remains enforced with the GitHub
Actions identity and no bypass. An ordinary candidate-authored CI status alone
does not establish that the independently required source executed.

This supersedes the World-only catalogue routing in ADR 0003, retaining its
candidate-independent selection and product-law requirements. It also supersedes
the unactivated App-publisher alternative in ADR 0027. No additional App,
permission, shared credential change or publisher activation is required.

## Evidence and source retirement

The World action shipped in [#1530](https://github.com/devantler-tech/world-at-ruin/pull/1530).
Native complete-suite overlap and refusal evidence preceded the reviewed
[catalogue retirement](https://github.com/devantler-tech/.github/pull/760).
Its signed v13.2.9 manifest was independently verified and reconciled; the old
managed ruleset identity was retained disabled, rather than orphaned or deleted.
Other effective protection bindings were independently compared unchanged.

After that retirement, [#1555](https://github.com/devantler-tech/world-at-ruin/pull/1555)
ran all 187 trusted scenes successfully through the shared source and merged
under normal protection. The unmerged
[#1556](https://github.com/devantler-tech/world-at-ruin/pull/1556) supplied a
candidate no-op validator and a real product parse error; the independently
required shared runner failed on that error. Each observation binds its exact
head, reviewed base, integration parents, run and attempt. Neither fixture-only
tests nor the old App diagnostic substitutes for these native observations.

A fresh default-source census of all 23 active portfolio repositories found no
workflow or composite-action consumer of the unused World App producer outside
World. Local caller closure identifies only its own workflow, guards and tests.
Remove that workflow, resolver, publisher and their exclusive guards. Preserve
the active shared admission action, legacy contained controller and sandbox
helpers, and their complete tests. Remove only CI calls to the retired guards.

Retain `tools/trusted-gate inspect` as a historical, read-only App-overlap
diagnostic with complete API/refusal controls. It cannot resolve candidates or
publish checks; HTTP methods other than body-free GET fail before network use.
Its historical overlap requires the old active rule and App binding, so failure
after this retirement is expected. It does not verify current shared protection
and its `activation_ready=unknown` output never authorizes activation.

## Recovery and limits

No enforcement or credential settings change in this source retirement. A
future routing recovery must be reviewed in the declarative GitHub owner,
verify restored protection and native controls before a cutover, and preserve
the managed policy identity. Restoring an unused publisher file or setting its
old activation variable is not a recovery procedure.

Complete CI, security, exact-head review and protected merges remain required.
The separate whole-feedback performance outcome stays open in #1495; successful
ownership migration is not a claim that every PR finishes within 15 minutes.
