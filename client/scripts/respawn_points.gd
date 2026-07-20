class_name RespawnPoints
## Resolves an attunement NAME from the save vault to a live position in the
## built world (issue #249, review of #254).
##
## This exists because a name registry alone is not a guarantee. `SaveVault`
## knows which names have shipped, and its guard proves those names survive a
## round-trip and are still listed — but "listed" is not "acted on". Restore
## behaviour used to be hard-coded in main.gd against one constant, so a name
## could be added to the ledger and to KNOWN_ATTUNEMENTS while nothing ever
## restored it: every guard green, the attunement dead.
##
## Putting resolution HERE gives the behaviour one home, and lets a test walk
## every shipped name end-to-end — seed it, boot, and require the wanderer to
## actually wake there. A name with no branch below fails that test, which is
## the property the ledger by itself cannot express.
##
## Positions are re-derived from the LIVE world every time, never persisted. The
## Reach is generated: a stored coordinate would drop a returning player
## underground the moment world generation shifts, so the vault stores the name
## and this resolves it against the world that exists now.


## Every attunement name this build can actually restore. Must equal
## SaveVault.KNOWN_ATTUNEMENTS — save_vault_test pins that, so the data layer
## and the behaviour layer cannot drift apart.
static func names() -> Array:
	return [SaveVault.SHRINE_WARDENS]


## The live world position for `name`, or null when this build has no branch for
## it. Null is the signal a caller must tolerate: a vault written by a newer
## client can carry a name this build genuinely cannot place, and that must
## degrade to "wake where you started", never to a crash or a blocked boot.
static func resolve(name: String, world: WorldGen) -> Variant:
	if world == null:
		return null
	match name:
		SaveVault.SHRINE_WARDENS:
			return world.shrine_respawn_point()
	return null
