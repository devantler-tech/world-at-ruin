# Canonicalise cone inputs at the authority

Status: accepted for the cone threshold and facing (#1447).

## Context

The server resolves a telegraph from the shape it stores, and a player can only
dodge what the client paints. The client cast factory refuses a cone whose
threshold lies outside `[-COS_SCALE, COS_SCALE]` or whose facing has no planar
direction, because an authoring error should be loud rather than a silent
default. The server geometry clamps the same threshold and resolves a zero
facing as world-forward. Both wire codecs already refused an out-of-range
threshold, but both accepted a zero-facing cone. A cone the server resolved
with the fallback heading would therefore reach a client that refuses to paint
it, which is the invisible-danger direction the extent cap already rules out.

## Decision

The server is the authority, and it canonicalises at construction.
`sim.ConeTelegraph` clamps the threshold and stores world-forward for a facing
with no planar direction. That is the heading membership resolves it to, so the
stored cone is exactly the cone the server resolves and sends.

Every boundary downstream of construction refuses a non-canonical cone. Both
wire codecs refuse a zero planar facing in addition to an out-of-range
threshold, and the client cast factory keeps its loud refusal. A refusal can
then only come from a hand-built shape or a client-side authoring error, never
from a cone the server resolves.

The client does not mirror the server's clamp and fallback. Doing so would turn
its authoring refusals into silent defaults, and it would still let a
non-canonical shape cross the wire.

## Evidence

`client/tests/data/cone_input_authority.json` holds shared input vectors. The Go
test in `server/wire` and `client/tests/cone_input_authority_test` both read it:
each raw input is accepted or refused identically by both codecs and the client
factory, and the canonical cone the server stores for every input is accepted
by all three. A membership comparison shows the stored world-forward facing
catches exactly what the zero facing caught through the fallback, and the
server produces only circle casts today, so no existing cast changes.

## Not covered

Rectangles keep the zero-facing fallback without canonicalisation. They have no
client caster yet; they adopt this rule when one is added.
