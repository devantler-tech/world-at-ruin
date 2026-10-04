package nakamaruntime

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/orphanreaper"
	"github.com/heroiclabs/nakama-common/runtime"
)

type orphanLog struct {
	runtime.Logger
	messages []string
}

// Info retains successful observations for assertions on their public vocabulary.
func (l *orphanLog) Info(format string, args ...interface{}) {
	l.messages = append(l.messages, fmt.Sprintf(format, args...))
}

// Warn retains failure observations without treating them as worker termination.
func (l *orphanLog) Warn(format string, args ...interface{}) {
	l.messages = append(l.messages, fmt.Sprintf(format, args...))
}

// TestOrphanObservationHasOnlyCountsAndClosedOutcomeClasses covers every outcome
// class and verifies that arbitrary provider content never enters the log.
func TestOrphanObservationHasOnlyCountsAndClosedOutcomeClasses(t *testing.T) {
	log := &orphanLog{}
	observe := orphanObservation(log)
	for _, err := range []error{nil, orphanreaper.ErrScan, orphanreaper.ErrCleanup, context.Canceled, context.DeadlineExceeded, errors.New("private-endpoint player-identity token-secret")} {
		observe(orphanreaper.Report{Scanned: 7, Waiting: 1, Protected: 2, Deleted: 1, Changed: 1, Failed: 2}, err)
	}
	for i, status := range []string{"complete", "incomplete", "cleanup-pending", "canceled", "deadline", "incomplete"} {
		message := log.messages[i]
		if !strings.Contains(message, "outcome="+status) || !strings.Contains(message, "scanned=7") || !strings.Contains(message, "protected=2") || !strings.Contains(message, "failed=2") {
			t.Fatalf("missing bounded outcome: %s", message)
		}
		for _, secret := range []string{"private-endpoint", "player-identity", "token-secret"} {
			if strings.Contains(message, secret) {
				t.Fatal("raw provider content escaped into orphan observation")
			}
		}
	}
	if orphanObservation(nil) != nil {
		t.Fatal("absent logger constructed a callback")
	}
}
