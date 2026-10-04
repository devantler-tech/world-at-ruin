package updatepublisher

import (
	"errors"
	"time"
)

// Issuance budgets constrain this operator tool. Verification retains the
// client's historical signed-window contract rather than retroactively changing it.
func issuanceBudget(kind string, d map[string]any, at time.Time) error {
	switch kind {
	case "certificate":
		before, err := timestamp(d["not_before"])
		if err != nil {
			return err
		}
		after, err := timestamp(d["not_after"])
		if err != nil {
			return err
		}
		if after.Sub(before) > 31*24*time.Hour {
			return errors.New("new certificate window exceeds 31 days")
		}
	case "head", "manifest":
		after, err := timestamp(d["not_after"])
		if err != nil {
			return err
		}
		if after.Sub(at) > 24*time.Hour {
			return errors.New("new publication expiry exceeds 24 hours")
		}
	case "revocation":
	default:
		return errors.New("unsupported issuance kind")
	}
	return nil
}
