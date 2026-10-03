class_name TestEnvironment
extends RefCounted
## Test-only snapshots preserve absence separately from an empty value.


static func snapshot(names: Array) -> Dictionary:
	var state := {}
	for name: String in names:
		state[name] = {"present": OS.has_environment(name), "value": OS.get_environment(name)}
	return state


static func restore(state: Dictionary) -> void:
	for name: String in state:
		if state[name]["present"]:
			OS.set_environment(name, state[name]["value"])
		else:
			OS.unset_environment(name)
