extends Node
## Trust-chain test for issues #604, #660 and #693. It exercises the real
## production boundary from an offline root through a signing-key certificate, a
## root-signed revocation list and the independently fetched revocation head that
## dates it, then through the manifest signature into [UpdateDecision].
##
## The fixed signatures were generated with OpenSSL, independently of Godot.
## Run: godot --headless --path client res://tests/update_trust_chain_test.tscn

const VERIFIER_PATH := "res://scripts/update_trust.gd"
const VECTOR_PATH := "res://tests/data/update_trust_chain_vector.json"
const CHAIN_METHOD := "verify_and_decide"

var _failed := false
var _verifier: Script
var _vector: Dictionary
var _root_public_key := ""
var _wrong_root_public_key := ""


func _ready() -> void:
	_load_inputs()
	if _failed:
		return
	if not _has_script_method(CHAIN_METHOD):
		_fail("UpdateTrust.%s is missing — certificate epochs can reach UpdateDecision without offline-root authentication" % CHAIN_METHOD)
		return
	_test_valid_chain_reaches_update_decision()
	_test_revoked_key_is_refused_before_manifest_authentication()
	_test_revocation_is_required_and_root_authenticated()
	_test_malformed_root_signed_revocation_is_refused()
	_test_revocation_head_is_required_and_root_authenticated()
	_test_embedded_revocation_below_the_head_floor_is_refused()
	_test_expired_or_foreign_revocation_head_is_refused()
	_test_head_is_enforced_before_manifest_authentication()
	_test_wrong_root_and_self_signed_certificate_are_refused()
	_test_tampered_certificate_is_refused()
	_test_tampered_manifest_is_refused()
	_test_malformed_or_unsupported_signing_inputs_fail_closed()
	if _failed:
		return
	print("TEST PASS — only an unrevoked offline-root-authenticated signing key, presenting a revocation list a current independently fetched head vouches for, can authorize a manifest decision")
	get_tree().quit(0)


func _load_inputs() -> void:
	if not ResourceLoader.exists(VERIFIER_PATH):
		_fail("%s is missing — there is no production update-trust boundary" % VERIFIER_PATH)
		return
	_verifier = load(VERIFIER_PATH)
	if _verifier == null:
		_fail("%s could not be loaded as a script" % VERIFIER_PATH)
		return
	if not FileAccess.file_exists(VECTOR_PATH):
		_fail("%s is missing — the trust chain needs an independent fixed vector" % VECTOR_PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(VECTOR_PATH))
	if not (parsed is Dictionary):
		_fail("%s did not parse as a JSON object" % VECTOR_PATH)
		return
	_vector = parsed
	_root_public_key = _read_key(str(_vector["root_public_key_path"]))
	_wrong_root_public_key = _read_key(str(_vector["wrong_root_public_key_path"]))


## Catches bypassing either signature and calling UpdateDecision directly.
func _test_valid_chain_reaches_update_decision() -> void:
	var got := _verify(_manifest(), _root_public_key)
	if not bool(got.get("trusted", false)):
		_fail("the fixed root → signing key → manifest chain was refused: %s" % str(got.get("error", "")))
		return
	var decision: Variant = got.get("decision")
	if not (decision is Dictionary) or decision.get("action") != UpdateDecision.UP_TO_DATE:
		_fail("the authenticated chain did not reach the existing decision core: %s" % str(decision))


## Catches omitting revocation, checking it after manifest authentication, or
## treating a valid leaf signature as authority after the root revoked that leaf.
func _test_revoked_key_is_refused_before_manifest_authentication() -> void:
	var revoked := (_vector["revoked_manifest"] as Dictionary).duplicate(true)
	_expect_revoked(_verify(revoked, _root_public_key),
		"a valid manifest signed by a root-revoked key")

	# The revoked-key classification must win before the manifest signature is
	# parsed. Otherwise a compromised key still reaches its own authentication
	# boundary before the root's control signal is consumed.
	revoked["signature"] = "%%%"
	_expect_revoked(_verify(revoked, _root_public_key),
		"a revoked key paired with a malformed manifest signature")


