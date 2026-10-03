// Package grpctest supplies an isolated, real in-memory gRPC transport for tests.
package grpctest

import (
	"context"
	"net"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
)

// Connect registers the caller's services on a private server and retains normal
// RPC metadata, cancellation and serialization. Cleanup closes the connection,
// listener and server in that order.
func Connect(tb testing.TB, target string, register func(*grpc.Server), options ...grpc.ServerOption) *grpc.ClientConn {
	tb.Helper()
	listener := bufconn.Listen(1024 * 1024)
	server := grpc.NewServer(options...)
	register(server)
	go func() { _ = server.Serve(listener) }()
	tb.Cleanup(server.Stop)
	tb.Cleanup(func() { _ = listener.Close() })
	conn, err := grpc.NewClient(
		target,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return listener.DialContext(ctx)
		}),
	)
	if err != nil {
		tb.Fatalf("create in-memory gRPC client: %v", err)
	}
	tb.Cleanup(func() { _ = conn.Close() })
	return conn
}
