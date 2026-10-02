// Package nakamaaccounttest owns the in-memory account transport used by server tests.
package nakamaaccounttest

import (
	"context"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama/v3/apigrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/emptypb"
	"net"
	"sync"
	"testing"
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

func (s *Server) Observed() (int, []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls, append([]string(nil), s.auth...)
}

func (s *Server) ObservedTrace() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.trace...)
}

func (s *Server) ObservedGatewayAuthorization() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.gatewayAuth...)
}

func Client(tb testing.TB, server *Server) apigrpc.NakamaClient {
	tb.Helper()

	listener := bufconn.Listen(1024 * 1024)
	grpcServer := grpc.NewServer()
	apigrpc.RegisterNakamaServer(grpcServer, server)
	go func() {
		_ = grpcServer.Serve(listener)
	}()
	tb.Cleanup(grpcServer.Stop)
	tb.Cleanup(func() {
		_ = listener.Close()
	})

	conn, err := grpc.NewClient(
		"passthrough:///nakama-test",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return listener.DialContext(ctx)
		}),
	)
	if err != nil {
		tb.Fatalf("create Nakama test client: %v", err)
	}
	tb.Cleanup(func() {
		_ = conn.Close()
	})

	return apigrpc.NewNakamaClient(conn)
}

func (s *Server) ObservedAuthorization() []string { _, auth := s.Observed(); return auth }