## Catches accepting certificate-backed manifests that omit the list, trusting
## an unsigned list, or failing to bind the root signature to its exact JCS bytes.
func _test_revocation_is_required_and_root_authenticated() -> void:
	var absent := _manifest()
	absent.erase("revocation")
	_expect_refusal_stage(_verify(absent, _root_public_key), "revocation",
		"a manifest carrying no revocation list")

	var unsigned := _manifest()
	unsigned["revocation"].erase("root_signature")
	_expect_refusal_stage(_verify(unsigned, _root_public_key), "revocation",
		"a revocation list carrying no offline-root signature")

	var tampered := _manifest()
	tampered["revocation"]["version"] = 5
	_expect_refusal_stage(_verify(tampered, _root_public_key), "revocation",
		"a changed revocation version under the old root signature")


## Catches accepting an ambiguous set representation that could let publisher
## and client disagree about whether a key id is present.
func _test_malformed_root_signed_revocation_is_refused() -> void:
	var duplicate := _manifest()
	var key_id := str(duplicate["key"]["id"])
	duplicate["revocation"]["revoked_ids"] = [key_id, key_id]
	duplicate["revocation"]["root_signature"] = \
		str(_vector["duplicate_revocation_root_signature"])
	_expect_refusal_stage(_verify(duplicate, _root_public_key), "duplicate",
		"a root-signed revocation list carrying the same key id twice")

	var malformed := _manifest()
	malformed["revocation"]["revoked_ids"] = "signing-key-2030-01"
	_expect_refusal_stage(_verify(malformed, _root_public_key), "revocation",
		"a revocation list whose revoked_ids value is not an array")


## Catches accepting embedded-only revocation. Without an independently fetched
## head, a stolen key replays an older — but validly root-signed — list issued
## before the theft, and every other check on this boundary still passes.
func _test_revocation_head_is_required_and_root_authenticated() -> void:
	_expect_refusal_stage(_verify_with_head(_manifest(), _root_public_key, null),
		"independently fetched", "a manifest verified with no revocation head")

	var unsigned := _head()
	unsigned.erase("root_signature")
	_expect_refusal_stage(_verify_with_head(_manifest(), _root_public_key, unsigned),
		"independently fetched", "a revocation head carrying no offline-root signature")

	var tampered := _head()
	tampered["version_floor"] = 9
	_expect_refusal_stage(_verify_with_head(_manifest(), _root_public_key, tampered),
		"independently fetched", "a raised head floor under the old root signature")


## The floor check, ablated in BOTH directions: the identical manifest is
## accepted under a head whose floor it meets and refused under a head that has
## moved past it. Asserting only the refusal would still pass with the comparison
## inverted, and asserting only the acceptance would pass with it deleted.
func _test_embedded_revocation_below_the_head_floor_is_refused() -> void:
	var accepted := _verify_with_head(_manifest(), _root_public_key, _head())
	if not bool(accepted.get("trusted", false)):
		_fail("an embedded revocation list at the published head floor was refused: %s"
			% str(accepted.get("error", "")))
		return

	_expect_refusal_stage(
		_verify_with_head(_manifest(), _root_public_key,
			_head_variant("revocation_head_floor_above_embedded")),
		"independently fetched",
		"an embedded revocation list older than the published head floor")


## Catches a head that authenticates but is no longer evidence about this
## endpoint: expired, or published for another channel whose floor is
## legitimately lower.
func _test_expired_or_foreign_revocation_head_is_refused() -> void:
	_expect_refusal_stage(
		_verify_with_head(_manifest(), _root_public_key,
			_head_variant("revocation_head_expired")),
		"independently fetched", "a revocation head that has expired")

	_expect_refusal_stage(
		_verify_with_head(_manifest(), _root_public_key,
			_head_variant("revocation_head_other_url")),
		"independently fetched", "a revocation head published for another endpoint")


## Catches enforcing the floor only after the manifest verifies. A replayed list
## must be a trust refusal, not something the manifest signature gets to answer.
func _test_head_is_enforced_before_manifest_authentication() -> void:
	var replayed := _manifest()
	replayed["signature"] = "%%%"
	_expect_refusal_stage(
		_verify_with_head(replayed, _root_public_key,
			_head_variant("revocation_head_floor_above_embedded")),
		"independently fetched",
		"a stale embedded revocation paired with a malformed manifest signature")


## Catches verifying a certificate with the leaf key, a global key, or merely
## checking that its signature is well-formed.
func _test_wrong_root_and_self_signed_certificate_are_refused() -> void:
	_expect_refused(_verify(_manifest(), _wrong_root_public_key),
		"a certificate presented under a different valid offline root")

	var self_signed := _manifest()
	self_signed["key"]["root_signature"] = str(_vector["self_signed_certificate_signature"])
	_expect_refused(_verify(self_signed, _root_public_key),
		"a signing key that signs its own certificate")


