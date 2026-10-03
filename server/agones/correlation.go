package agones

import (
	"errors"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
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
	return handoffidentity.SHA256Base32([]byte(value)), nil
}

func validCorrelationID(value string) bool {
	return handoffidentity.CorrelationID(value)
}
