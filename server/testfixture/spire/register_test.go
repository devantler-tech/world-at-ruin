//go:build linux

package spire

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestRegisterExactAllocation(t *testing.T) {
	private := t.TempDir()
	if err := os.WriteFile(filepath.Join(private, "join-token"), []byte("private-fixture-bootstrap-token"), 0600); err != nil {
		t.Fatal(err)
	}
	var calls [][]string
	Register(t, context.Background(), Issuer{Private: private}, []Entry{{ID: "spiffe://war-fixture.test/zone/world/actual-uid", UID: 10004}}, Runner{
		Admin: func(ctx context.Context, args ...string) ([]byte, error) {
			if _, bounded := ctx.Deadline(); !bounded {
				t.Fatal("unbounded issuer registration")
			}
			calls = append(calls, slices.Clone(args))
			return nil, nil
		},
	})
	want := []string{"entry", "create", "-socketPath", filepath.Join(private, "server", "api.sock"), "-parentID", "spiffe://war-fixture.test/spire/agent/join_token/private-fixture-bootstrap-token", "-spiffeID", "spiffe://war-fixture.test/zone/world/actual-uid", "-selector", "unix:uid:10004", "-x509SVIDTTL", "300"}
	if len(calls) != 1 || !slices.Equal(calls[0], want) {
		t.Fatal("registration did not retain exact allocation/UID binding")
	}
}
