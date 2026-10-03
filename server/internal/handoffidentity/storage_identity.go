package handoffidentity

// SHA256Hex recognizes the canonical lowercase spelling of a SHA-256 digest.
// Historical readers with broader spelling rules keep their own policy.
func SHA256Hex(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, char := range value {
		if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
			return false
		}
	}
	return true
}

// UUID recognizes hyphenated UUID spelling in either case, including the nil
// UUID. It imposes no version or variant restriction; owner policy is separate.
func UUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, char := range value {
		switch index {
		case 8, 13, 18, 23:
			if char != '-' {
				return false
			}
		default:
			if (char < '0' || char > '9') && (char < 'a' || char > 'f') && (char < 'A' || char > 'F') {
				return false
			}
		}
	}
	return true
}
