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
	# A P-256 ECDSA signature is a short-form DER SEQUENCE of two INTEGERs.
	# Mbed TLS validates both integers; this boundary pins the outer encoding so
	# arbitrary binary input is never handed to it as if it were the agreed wire
	# format.
	if signature.size() < 8 or signature.size() > 72 \
			or signature[0] != 0x30 or signature[1] != signature.size() - 2:
		return _refused("update signature is not a DER-encoded P-256 ECDSA signature")

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


static func _sha256(message: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	# SHA-256 is a built-in algorithm, and message is non-empty by the caller's
	# guard, so these operations cannot fail for a supported Godot runtime.
	context.start(HashingContext.HASH_SHA256)
	context.update(message)
	return context.finish()


static func _refused(error: String) -> Dictionary:
	return {"valid": false, "error": error}
