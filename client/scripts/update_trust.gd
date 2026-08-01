class_name UpdateTrust
extends RefCounted
## The client-side cryptographic boundary for update-trust signatures.
##
## Godot's built-in [Crypto] verifier is used directly. The accepted key shape is
## pinned to a DER SubjectPublicKeyInfo for P-256 and the signature is ASN.1 DER,
## so an algorithm label cannot be used to smuggle another curve or encoding into
## the same verifier. The caller supplies the exact RFC-8785 JCS bytes; this class
## hashes those bytes itself and never accepts a manifest-supplied digest.

const ALGORITHM := "ecdsa-p256-sha256"

# DER prefix for:
#   SEQUENCE
#     SEQUENCE
#       OBJECT IDENTIFIER id-ecPublicKey
#       OBJECT IDENTIFIER prime256v1
#     BIT STRING 00 04 <64-byte uncompressed point>
#
# Requiring the complete prefix and 91-byte SPKI prevents a valid key on another
# elliptic curve from reaching the P-256 verifier under the same algorithm label.
const _P256_SPKI_SIZE := 91
const _P256_SPKI_PREFIX_HEX := \
		"3059301306072a8648ce3d020106082a8648ce3d03010703420004"
const _PUBLIC_KEY_BEGIN := "-----BEGIN PUBLIC KEY-----"
const _PUBLIC_KEY_END := "-----END PUBLIC KEY-----"


## Authenticate a certificate-backed manifest and only then ask
## [UpdateDecision] what it means for this installation.
##
## The order is the trust contract:
##   1. the offline root verifies the signing-key certificate;
##   2. the offline root verifies the embedded revocation list and the
##      authenticated certificate id is refused when that list names it;
##   3. only an unrevoked authenticated signing key verifies the manifest;
##   4. only an authenticated manifest reaches the decision core.
##
## The independently fetched revocation head remains outside this pure boundary;
## adding it later does not change the embedded-list authentication order here.
##
## Returns `{trusted: bool, error: String, decision: Dictionary}`. A trust
## refusal always carries an empty decision so a caller cannot accidentally act
## on unauthenticated certificate fields.
static func verify_and_decide(installed: Dictionary, manifest: Dictionary,
		root_public_key_pem: Variant) -> Dictionary:
	if not (manifest.get("key") is Dictionary):
		return _untrusted("manifest carries no signing-key certificate")
	var certificate: Dictionary = manifest["key"]
	if not certificate.has("root_signature"):
		return _untrusted("signing-key certificate carries no offline-root signature")

	var certificate_payload := certificate.duplicate(true)
	certificate_payload.erase("root_signature")
	var certificate_jcs := JCS.canonicalize(certificate_payload)
	if str(certificate_jcs["error"]) != "":
		return _untrusted("signing-key certificate cannot be canonicalized: %s" %
			str(certificate_jcs["error"]))
	var certificate_verification := verify_signature(
		certificate.get("algorithm"),
		root_public_key_pem,
		str(certificate_jcs["text"]).to_utf8_buffer(),
		certificate.get("root_signature"),
	)
	if not bool(certificate_verification["valid"]):
		return _untrusted("signing-key certificate is not authenticated by the offline root: %s" %
			str(certificate_verification["error"]))

	var revocation_verification := _verify_revocation(
		manifest.get("revocation"), certificate.get("id"),
		certificate.get("algorithm"), root_public_key_pem)
	if not bool(revocation_verification["valid"]):
		return _untrusted(str(revocation_verification["error"]))

	if not manifest.has("signature"):
		return _untrusted("manifest carries no signing-key signature")
	var manifest_payload := manifest.duplicate(true)
	manifest_payload.erase("signature")
	var manifest_jcs := JCS.canonicalize(manifest_payload)
	if str(manifest_jcs["error"]) != "":
		return _untrusted("manifest cannot be canonicalized: %s" %
			str(manifest_jcs["error"]))
	var manifest_verification := verify_signature(
		certificate.get("algorithm"),
		certificate.get("public_key"),
		str(manifest_jcs["text"]).to_utf8_buffer(),
		manifest.get("signature"),
	)
	if not bool(manifest_verification["valid"]):
		return _untrusted("manifest is not authenticated by its root-certified signing key: %s" %
			str(manifest_verification["error"]))

	return {
		"trusted": true,
		"error": "",
		"decision": UpdateDecision.decide(installed, manifest),
	}


