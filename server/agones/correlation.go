package agones

import (
	"crypto/sha256"
	"encoding/base32"
	"errors"
	"strings"
)

const (
	// FleetLabel is Agones's controller-owned Fleet membership label.
	FleetLabel = "agones.dev/fleet"
	// AttemptLabel binds one allocated GameServer to one durable handoff
	// attempt without exposing the raw correlation value.
	AttemptLabel = "world-at-ruin.dev/handoff-attempt"
)

// CorrelationLabel returns the full canonical SHA-256-derived Kubernetes label
// value used to correlate allocation and resource reconciliation.
func CorrelationLabel(value string) (string, error) {
	if !validCorrelationID(value) {
		return "", errors.New("agones: correlation identity is invalid")
	}
	digest := sha256.Sum256([]byte(value))
	return strings.ToLower(
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:]),
	), nil
}

func validCorrelationID(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') &&
			(char < 'A' || char > 'Z') &&
			(char < '0' || char > '9') &&
			char != '-' &&
			char != '_' {
			return false
		}
	}
	return true
}
