#!/usr/bin/env bash
# Derive the update manifest's anti-replay `sequence` from the release version.
#
# WHY NOT THE WALL CLOCK. The obvious source is `date -u +%s` at publication.
# It is monotonic in the instant it is SAMPLED, which is not the thing that has
# to be ordered: CD's concurrency group is scoped per tag
# (`CD-${github.ref_name}`), so two releases run CONCURRENTLY. A run that
# samples an earlier second can reach `oras tag ... latest` after a run that
# sampled a later one, and `latest` then serves a manifest whose sequence is
# HIGHER than the newer release's. A client that recorded the newer mark
# rejects everything after it until the next release — and, worse, a client
# that had not would accept the OLDER build as if it were newer, because its
# counter says so. Sampling per runner also lets two publications land in the
# same second, and a skewed runner clock can mint a far-future mark that
# suppresses every later manifest.
#
# THE VERSION IS ALREADY THE PUBLICATION ORDER. semantic-release only ever
# increases it, so ordering by version is ordering by release. That fixes the
# inversion at its root rather than racing it:
#
#   * concurrent runs cannot invert — the mark does not depend on when a runner
#     happened to look at a clock;
#   * an out-of-order `latest` retag becomes SAFE instead of harmful. It still
#     exposes the older build, but that build now carries the LOWER mark, so a
#     client refuses it as stale — which is the correct answer — instead of
#     accepting a downgrade;
#   * re-running CD for the same tag republishes the same mark, because it is
#     the same publication;
#   * two publications can never collide, and no clock is read at all.
#
# THE KNOWN LIMIT, stated rather than hidden: a SECOND manifest for an ALREADY
# RELEASED version cannot supersede the first, because the mark would be equal.
# That is not reachable today — a manifest is only ever published as part of a
# release, and a release is a version — but it is what to revisit if revocation
# ever needs to be re-published between releases. The answer then is a
# durable per-publication counter, not a return to sampling a clock.
#
# The ADR warns against deriving the envelope inside the BUILD, which is why
# `UpdateManifest.build()` takes it as an argument. This is the publisher, which
# is exactly where that choice belongs.
#
# Usage: tools/manifest-sequence.sh <version>     # e.g. 0.1.17 -> 1017
set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "usage: tools/manifest-sequence.sh <major.minor.patch>" >&2
	exit 2
fi

version="$1"

# Dotted integers only, and no leading zeros: `01` and `1` would otherwise both
# parse to 1, so two distinct tags could mint the same mark. `UpdateManifest`
# refuses a non-dotted version anyway (a prerelease tag never reaches here), so
# this rejects the same shapes the client would.
if ! printf '%s' "${version}" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
	echo "::error::'${version}' is not a major.minor.patch version, so no monotonic sequence can be derived from it" >&2
	exit 1
fi

major="${version%%.*}"
rest="${version#*.}"
minor="${rest%%.*}"
patch="${rest##*.}"

# Positional, base 1e6 per component. Wide enough that no realistic minor or
# patch run reaches it, and the whole value stays far inside the int64 every
# consumer (JSON, GDScript, the client's stored high-water mark) uses. A narrow
# base would silently wrap one component into the next and invert the order it
# exists to preserve, so the bound is checked rather than assumed.
limit=1000000
for component in "${major}" "${minor}" "${patch}"; do
	if [ "${component}" -ge "${limit}" ]; then
		echo "::error::version component '${component}' in '${version}' reaches the ${limit} positional base — the sequence encoding would carry into the next component and stop being monotonic" >&2
		exit 1
	fi
done

printf '%s\n' "$(( major * limit * limit + minor * limit + patch ))"
