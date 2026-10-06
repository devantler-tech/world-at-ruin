//go:build !war_native_trial

package nakamatrial

import (
	"errors"
	"testing"
)

func TestNativeRetirementCompletionObservations(t *testing.T) {
	observationFailure := errors.New("fixture observation failed")
	for _, tc := range []struct {
		name     string
		gone     bool
		count    int
		err      error
		complete bool
		queried  bool
	}{
		{name: "resource remains", count: 0},
		{name: "resource gone but storage remains", gone: true, count: 1, queried: true},
		{name: "both retirements observed", gone: true, complete: true, queried: true},
		{name: "incomplete durable observation", gone: true, err: observationFailure, queried: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			queried := false
			complete, err := nativeRetirementComplete(tc.gone, func() (int, error) {
				queried = true
				return tc.count, tc.err
			})
			if complete != tc.complete || !errors.Is(err, tc.err) || queried != tc.queried {
				t.Fatalf("completion=%t error=%v queried=%t; want completion=%t error=%v queried=%t", complete, err, queried, tc.complete, tc.err, tc.queried)
			}
		})
	}
}
