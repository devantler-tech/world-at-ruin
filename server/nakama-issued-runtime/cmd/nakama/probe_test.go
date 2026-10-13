package main

import (
	"context"
	"github.com/spiffe/go-spiffe/v2/proto/spiffe/workload"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestSDKProbeDisabledIgnoresAllInputs(t *testing.T) {
	for _, enable := range []string{"", "false"} {
		if err := sdkProbe(context.Background(), map[string]string{"WAR_ISSUED_SDK_PROBE_ENABLED": enable, "WAR_ISSUED_SDK_PROBE_SOCKET": "not a socket"}); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSDKProbeUnknownFlagRefuses(t *testing.T) {
	if err := sdkProbe(context.Background(), map[string]string{"WAR_ISSUED_SDK_PROBE_ENABLED": "yes"}); err == nil || err.Error() != "issued SDK probe enablement refused" {
		t.Fatalf("flag: %v", err)
	}
}

func TestSDKProbeActuallyRequestsUnavailableIssuer(t *testing.T) {
	missing := filepath.Join(sdkFixtureDirectory(t), "missing.sock")
	err := sdkProbe(context.Background(), map[string]string{"WAR_ISSUED_SDK_PROBE_ENABLED": "true", "WAR_ISSUED_SDK_PROBE_SOCKET": missing})
	if err == nil || err.Error() != "issued SDK WorkloadAPI unavailable" {
		t.Fatalf("expected actual SDK transport refusal: %v", err)
	}
	if strings.Contains(err.Error(), missing) {
		t.Fatal("private socket path reached diagnostics")
	}
}

type refusingIssuer struct {
	workload.UnimplementedSpiffeWorkloadAPIServer
	requests atomic.Uint32
}

func (s *refusingIssuer) FetchX509SVID(_ *workload.X509SVIDRequest, _ workload.SpiffeWorkloadAPI_FetchX509SVIDServer) error {
	s.requests.Add(1)
	return status.Error(codes.PermissionDenied, "private issuer diagnostic")
}

// A different actual RPC refusal is never relabelled as the intended missing
// issuer control, and neither its diagnostic nor endpoint escapes to callers.
func TestSDKProbePreservesUnknownRequestFailure(t *testing.T) {
	socket := filepath.Join(sdkFixtureDirectory(t), "issuer.sock")
	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	issuer := &refusingIssuer{}
	workload.RegisterSpiffeWorkloadAPIServer(server, issuer)
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	t.Cleanup(func() {
		server.Stop()
		if err := <-done; err != nil {
			t.Error(err)
		}
	})
	err = sdkProbe(context.Background(), map[string]string{"WAR_ISSUED_SDK_PROBE_ENABLED": "true", "WAR_ISSUED_SDK_PROBE_SOCKET": socket})
	if err == nil || err.Error() != "issued SDK WorkloadAPI request refused" || issuer.requests.Load() != 1 {
		t.Fatalf("actual refusal misclassified: %v; requests=%d", err, issuer.requests.Load())
	}
}

// Keep Unix paths short on every test host while retaining exact private cleanup.
func sdkFixtureDirectory(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "war-sdk-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(dir); err != nil {
			t.Error(err)
		}
	})
	return dir
}
