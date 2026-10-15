//go:build !war_native_trial

package nakamatrial

import (
	"context"
	"crypto/ed25519"
	"testing"
	"time"

	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// The real SDK validates certificates; these synthetic contexts exercise selection.
func roleReadinessContext(id string) *workloadapi.X509Context {
	return &workloadapi.X509Context{SVIDs: []*x509svid.SVID{{ID: spiffeid.RequireFromString(id), PrivateKey: ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize))}}}
}

// A listening role may first refuse while registration converges; never renew its window.
func TestIssuedRoleReadinessWaitsForExactRegisteredCredential(t *testing.T) {
	for _, expected := range []string{"spiffe://war-fixture.test/claims/private", "spiffe://war-fixture.test/zone/owned/source"} {
		t.Run(expected, func(t *testing.T) {
			material := roleReadinessContext(expected)
			ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
			defer cancel()
			attempts := 0
			got, err := awaitIssuedRole(ctx, expected, func(request context.Context) (*workloadapi.X509Context, error) {
				attempts++
				deadline, ok := request.Deadline()
				outer, _ := ctx.Deadline()
				if !ok || deadline.After(outer) {
					t.Fatal("credential request escaped original startup lifetime")
				}
				switch attempts {
				case 1:
					return nil, status.Error(codes.PermissionDenied, "not synchronized")
				case 2:
					return nil, status.Error(codes.Unavailable, "not synchronized")
				default:
					return material, nil
				}
			})
			if err != nil || got != material || attempts != 3 {
				t.Fatal("registered-role convergence did not require the exact credential")
			}
		})
	}
}

// Invalid material and permanent failures cannot be retried into an admission.
func TestIssuedRoleReadinessRefusesInvalidOrPermanentResults(t *testing.T) {
	const expected = "spiffe://war-fixture.test/claims/private"
	for _, name := range []string{"nil", "empty", "nil-svid", "wrong-role", "missing-key", "multiple", "permanent", "late"} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
			defer cancel()
			calls := 0
			got, err := awaitIssuedRole(ctx, expected, func(context.Context) (*workloadapi.X509Context, error) {
				calls++
				material := roleReadinessContext(expected)
				switch name {
				case "nil":
					return nil, nil
				case "empty":
					material.SVIDs = nil
				case "nil-svid":
					material.SVIDs[0] = nil
				case "wrong-role":
					material = roleReadinessContext(expected + "-wrong")
				case "missing-key":
					material.SVIDs[0].PrivateKey = nil
				case "multiple":
					material.SVIDs = append(material.SVIDs, material.SVIDs[0])
				case "permanent":
					return nil, status.Error(codes.InvalidArgument, "private-sentinel")
				case "late":
					cancel()
				}
				return material, nil
			})
			if err == nil || got != nil || calls != 1 {
				t.Fatal("invalid or late material became role readiness")
			}
		})
	}
}

// Persistent refusal remains bounded and cancellation never starts a new fetch.
func TestIssuedRoleReadinessBoundsPersistentRefusal(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 150*time.Millisecond)
	defer cancel()
	calls := 0
	fetch := func(context.Context) (*workloadapi.X509Context, error) {
		calls++
		return nil, status.Error(codes.PermissionDenied, "not registered")
	}
	got, err := awaitIssuedRole(ctx, "spiffe://war-fixture.test/claims/private", fetch)
	if err == nil || got != nil || calls < 1 || ctx.Err() == nil {
		t.Fatal("permanent refusal escaped the original context")
	}
	previous := calls
	_, _ = awaitIssuedRole(ctx, "spiffe://war-fixture.test/claims/private", fetch)
	if calls != previous {
		t.Fatal("canceled startup fetched another credential")
	}
}
