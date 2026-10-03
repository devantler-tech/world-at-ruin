class_name DocumentIdentity
## Content identities distinguish absence from a failed hash. Metadata cannot
## detect same-size edits or writes that preserve timestamps.

static func for_path(path: String, absent: String, unreadable: String) -> String:
	if not FileAccess.file_exists(path):
		return absent
	var sha := FileAccess.get_sha256(path)
	return unreadable if sha.is_empty() else sha
