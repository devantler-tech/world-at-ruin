class_name DevLog
## The in-game development log.
##
## World at Ruin is built almost entirely by agents, and the owner watches
## development progress by playing. Every change that a player could notice
## gets an entry here, newest first — open it in-game with F1.

const VERSION := "0.1.17"
const CODENAME := "Ashfall Reach"

## Newest first. Keys: version, date, title, notes (Array[String]).
const ENTRIES: Array[Dictionary] = [
	{
		"version": "0.9.0",
		"date": "2026-07-19",
		"title": "It knows what you are holding",
		"notes": [
			"The hints along the bottom of the screen, and the prompt that appears when something is within reach, now name only the device actually in your hands. Pick up a controller and they become controller prompts; touch the keyboard and they turn back, before the next thing you walk up to.",
			"They used to say both at once — a keyboard line and a controller line stacked together, and prompts that read \"E · pad X\" whichever one you were using. Half of that was always about a device you had put down.",
		],
	},
	{
		"version": "0.8.0",
		"date": "2026-07-19",
		"title": "The mountain wears its weather",
		"notes": [
			"The rock you wake inside now looks like it has stood in the open for an age. Seen from the Reach, the massif's outer faces carry bleached, wind-worn layers, scour streaks running down the steep sides, and drifts of ash settling wherever the stone lies back — the same ash the ground wears, so the mountain finally belongs to the land around it instead of sitting on it like a smooth dome.",
			"Step back inside and nothing has changed: the warm banded strata of the cave are exactly as they were. The weather stops at the mouth, the way weather does.",
		],
	},
	{
		"version": "0.7.0",
		"date": "2026-07-18",
		"title": "The scrub gathers",
		"notes": [
			"Ground cover no longer sprinkles itself evenly across the Reach like confetti. Scrub and dead grass now gather into thickets in the hollows and thin away on exposed ground, leaving genuinely bare stretches between — so one patch of the Reach finally looks different from the next, and a distant band of growth is something to steer by.",
			"What grows where now follows the land: grasses and shrubs keep to the flatter, sheltered ground, while bones and rubble collect on the slopes and in their own scattered fields — places where something happened.",
			"The amount of cover hasn't changed. It is the same scenery budget, spent with intent instead of spread thin everywhere.",
		],
	},
	{
		"version": "0.6.0",
		"date": "2026-07-18",
		"title": "Pick up a controller",
		"notes": [
			"The Reach now plays from the couch. The left stick walks — tilt gently for a stroll, push it all the way to hurry — and the right stick looks around, with the same limits the mouse has always had, so the camera can't flip or spin.",
			"Jumping, sprinting, interacting, the character editor and this very log all sit on the pad's buttons too. Waking for the first time works pad-in-hand as well: the character shaper opens ready to steer with the D-pad.",
			"The hints at the bottom of the screen now tell both stories — keys and pad — and prompts on things you can touch show both buttons. Nothing about keyboard and mouse play changed: same keys, same feel.",
		],
	},
	{
		"version": "0.5.0",
		"date": "2026-07-18",
		"title": "Scrub, straw and bone",
		"notes": [
			"The ground cover was standing in for itself — a ball for a bush, a flat wedge for grass, a box for a pile of bones. It is now built as the thing it is: scrub you can pick individual leaves out of, grass that reads as separate blades, and heaps of broken stone and bone with uneven, weathered surfaces instead of one flat colour.",
			"The low sun now shines through the thin stuff. Dry grass lights up from behind when you look toward the horizon, and no two clumps are quite the same shade, so a stretch of ground reads as a place rather than as a pattern.",
			"And it moves. A dry wind crosses the Reach in gusts, and the scrub and grass lean downwind together as each gust passes, while the stone and bone stay exactly where they fell.",
			"They are still scattered evenly across the land, though, where real scrub would gather in thickets and leave bare patches between. That is the next thing to fix.",
		],
	},
	{
		"version": "0.4.0",
		"date": "2026-07-18",
		"title": "The ruins look broken",
		"notes": [
			"The standing stones out in the Reach were smooth pillars and tidy boxes — they read as something someone put there, not something that fell down. Now they are broken: columns shear off at an angle with a ragged snap, walls collapse away toward one end with courses missing, and rubble is irregular lumps instead of crates.",
			"Every ruin is still in exactly the same place it always was. Only their shapes changed, and the same world still grows the same ruins every time you load it.",
			"They are honestly still rough — a cluster of broken shapes rather than a building you could read the plan of. Arches, lintels and foundations come later.",
		],
	},
	{
		"version": "0.3.0",
		"date": "2026-07-18",
		"title": "The Reach holds the light",
		"notes": [
			"The air in the Reach carries ash now. Distance reads as distance — a ruin far off sits behind something, rather than merely being smaller — and the ash lies heavier down in the hollows than up on the ridges.",
			"Things sit ON the ground now. Every rock, bone pile and scrap of scrub darkens where it meets the earth, instead of looking pasted onto it.",
			"The braziers and the cave torches finally give off light rather than just being orange. Their glow carries into the air around them.",
			"Shadows soften as they stretch away from what casts them, instead of staying knife-edged all the way out.",
			"This is a pass on the light, not on the world itself. The ground, the ruins and the scrub are still made of plain shapes, and they still look it — that work is coming.",
		],
	},
	{
		"version": "0.2.0",
		"date": "2026-07-18",
		"title": "The ground is made of something",
		"notes": [
			"The Reach was a smooth surface you walked across. Now it is ground: ash drifted into banks and swept thin elsewhere, with a grain fine enough to see underfoot and coarse enough to catch the low sun.",
			"The land changes with its own shape. Ash settles where the ground lies flat and washes off the steeper faces, so slopes show the harder rock beneath instead of everything wearing the same colour.",
			"Nothing about the world itself moved — the same hills, the same ruins, the same scrub in the same places. Only what it is made of changed.",
			"The ruins, the scrub and the people are still plain shapes and still look it. The ground went first because you see more of it than anything else.",
		],
	},
	{
		"version": "0.1.18",
		"date": "2026-07-18",
		"title": "The dev log reads true",
		"notes": [
			"This log was listing two releases twice over, which read like a display fault and made it harder to trust as a record of what actually shipped. Every version now appears exactly once, newest first.",
			"A check keeps it that way. Every change you can see adds an entry to the top of this same list, so two changes landing near each other is precisely how a block gets copied twice — that now stops the build instead of reaching you.",
		],
	},
	{
		"version": "0.1.17",
		"date": "2026-07-18",
		"title": "The torches hang on the walls",
		"notes": [
			"The torches lighting the starter cave were hanging in mid-air — some of them stranded several metres from the nearest rock, out in the middle of the chamber. Each one now finds its own patch of wall and is bracketed to it.",
			"They also look like torches now: an iron bracket bolted to the rock, a shaft leaning up out of it, a pitch-soaked wrapped head, and a flame that tapers to a point and rises straight up however the shaft is angled. Before, each was a plain stick with a ball stuck on the end.",
			"The flame breathes with its own light as it flickers, and the way down is lit a little more evenly.",
		],
	},
	{
		"version": "0.1.16",
		"date": "2026-07-18",
		"title": "The ground is strewn",
		"notes": [
			"The Reach is no longer bare between its landmarks. Ashen scrub, dead grass, bone piles and broken rubble are now scattered across the Reach, so the ground between the ruins reads like somewhere a disaster happened rather than an empty plain.",
			"It is scenery and nothing more — there is nothing to pick up, it changes nothing about how you play, and you walk straight through it. The shrine's clearing, the ruins themselves and the cave mouth all stay clear, and the same world grows the same scrub every time you load it.",
		],
	},
	{
		"version": "0.1.15",
		"date": "2026-07-17",
		"title": "Your character is safe",
		"notes": [
			"An older build's own self-tests briefly borrowed your saved character while they ran; a crash at the wrong moment could leave it set aside instead of put back. The game now restores it for you automatically the next time you play.",
			"And if it ever cannot (a locked file, say), it will tell you and refuse to start a fresh character over the top — your original is never overwritten. Nothing you have made is thrown away.",
		],
	},
	{
		"version": "0.1.14",
		"date": "2026-07-17",
		"title": "The world answers",
		"notes": [
			"The Reach is no longer a diorama you only walk through: look at something close and a prompt appears — press E (or a gamepad button) to act on it.",
			"The Wardens' Shrine can be attuned: stand at its flame, attune it, and the Reach will return you there when you fall — instead of waking you back in the dark of the cave. (For now this lasts the session; it will remember across logouts once the save vault is sealed.)",
			"The people finally speak: walk up to anyone and they have a first word for you — the same word, from the same person, every boot. It is a first line only; real conversations, and the errands they will carry, come later.",
		],
	},
	{
		"version": "0.1.13",
		"date": "2026-07-17",
		"title": "Something else lives here",
		"notes": [
			"You are no longer the only kind of thing in the Reach: a pack of ash hounds — lean four-legged scavengers — now haunts the wild edges of the land, well beyond the settlement. Walk out far enough and you will find them watching.",
			"Every hound is grown from its name, like the people are: build, legs, snout, ears, tail, size and hide-colour all come from a seeded generator, so Ashfang is the same beast in the same place on every machine, every boot, forever.",
			"They cannot hunt yet — no teeth, no chase, one still pose. That comes with combat. Today they are the proof that the world can make creatures, not just people: the same machinery that shapes a wanderer now shapes a beast that was never human-shaped to begin with.",
		],
	},
	{
		"version": "0.1.12",
		"date": "2026-07-17",
		"title": "The Reach is inhabited",
		"notes": [
			"Walk out of the cave and you are no longer alone: a small settlement rings the shrine, and lone drifters dot the open land — two dozen people, every one of them different.",
			"Each person is grown from their name: body, face, age, phenotype, outfit and skin all come from a seeded generator, so Maren stands in the same place with the same face on every machine, every boot, forever.",
			"Everyone finally stands like a person, arms at their sides — the T-pose era ends for you and them alike (real animation comes later; today they hold still and watch the light).",
			"Walk close and a name fades in over each head. They cannot speak yet. They are waiting for the world to give them something to say.",
		],
	},
	{
		"version": "0.1.11",
		"date": "2026-07-17",
		"title": "Skin, at last",
		"notes": [
			"The clay era ends: bodies now wear real skin. Six painted skins — light, mid and deep tones, young and old, male and female — sit in a new SKIN section of the character screen, live on your body as you browse them.",
			"Faces finally have faces: brows, lips and years arrive with the texture, not just the sculpt.",
			"Every preset dressed for it: the wanderer wakes bronzed by the sun outside, the villager and elder wear lived-in faces, the brute's hide is old leather.",
			"Clay is still there — as a choice — and old saves are, as always, untouched until you visit the character screen (C).",
		],
	},
	{
		"version": "0.1.10",
		"date": "2026-07-17",
		"title": "Every body the world will need",
		"notes": [
			"The character screen learned gender and phenotype: new whole-body sliders — female, male, aged, heavy, slim — and three facial-structure axes, all live on the body as you drag them. The one androgynous base is now every body the world will need.",
			"Your clothes follow: every garment was rebaked to track the new axes, so a shirt fits an elder the same way it fits a brute.",
			"A fourth preset joined the character screen: the elder — a village matriarch the Ruin could not kill, and the first face of the new axes.",
			"As always, nothing you saved is touched: old characters load exactly as they were, and the new sliders simply sit at zero until you move them.",
		],
	},
	{
		"version": "0.1.9",
		"date": "2026-07-17",
		"title": "The ragged clothes the Ruin left you",
		"notes": [
			"The wanderer no longer wakes bare: a crude shirt, wool pants and cloth shoes — the ragged clothes the story always promised — now dress the body, fitted to it and following every slider as you reshape yourself.",
			"The character screen grew an OUTFIT section: each slot (torso, legs, feet) can wear any baked piece or stay bare. Villagers dress like villagers; the brute goes bare-chested in scavenged boots, as a brute should.",
			"Under the hood this is the equipment system arriving: clothes are baked from CC0 MakeHuman pieces onto the one canonical skeleton, so every garment fits every body — and every future humanoid. Weapon sockets now wait on both hands for the first weapon to exist.",
			"Old saved characters keep working untouched (they always will); dressing them is one visit to the character screen (C).",
		],
	},
	{
		"version": "0.1.8",
		"date": "2026-07-17",
		"title": "The cave becomes a cave",
		"notes": [
			"The starter cave was reborn (the owner's verdict on the old one: tinfoil in brown). It is now a SYSTEM: wake in a deep chamber, follow torchlight up a winding tunnel past a side passage that promises deeper dark, and step out through a stone doorway in a rock outcrop.",
			"The rock itself is new: smooth, flowing walls with warm sandstone strata (a procedural shader — still no textures, only arithmetic), floors silted with sediment, torches flickering along the spine.",
			"The mouth is dressed the way old caves are: an arch of rock, leaning jamb stones, fallen slabs — and the land dips into a hollow at the doorway so cave and overworld meet honestly, with no loading screen and no seams that lie.",
			"The generator behind it can grow more systems — deeper, branchier, elsewhere — from a seed. This one is only the first.",
		],
	},
	{
		"version": "0.1.7",
		"date": "2026-07-17",
		"title": "You wake in the starter cave",
		"notes": [
			"The cave is no longer a museum piece: it stands in the open world, a minute's walk from the shrine — and every wanderer now wakes inside it, by a handful of dying embers, with the mouth glowing ahead. Walk out; there is no loading screen, and there never will be.",
			"The first time you wake, the world asks who you are: a character creation screen shapes your body — build sliders, frame sliders, three starting presets — live on the body standing in the cave. Your shape is saved and kept.",
			"Press C any time to reshape yourself (an early-build courtesy while the character system grows: skin, hair and clothes are still to come, and the body still stands in the sculptor's pose).",
			"The capsule placeholder is gone; the wanderer wears a recipe-built body from the character system.",
		],
	},
	{
		"version": "0.1.6",
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
		"version": "0.1.5",
		"date": "2026-07-17",
		"title": "The first wanderer takes shape",
		"notes": [
			"A human figure now stands in the cave — the first character. The body is a CC0 base mesh; everything about how he stands is code: his proportions are reshaped bone by bone (broader chest, heavier forearms, larger hands) and his arms are lowered from the sculptor's T-pose into a relaxed stance, all by a script.",
			"A second taste-gate scene lines up three builds of the same body — grounded, hero, base — so the proportion range can be judged side by side.",
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
