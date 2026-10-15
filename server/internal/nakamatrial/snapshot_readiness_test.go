package nakamatrial

import (
	"context"
	"errors"
	"strings"
	"time"
)

const issuedSnapshotMarker = "ISSUED CLAIMS SNAPSHOT FETCHED"

// awaitIssuedSnapshot joins captured output to the existing startup window.
// The observation grants no listener validation or original custody authority.
func awaitIssuedSnapshot(ctx context.Context, done <-chan struct{}, logString func() string) error {
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-done:
			return errors.New("native process exited before issued snapshot readiness")
		default:
		}
		count := strings.Count(logString(), issuedSnapshotMarker)
		if count > 1 {
			return errors.New("duplicate issued snapshot observation")
		}
		if count == 1 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-done:
				return errors.New("native process exited before issued snapshot readiness")
			default:
				return nil
			}
		}
		select {
		case <-ticker.C:
		case <-ctx.Done():
			return ctx.Err()
		case <-done:
			return errors.New("native process exited before issued snapshot readiness")
		}
	}
}
