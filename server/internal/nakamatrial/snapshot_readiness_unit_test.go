//go:build !war_native_trial

package nakamatrial

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"
)

// A fake-clock hold exposes premature success before captured output arrives.
func TestIssuedSnapshotWaitsForCapturedOutput(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		firstRead := make(chan struct{})
		var once sync.Once
		var mu sync.Mutex
		var captured string
		read := func() string {
			mu.Lock()
			defer mu.Unlock()
			value := captured
			once.Do(func() { close(firstRead) })
			return value
		}
		result := make(chan error, 1)
		go func() { result <- awaitIssuedSnapshot(ctx, make(chan struct{}), read) }()
		<-firstRead
		// Advance several polling opportunities without spending wall time,
		// then join every runnable worker before checking the result channel.
		time.Sleep(100 * time.Millisecond)
		synctest.Wait()
		select {
		case err := <-result:
			t.Fatalf("readiness returned before snapshot capture: %v", err)
		default:
		}
		mu.Lock()
		captured = issuedSnapshotMarker
		mu.Unlock()
		if err := <-result; err != nil {
			t.Fatalf("healthy startup rejected output still being captured: %v", err)
		}
	})
}

// Child liveness and cancellation take precedence over any captured marker.
func TestIssuedSnapshotRefusesInvalidReadiness(t *testing.T) {
	for _, scenario := range []string{"exited", "cancelled", "duplicate", "missing"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			done := make(chan struct{})
			captured := issuedSnapshotMarker
			switch scenario {
			case "exited":
				close(done)
			case "cancelled":
				cancel()
			case "duplicate":
				captured += "\n" + issuedSnapshotMarker
			case "missing":
				captured = "private-output-must-not-be-reported"
			}
			err := awaitIssuedSnapshot(ctx, done, func() string {
				if scenario == "missing" {
					cancel()
				}
				return captured
			})
			if err == nil || strings.Contains(err.Error(), captured) {
				t.Fatal("invalid readiness accepted or private output reported")
			}
			if (scenario == "cancelled" || scenario == "missing") && !errors.Is(err, context.Canceled) {
				t.Fatalf("startup cancellation was not retained: %v", err)
			}
		})
	}
}

// Exactly one live observation satisfies fetch readiness without custody authority.
func TestIssuedSnapshotAcceptsOneLiveObservation(t *testing.T) {
	if err := awaitIssuedSnapshot(t.Context(), make(chan struct{}), func() string { return issuedSnapshotMarker }); err != nil {
		t.Fatal(err)
	}
}