## Catches trusting the certificate fields before authenticating the exact JCS
## bytes. The altered epoch would start a fresh sequence line if it reached the
## decision core.
func _test_tampered_certificate_is_refused() -> void:
	var changed_epoch := _manifest()
	changed_epoch["key"]["epoch"] = 8
	changed_epoch["key_epoch"] = 8
	_expect_refused(_verify(changed_epoch, _root_public_key),
		"a higher self-declared certificate epoch")

	var changed_id := _manifest()
	changed_id["key"]["id"] = "signing-key-attacker"
	_expect_refused(_verify(changed_id, _root_public_key),
		"a changed certificate identity")


## Catches authenticating the signing key but never using it to verify the
## manifest. Both mutations remain well-formed and would reach a normal decision.
func _test_tampered_manifest_is_refused() -> void:
	var changed_sequence := _manifest()
	changed_sequence["sequence"] = 43
	_expect_refused(_verify(changed_sequence, _root_public_key),
		"a changed manifest sequence")

	var changed_shell := _manifest()
	changed_shell["shell"]["current"] = "0.1.15"
	_expect_refused(_verify(changed_shell, _root_public_key),
		"a changed shell target")


## Catches permissive defaulting, algorithm confusion, and base64 decoders that
## turn malformed signature input into an accidental success.
func _test_malformed_or_unsupported_signing_inputs_fail_closed() -> void:
	var no_root_signature := _manifest()
	no_root_signature["key"].erase("root_signature")
	_expect_refused(_verify(no_root_signature, _root_public_key),
		"a certificate with no root signature")

	var no_manifest_signature := _manifest()
	no_manifest_signature.erase("signature")
	_expect_refused(_verify(no_manifest_signature, _root_public_key),
		"a manifest with no signature")

	var unsupported := _manifest()
	unsupported["key"]["algorithm"] = "ed25519"
	_expect_refused(_verify(unsupported, _root_public_key),
		"an unsupported certificate algorithm")

	var noncanonical := _manifest()
	noncanonical["signature"] = str(noncanonical["signature"]) + "="
	_expect_refused(_verify(noncanonical, _root_public_key),
		"a non-canonical base64 manifest signature")


func _verify(manifest: Dictionary, root_public_key: String) -> Dictionary:
	return _verify_with_head(manifest, root_public_key, _head())


func _verify_with_head(manifest: Dictionary, root_public_key: String,
		revocation_head: Variant) -> Dictionary:
	var got: Variant = _verifier.call(CHAIN_METHOD,
		(_vector["installed"] as Dictionary).duplicate(true),
		manifest,
		root_public_key,
		revocation_head)
	if not (got is Dictionary):
		_fail("UpdateTrust.%s returned a non-object result" % CHAIN_METHOD)
		return {"trusted": false, "error": "test call failed", "decision": {}}
	return got


func _manifest() -> Dictionary:
	return (_vector["manifest"] as Dictionary).duplicate(true)


func _head() -> Dictionary:
	return (_vector["revocation_head"] as Dictionary).duplicate(true)


func _head_variant(name: String) -> Dictionary:
	return (_vector[name] as Dictionary).duplicate(true)


func _expect_refused(got: Dictionary, case_name: String) -> void:
	if bool(got.get("trusted", false)):
		_fail("%s reached UpdateDecision as trusted" % case_name)
		return
	if str(got.get("error", "")).is_empty():
		_fail("%s was refused without an error" % case_name)
		return
	var decision: Variant = got.get("decision", {})
	if not (decision is Dictionary) or not decision.is_empty():
		_fail("%s produced a decision before the trust chain was authenticated: %s" % [
			case_name, str(decision)])


func _expect_revoked(got: Dictionary, case_name: String) -> void:
	_expect_refusal_stage(got, "revoked", case_name)


func _expect_refusal_stage(got: Dictionary, stage: String, case_name: String) -> void:
	_expect_refused(got, case_name)
	if _failed:
		return
	if not str(got.get("error", "")).contains(stage):
		_fail("%s was not classified at the %s stage: %s" % [
			case_name, stage, str(got.get("error", ""))])


func _has_script_method(method_name: String) -> bool:
	for method: Dictionary in _verifier.get_script_method_list():
		if str(method.get("name", "")) == method_name:
			return true
	return false


func _read_key(path: String) -> String:
	var value := FileAccess.get_file_as_string(path)
	if value.is_empty():
		_fail("could not read public-key fixture %s" % path)
	return value


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