## Authenticate the embedded root-signed revocation set and refuse the current
## certificate id before its key can authenticate the surrounding manifest.
static func _verify_revocation(raw: Variant, certificate_id: Variant,
		algorithm: Variant, root_public_key_pem: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return _refused("manifest carries no root-signed revocation object")
	var revocation: Dictionary = raw
	if not UpdateDecision.is_int_id(revocation.get("version")):
		return _refused("revocation version is missing or not a whole number")
	if not (revocation.get("head_url") is String) \
			or (revocation["head_url"] as String).is_empty():
		return _refused("revocation head_url is missing or not a non-empty string")
	if not (revocation.get("revoked_ids") is Array):
		return _refused("revocation revoked_ids is missing or not an array")
	if not revocation.has("root_signature"):
		return _refused("revocation object carries no offline-root signature")

	var seen_ids := {}
	for raw_id: Variant in revocation["revoked_ids"]:
		if not (raw_id is String) or (raw_id as String).is_empty():
			return _refused("revocation contains an empty or non-string key id")
		var key_id := str(raw_id)
		if seen_ids.has(key_id):
			return _refused("revocation contains duplicate key id '%s'" % key_id)
		seen_ids[key_id] = true

	var revocation_payload := revocation.duplicate(true)
	revocation_payload.erase("root_signature")
	var revocation_jcs := JCS.canonicalize(revocation_payload)
	if str(revocation_jcs["error"]) != "":
		return _refused("revocation object cannot be canonicalized: %s" %
			str(revocation_jcs["error"]))
	var root_verification := verify_signature(
		algorithm,
		root_public_key_pem,
		str(revocation_jcs["text"]).to_utf8_buffer(),
		revocation.get("root_signature"),
	)
	if not bool(root_verification["valid"]):
		return _refused("revocation object is not authenticated by the offline root: %s" %
			str(root_verification["error"]))
	if seen_ids.has(str(certificate_id)):
		return _refused("certified signing key '%s' is revoked by the offline root" %
			str(certificate_id))
	return {"valid": true, "error": ""}


## Verify an ECDSA P-256/SHA-256 signature over the exact message bytes.
##
## Returns `{valid: bool, error: String}`. Every malformed or unsupported input
## is a clean refusal; `valid` is true only when Godot's real cryptographic
## verifier accepts the signature.
static func verify_signature(algorithm: Variant, public_key_pem: Variant,
		message: PackedByteArray, signature_base64: Variant) -> Dictionary:
	if algorithm != ALGORITHM:
		return _refused("unsupported update-signature algorithm")
	if not (public_key_pem is String):
		return _refused("update-signature public key is not a string")
	if message.is_empty():
		return _refused("update-signature message is empty")
	if not (signature_base64 is String):
		return _refused("update signature is not a base64 string")

	var key_shape := _p256_public_key_shape(str(public_key_pem))
	if str(key_shape["error"]) != "":
		return _refused(str(key_shape["error"]))

	var decoded_signature := _strict_base64(str(signature_base64))
	if str(decoded_signature["error"]) != "":
		return _refused("update signature %s" % str(decoded_signature["error"]))
	var signature: PackedByteArray = decoded_signature["bytes"]
	if not _is_canonical_p256_ecdsa_der(signature):
		return _refused(
			"update signature is not a canonical DER-encoded P-256 ECDSA signature")

	var public_key := CryptoKey.new()
	var load_error := public_key.load_from_string(str(public_key_pem), true)
	if load_error != OK:
		# The DER envelope and algorithm identifiers were validated before calling
		# the engine; it still owns point validation and runtime capability checks.
		return _refused("Godot could not load the validated P-256 public key")

	var verified := Crypto.new().verify(
		HashingContext.HASH_SHA256,
		_sha256(message),
		signature,
		public_key,
	)
	if not verified:
		return _refused("update signature did not verify")
	return {"valid": true, "error": ""}


## Validate and pin the PEM/DER public-key representation before handing it to
## Godot's parser.
static func _p256_public_key_shape(public_key_pem: String) -> Dictionary:
	var normalized := public_key_pem.replace("\r\n", "\n").strip_edges()
	var lines := normalized.split("\n", false)
	if lines.size() < 3 or lines[0] != _PUBLIC_KEY_BEGIN \
			or lines[lines.size() - 1] != _PUBLIC_KEY_END:
		return {"error": "update-signature public key is not a PEM PUBLIC KEY"}

	var body := ""
	for i in range(1, lines.size() - 1):
		body += lines[i].strip_edges()
	var decoded := _strict_base64(body)
	if str(decoded["error"]) != "":
		return {"error": "update-signature public key PEM body %s" % str(decoded["error"])}
	var der: PackedByteArray = decoded["bytes"]
	if der.size() != _P256_SPKI_SIZE \
			or not der.hex_encode().begins_with(_P256_SPKI_PREFIX_HEX):
		return {"error": "update-signature public key is not a P-256 SubjectPublicKeyInfo"}
	return {"error": ""}


## Decode only canonical RFC 4648 base64. [Marshalls.base64_to_raw] is permissive
## and emits engine errors for malformed input, so syntax is checked first and
## the round-trip is required.
static func _strict_base64(value: String) -> Dictionary:
	if value.is_empty() or value.length() % 4 != 0:
		return {"bytes": PackedByteArray(), "error": "is not canonical base64"}
	var padding := 0
	var saw_padding := false
	for i in value.length():
		var code := value.unicode_at(i)
		var is_alpha_numeric := \
				(code >= 0x41 and code <= 0x5a) \
				or (code >= 0x61 and code <= 0x7a) \
				or (code >= 0x30 and code <= 0x39)
		if code == 0x3d: # =
			saw_padding = true
			padding += 1
			if padding > 2:
				return {"bytes": PackedByteArray(), "error": "is not canonical base64"}
		elif not is_alpha_numeric and code != 0x2b and code != 0x2f: # + /
			return {"bytes": PackedByteArray(), "error": "is not canonical base64"}
		elif saw_padding:
			return {"bytes": PackedByteArray(), "error": "is not canonical base64"}

	var decoded := Marshalls.base64_to_raw(value)
	if decoded.is_empty() or Marshalls.raw_to_base64(decoded) != value:
		return {"bytes": PackedByteArray(), "error": "is not canonical base64"}
	return {"bytes": decoded, "error": ""}


## Require DER's unique minimal representation rather than accepting any
## BER-compatible SEQUENCE that the engine can reduce to the same r/s values.
## P-256 coordinates need at most 32 bytes plus one necessary sign-protection
## zero, so every length is short-form and the whole signature is at most 72
## bytes.
static func _is_canonical_p256_ecdsa_der(signature: PackedByteArray) -> bool:
	if signature.size() < 8 or signature.size() > 72 \
			or signature[0] != 0x30 or signature[1] != signature.size() - 2:
		return false

	var after_r := _canonical_positive_der_integer_end(signature, 2)
	if after_r < 0:
		return false
	var after_s := _canonical_positive_der_integer_end(signature, after_r)
	return after_s == signature.size()


## Return the first byte after one canonical positive short-form DER INTEGER,
## or -1 when its tag, length, sign or leading-zero representation is invalid.
static func _canonical_positive_der_integer_end(value: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + 2 > value.size() or value[offset] != 0x02:
		return -1

	var integer_size := int(value[offset + 1])
	if integer_size < 1 or integer_size > 33:
		return -1
	var content_start := offset + 2
	var content_end := content_start + integer_size
	if content_end > value.size():
		return -1

	var first := int(value[content_start])
	if first == 0:
		# Zero is not a valid ECDSA coordinate. Otherwise a leading zero is
		# canonical only when it prevents the next byte from looking negative.
		if integer_size == 1 or (int(value[content_start + 1]) & 0x80) == 0:
			return -1
	elif (first & 0x80) != 0:
		return -1
	return content_end


static func _sha256(message: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	# SHA-256 is a built-in algorithm, and message is non-empty by the caller's
	# guard, so these operations cannot fail for a supported Godot runtime.
	context.start(HashingContext.HASH_SHA256)
	context.update(message)
	return context.finish()


static func _refused(error: String) -> Dictionary:
	return {"valid": false, "error": error}


static func _untrusted(error: String) -> Dictionary:
	return {"trusted": false, "error": error, "decision": {}}
