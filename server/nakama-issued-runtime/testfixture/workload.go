// Package testfixture owns synthetic WorkloadAPI transport for source and native
// issued-runtime tests. It is not imported by a plugin or a serving command.
package testfixture

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/spiffe/go-spiffe/v2/proto/spiffe/workload"
	"google.golang.org/grpc"
)

// Directory keeps Unix endpoint paths short on every test host.
func Directory(t *testing.T) string {
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

// WorkloadAPI starts one real Unix RPC server and owns its exact retirement.
// The supplied service is synthetic; no process attestation is performed.
func WorkloadAPI(t *testing.T, service workload.SpiffeWorkloadAPIServer) string {
	t.Helper()
	socket := filepath.Join(Directory(t), "api.sock")
	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	workload.RegisterSpiffeWorkloadAPIServer(server, service)
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	t.Cleanup(func() {
		server.Stop()
		_ = listener.Close()
		select {
		case err := <-done:
			if err != nil && !errors.Is(err, grpc.ErrServerStopped) {
				t.Error("fixture WorkloadAPI serve failed")
			}
		case <-time.After(time.Second):
			t.Error("fixture WorkloadAPI did not retire")
		}
	})
	return socket
}
