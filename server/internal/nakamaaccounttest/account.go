// Package nakamaaccounttest owns the in-memory account transport used by server tests.
package nakamaaccounttest

import (
	"context"
	"sync"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/internal/grpctest"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama/v3/apigrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/emptypb"
)

type Server struct {
	apigrpc.UnimplementedNakamaServer

	mu          sync.Mutex
	calls       int
	auth        []string
	gatewayAuth []string
	trace       []string
	Account     *api.Account
	AccountErr  error
}

// GetAccount records detached request metadata and returns the account or error configured before
// the RPC starts.
func (s *Server) GetAccount(ctx context.Context, _ *emptypb.Empty) (*api.Account, error) {
	md, _ := metadata.FromIncomingContext(ctx)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	s.auth = append([]string(nil), md.Get("authorization")...)
	s.gatewayAuth = append([]string(nil), md.Get("grpcgateway-authorization")...)
	s.trace = append([]string(nil), md.Get("x-trace-id")...)
	return s.Account, s.AccountErr
}

// Observed returns the call count and a detached authorization snapshot under the metadata lock.
func (s *Server) Observed() (int, []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls, append([]string(nil), s.auth...)
}

// ObservedTrace returns a detached trace metadata snapshot under the metadata lock.
func (s *Server) ObservedTrace() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.trace...)
}

// ObservedGatewayAuthorization returns a detached gateway authorization snapshot under the metadata
// lock.
func (s *Server) ObservedGatewayAuthorization() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.gatewayAuth...)
}

// Client connects to the in-memory account RPC server and registers connection, listener and server
// cleanup.
func Client(tb testing.TB, server *Server) apigrpc.NakamaClient {
	tb.Helper()

	conn := grpctest.Connect(tb, "passthrough:///nakama-test", func(serverTransport *grpc.Server) {
		apigrpc.RegisterNakamaServer(serverTransport, server)
	})

	return apigrpc.NewNakamaClient(conn)
}

// ObservedAuthorization returns the detached authorization snapshot without exposing mutable
// fixture storage.
func (s *Server) ObservedAuthorization() []string { _, auth := s.Observed(); return auth }
