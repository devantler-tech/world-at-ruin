class_name Interactable
extends Node3D
## A thing in the world the wanderer can act on — the game's one interaction
## verb. A shrine to attune, a person to speak to; later, loot to take and
## quests to accept (Phase 6, #13). Everything that answers the player plugs
## into the same seam: it is an Interactable, it carries a prompt, and it
## emits `interacted` when the wanderer chooses it.
##
## Selection is a PURE function (`choose`) of positions, ranges and facing —
## no scene tree, no engine state — so it is deterministic and unit-testable.
## The scene-tree glue lives in InteractionController.

## Every Interactable joins this group so the controller can find them all
## without anyone holding an explicit registry.
const GROUP := "interactable"

## Shown on the HUD when this is the current target ("[E] <prompt>").
@export var prompt: String = "Interact"
## Planar (XZ) reach, in metres. Landmarks (the shrine) use a wide reach; a
## person you must nearly touch uses a small one.
@export var interact_range: float = 3.0
## Minimum planar facing dot to be eligible: 1 = must look dead-on, 0 = within
## 90°, -1 = any facing at all. A person needs to be faced; a shrine is
## lenient — you can attune it standing at its foot.
@export var facing_min: float = -1.0

## The wanderer chose this interactable. `by` is the interacting node (Player).
signal interacted(by: Node)


func _ready() -> void:
	add_to_group(GROUP)


func trigger(by: Node) -> void:
	interacted.emit(by)


## Index of the best interactable the wanderer at `from` looking along planar
## `forward` can act on, or -1 if none qualifies. "Best" = within its own
## range AND faced past its own threshold, then NEAREST wins; ties break to the
## lower index so the choice is deterministic. Distance and facing are measured
## on the XZ plane so a tall shrine still counts when you stand at its foot.
##
## Pure: the three arrays are parallel (positions[i], ranges[i], facing_mins[i]
## describe candidate i). No node access, so tests drive it directly.
static func choose(from: Vector3, forward: Vector3,
		positions: PackedVector3Array, ranges: PackedFloat32Array,
		facing_mins: PackedFloat32Array) -> int:
	var fwd := Vector2(forward.x, forward.z)
	fwd = fwd.normalized() if fwd.length() > 0.0001 else Vector2(0, -1)
	var best := -1
	var best_dist := INF
	for i in positions.size():
		var to := Vector2(positions[i].x - from.x, positions[i].z - from.z)
		var dist := to.length()
		if dist > ranges[i]:
			continue
		# On top of it: count as fully faced rather than dividing by ~0.
		var faced := 1.0 if dist < 0.001 else fwd.dot(to / dist)
		if faced < facing_mins[i]:
			continue
		if dist < best_dist:
			best_dist = dist
			best = i
	return best
