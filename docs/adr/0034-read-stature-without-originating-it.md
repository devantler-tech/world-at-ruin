# ADR 0034: Read stature without originating it

## Status

Accepted

## Context

Character recipes need independent upper- and lower-leg lengths while existing characters retain their exact appearance. Expanding the reader must not authorize new persisted vocabulary or weaken ordinary-edit preservation, deletion protection, or update recovery.

## Decision

Recipe version 5 reads `joint_push.thigh` and `joint_push.calf`. They scale the knee and ankle offsets respectively; the hip separation and bone bases remain unchanged. Recipe versions 1–4 refuse these keys. Absent keys preserve historical geometry and fingerprints. Equipment uses the same adjusted skeleton. New leg operations follow the existing stance edits, then the visual root shifts by the change in the lowest ankle rest. This keeps rendered soles within 3 mm of the historical floor contact while the real Player capsule and historical characters remain unchanged. The computation uses composed rests; it does not build a neutral second character or skin vertices during production construction.

The recipe origination ceiling stays 4 and the content writer capability stays 7. The reader advertises recipe ceiling 5 and content capability 8. Production creation controls and writer vocabulary expose no leg-length setting. An ordinary edit of an already accepted v5 document preserves its version and the exact presence and values of both leg keys. Adding, changing, removing, downstamping, or deleting reader-only state is refused under the existing persistence lock. The real post-staging commit rereads the accepted target and revalidates reader-only preservation, including blind callers, so foreign expanded state installed during serialization survives. Ordinary blind replacements and exact expanded-value edits remain permitted.

Update checks consume the accepted character requirements, separately from the reader ceiling: ordinary or absent character state remains schema4/capability7, while an accepted v5 character requires schema5/capability8. Unknown or changed requirements cannot authorize update-history acceptance. Older recovery targets are ineligible for v5 state.

A retained, published whole-app reader must independently boot and preserve expanded state before a separate writer-contract change may originate it. A manifest declaration, local render, CI result, or merge does not establish that retained release. New races, presets, creation controls, and visual activation remain separate work.

## Consequences

Current presets and creation behavior stay identical. The expansion makes stature representable without creating new player state. Compatibility proof includes the reviewed golden fixture, independent geometry and equipment clearance oracles, exact historical fingerprints, refused destructive writes, actual isolated game boots and update facts, and recovery eligibility.
