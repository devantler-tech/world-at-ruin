class_name DevLog
## The in-game development log.
##
## World at Ruin is built almost entirely by agents, and the owner watches
## development progress by playing. Every change that a player could notice
## gets an entry here, newest first — open it in-game with F1.

const VERSION := "0.1.2"
const CODENAME := "Ashfall Reach"

## Newest first. Keys: version, date, title, notes (Array[String]).
const ENTRIES: Array[Dictionary] = [
	{
		"version": "0.1.2",
		"date": "2026-07-16",
		"title": "The ground becomes real",
		"notes": [
			"Found the true root cause of the sinking and bumping: the terrain's surface was built facing DOWNWARD, so the ground was only half-solid — bodies sank into it, and the anti-stuck safeguard fought the resulting jitter. The world is now genuinely solid.",
			"A side effect of the same bug: the sun was lighting the underside of the world. The Reach is noticeably less murky now that its ground faces the sky.",
			"The safeguard also measures against the exact walkable surface (not the smooth mathematical curve), tolerates how a rounded body rests on slopes, and only intervenes when embedding persists.",
			"Two new always-run tests pin all of this: one buries a wanderer and demands the world give him back; one raycasts the whole Reach and demands the math and the physics agree exactly.",
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
