package nakamastorage

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

func TestReadErrorRetainsDomainPrecedenceAndOpaqueErrors(t *testing.T) {
	missing, invalid := errors.New("missing record"), errors.New("invalid record")
	unknown := errors.New("opaque reader failure")
	for _, test := range []struct {
		name        string
		input, want error
	}{
		{"success", nil, nil},
		{"wrapped missing", fmt.Errorf("read: %w", ErrObjectMissing), missing},
		{"wrapped invalid", fmt.Errorf("read: %w", ErrObjectInvalid), invalid},
		{"missing before invalid", errors.Join(ErrObjectInvalid, ErrObjectMissing), missing},
		{"cancellation", context.Canceled, context.Canceled},
		{"deadline", context.DeadlineExceeded, context.DeadlineExceeded},
		{"opaque identity", unknown, unknown},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := ReadError(test.input, missing, invalid); !errors.Is(got, test.want) {
				t.Fatalf("ReadError() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestLoadBeforeReplaceObservesOnlyConditionalWrites(t *testing.T) {
	missing, invalid := errors.New("missing record"), errors.New("invalid record")
	for _, test := range []struct {
		name, version   string
		loadError, want error
		calls           int
	}{
		{"create skips even a refused read", "*", invalid, nil, 0},
		{"existing record", "observed", nil, nil, 1},
		{"absent left to mutation boundary", "observed", fmt.Errorf("read: %w", missing), nil, 1},
		{"invalid record", "observed", invalid, invalid, 1},
		{"cancellation", "observed", context.Canceled, context.Canceled, 1},
		{"deadline", "observed", context.DeadlineExceeded, context.DeadlineExceeded, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := 0
			load := func(gotContext context.Context, subject string) (struct{}, error) {
				calls++
				if gotContext != ctx || subject != "subject" {
					t.Fatalf("load context or subject changed: %v, %q", gotContext, subject)
				}
				return struct{}{}, test.loadError
			}
			got := LoadBeforeReplace(ctx, "subject", test.version, missing, load)
			if !errors.Is(got, test.want) || calls != test.calls {
				t.Fatalf("preflight = %v after %d reads, want %v after %d", got, calls, test.want, test.calls)
			}
		})
	}
}
