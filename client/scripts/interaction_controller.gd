class_name InteractionController
extends Node
## Drives the one interaction verb. Each frame it finds the nearest interactable
## the wanderer is near and facing (Interactable.choose), shows its prompt on
## the HUD, and fires it when the `interact` action is pressed.
##
## Deliberately thin: all the selection maths is the pure Interactable.choose,
## and every effect (attuning a shrine, a person speaking) lives on the
## interactable's own `interacted` handler. This node only bridges the two.

var player: Player
var hud: Hud

var _target: Interactable


func _process(_delta: float) -> void:
	_target = scan()
	if _target != null:
		hud.show_prompt("[E · pad X] %s" % _target.prompt)
	else:
		hud.hide_prompt()


## The interactable the wanderer would act on right now, or null. Public so a
## test can position the player and verify selection without faking input.
## Suppressed whenever the wanderer is not in control (the character creator
## owns the screen) — no prompts while reshaping a body.
func scan() -> Interactable:
	if player == null or not player.control_enabled:
		return null
	var nodes := get_tree().get_nodes_in_group(Interactable.GROUP)
	if nodes.is_empty():
		return null
	var interactables: Array[Interactable] = []
	var positions := PackedVector3Array()
	var ranges := PackedFloat32Array()
	var facing_mins := PackedFloat32Array()
	for n in nodes:
		var it := n as Interactable
		if it == null or not it.is_inside_tree():
			continue
		interactables.append(it)
		positions.append(it.global_position)
		ranges.append(it.interact_range)
		facing_mins.append(it.facing_min)
	var idx := Interactable.choose(
		player.global_position, player.aim_forward(), positions, ranges, facing_mins)
	return interactables[idx] if idx >= 0 else null


func _unhandled_input(event: InputEvent) -> void:
	if _target == null or player == null or not player.control_enabled:
		return
	if event.is_action_pressed("interact"):
		_target.trigger(player)
		get_viewport().set_input_as_handled()
