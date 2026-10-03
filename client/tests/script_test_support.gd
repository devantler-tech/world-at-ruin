class_name ScriptTestSupport
extends RefCounted
## Inspect the actual loaded capture script's method catalog without invoking
## its scene lifecycle or replacing it with a mock.


## Test method existence independently of its number of arguments.
static func catalog_has_method(script: Script, wanted: String) -> bool:
	return not _method(script, wanted).is_empty()


## Return the original catalog's argument count, or -1 for an absent method.
static func argument_count(script: Script, wanted: String) -> int:
	var method := _method(script, wanted)
	return -1 if method.is_empty() else (method.get("args", []) as Array).size()


## Preserve the catalog's first matching method and its unmodified metadata.
static func _method(script: Script, wanted: String) -> Dictionary:
	for method: Dictionary in script.get_script_method_list():
		if String(method.get("name", "")) == wanted:
			return method
	return {}
