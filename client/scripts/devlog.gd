class_name DevLog
## The in-game development log.
##
## World at Ruin is built almost entirely by agents, and the owner watches
## development progress by playing. Every change that a player could notice
## gets an entry here, newest first — open it in-game with F1.

const VERSION := "0.1.4"
const CODENAME := "Ashfall Reach"

## Newest first. Keys: version, date, title, notes (Array[String]).
const ENTRIES: Array[Dictionary] = [
	{
		"version": "0.1.4",
		"date": "2026-07-17",
		"title": "Bodies from recipes",
		"notes": [
			"The character system exists. One canonical human body is now baked entirely by committed code — and every person in this world will be a RECIPE: a small text file of named sliders (broader shoulders, heavier gut, squarer jaw...) that reshapes that one body.",
			"Three first recipes stand in the gallery (scenes/recipes.tscn — the taste gate): a wanderer, a villager, and a brute. Same skeleton, same mesh, three different people.",
			"Recipes are forever: a golden recipe exercising every slider is locked into the tests — if a future change would break a character someone made, the build fails before it can.",
			"Clay-grey for now, and standing in a sculptor's pose: skin, hair and clothes are later stages of the system.",
		],
	},
	{
		"version": "0.1.3",
		"date": "2026-07-17",
		"title": "The first cave",
		"notes": [
			"A procedural cave chamber now exists — carved entirely from code, like everything else in the Reach: a seeded, rough-walled hollow with a flattened floor and a mouth you could walk in through.",
			"It lives in its own scene for now (the taste gate — judge it in the editor viewport, lit by embers and the light spilling through the mouth). It is not connected to the overworld yet.",
			"Same seed, same cave, every time — a regression test fingerprints the rock so it can never silently change shape.",
		],
	},
	{
		"version": "0.1.2",
		"date": "2026-07-16",
		"title": "The ground becomes real",
		"notes": [
			"Found the true root cause of the sinking and bumping: the terrain's surface was built facing DOWNWARD, so the ground was only half-solid — bodies sank into it, and the anti-stuck safeguard fought the resulting jitter. The world is now genuinely solid.",
			"A side effect of the same bug: the sun was lighting the underside of the world. The Reach is noticeably less murky now that its ground faces the sky.",
			"The safeguard also measures against the exact walkable surface (not the smooth mathematical curve), tolerates how a rounded body rests on slopes, and only intervenes when embedding persists.",
			"Two new always-run tests pin all of this: one buries a wanderer and demands the world give him back; one raycasts the whole Reach and demands the math and the physics agree exactly.",
			"Sprint momentum now carries through jumps instead of braking mid-air.",
		],
	},
	{
		"version": "0.1.1",
		"date": "2026-07-16",
		"title": "The ground no longer swallows wanderers",
		"notes": [
			"Fixed getting wedged inside the terrain after a hard fall (the first player-reported bug — reported minutes after the world first existed).",
			"Falls now cap at a survivable-feeling terminal speed, and the Reach pops you back onto the surface if the ground ever claims you.",
		],
	},
	{
		"version": "0.1.0",
		"date": "2026-07-16",
		"title": "The world exists",
		"notes": [
			"First walkable slice: the Ashfall Reach — a ruined field under a dying sky, generated entirely from code.",
			"The Wardens' shrine burns at the centre. It will be a respawn shrine one day; today it is a landmark and a promise.",
			"A wanderer (you) with third-person movement: walk, sprint, jump, mouse-look.",
			"Fall off the world and the shrine calls you back — the first, tiniest nod to the death rules.",
			"This dev log. Open it each build to watch the world grow.",
		],
	},
]
