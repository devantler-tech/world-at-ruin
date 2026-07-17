class_name DevLog
## The in-game development log.
##
## World at Ruin is built almost entirely by agents, and the owner watches
## development progress by playing. Every change that a player could notice
## gets an entry here, newest first — open it in-game with F1.

const VERSION := "0.1.5"
const CODENAME := "Ashfall Reach"

## Newest first. Keys: version, date, title, notes (Array[String]).
const ENTRIES: Array[Dictionary] = [
	{
		"version": "0.1.5",
		"date": "2026-07-17",
		"title": "The first wanderer takes shape",
		"notes": [
			"A human figure now stands in the cave — the first character. The body is a CC0 base mesh; everything about how he stands is code: his proportions are reshaped bone by bone (broader chest, heavier forearms, larger hands) and his arms are lowered from the sculptor's T-pose into a relaxed stance, all by a script.",
			"A second taste-gate scene (scenes/character.tscn) lines up three builds of the same body — grounded, hero, base — so the proportion range can be judged side by side.",
			"Same parameters, same body, every time: a regression test fingerprints the skeleton and the deformed skin so the figure can never silently change shape.",
		],
	},
	{
		"version": "0.1.4",
		"date": "2026-07-17",
		"title": "Play it without the editor",
		"notes": [
			"World at Ruin is now a real, double-clickable Mac app: every build exports a signed universal .app you can download from the project's build page — no Godot editor required.",
			"The build machinery smoke-boots the exported app itself before publishing it, so a download that would not start never ships.",
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
