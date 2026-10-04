extends SceneTree
## Exercises the real client over newly generated offline publisher bytes.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("publisher proof needs one public chain fixture")
		quit(1)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not (parsed is Dictionary):
		push_error("publisher proof did not read a public JSON object")
		quit(1)
		return
	var proof: Dictionary = parsed
	var installed: Dictionary = proof["installed"]
	var manifest: Dictionary = proof["manifest"]
	var head: Dictionary = proof["head"]
	var root: String = proof["root_public_key"]
	var valid := UpdateTrust.verify_and_decide(installed, manifest, root, head)
	if not valid.get("trusted", false) or valid["decision"].get("action") != UpdateDecision.UP_TO_DATE:
		push_error("new publisher chain did not reach the client decision core: %s" % str(valid))
		quit(1)
		return
	var altered := manifest.duplicate(true)
	altered["sequence"] = 43
	var altered_result := UpdateTrust.verify_and_decide(installed, altered, root, head)
	var missing_head := UpdateTrust.verify_and_decide(installed, manifest, root, null)
	if altered_result.get("trusted", false) or missing_head.get("trusted", false):
		push_error("publisher interoperability accepted altered or incomplete trust evidence")
		quit(1)
		return
	var revoked := UpdateTrust.verify_and_decide(installed, proof["revoked_manifest"], root, head)
	var stale := UpdateTrust.verify_and_decide(installed, manifest, root, proof["raised_head"])
	var expired := UpdateTrust.verify_and_decide(installed, manifest, root, proof["expired_head"])
	for control: Array in [[revoked, "is revoked"], [stale, "below the independently fetched"], [expired, "head expired"]]:
		var result: Dictionary = control[0]
		if result.get("trusted", false) or not str(result.get("error", "")).contains(control[1]):
			push_error("authentic negative control did not refuse for its intended reason: %s" % str(result))
			quit(1)
			return
	print("TEST PASS — publisher bytes reach the client; authentic revoked, below-floor and expired evidence refuses")
	quit(0)
