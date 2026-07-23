package nakamaauth

import (
	"context"
	"net"
	"strings"
	"sync"
	"testing"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama/v3/apigrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/emptypb"
)

const testSession = "signed-session-token"

type accountServer struct {
	apigrpc.UnimplementedNakamaServer

	mu         sync.Mutex
	calls      int
	auth       []string
	trace      []string
	account    *api.Account
	accountErr error
}

func (s *accountServer) GetAccount(ctx context.Context, _ *emptypb.Empty) (*api.Account, error) {
	md, _ := metadata.FromIncomingContext(ctx)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	s.auth = append([]string(nil), md.Get("authorization")...)
	s.trace = append([]string(nil), md.Get("x-trace-id")...)
	return s.account, s.accountErr
}

func (s *accountServer) observed() (int, []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls, append([]string(nil), s.auth...)
}

func (s *accountServer) observedTrace() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.trace...)
}

func verifierAgainst(t *testing.T, server *accountServer) *Verifier {
	t.Helper()

	listener := bufconn.Listen(1024 * 1024)
	grpcServer := grpc.NewServer()
	apigrpc.RegisterNakamaServer(grpcServer, server)
	go func() {
		_ = grpcServer.Serve(listener)
	}()
	t.Cleanup(grpcServer.Stop)
	t.Cleanup(func() {
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
		t.Fatalf("create Nakama test client: %v", err)
	}
	t.Cleanup(func() {
		_ = conn.Close()
	})

	return NewVerifier(apigrpc.NewNakamaClient(conn))
}

func TestVerifySessionForwardsBearerAndReturnsUserID(t *testing.T) {
	server := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	verifier := verifierAgainst(t, server)

	userID, err := verifier.VerifySession(context.Background(), testSession)
	if err != nil {
		t.Fatalf("VerifySession returned an error: %v", err)
	}
	if userID != "player-42" {
		t.Fatalf("VerifySession user ID = %q, want player-42", userID)
	}

	calls, auth := server.observed()
	if calls != 1 {
		t.Fatalf("GetAccount calls = %d, want 1", calls)
	}
	if len(auth) != 1 || auth[0] != "Bearer "+testSession {
		t.Fatalf("authorization metadata = %q, want one bearer credential", auth)
	}
}

func TestVerifySessionReplacesInheritedAuthorizationMetadata(t *testing.T) {
	server := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	verifier := verifierAgainst(t, server)
	ctx := metadata.NewOutgoingContext(
		context.Background(),
		metadata.Pairs(
			"authorization", "Bearer inherited-session",
			"x-trace-id", "trace-7",
		),
	)

	_, err := verifier.VerifySession(ctx, testSession)
	if err != nil {
		t.Fatalf("VerifySession returned an error: %v", err)
	}

	_, auth := server.observed()
	if len(auth) != 1 || auth[0] != "Bearer "+testSession {
		t.Fatalf("authorization metadata = %q, want only supplied bearer credential", auth)
	}
	trace := server.observedTrace()
	if len(trace) != 1 || trace[0] != "trace-7" {
		t.Fatalf("trace metadata = %q, want preserved trace-7", trace)
	}
}

func TestVerifySessionPreservesSanitizedGRPCCode(t *testing.T) {
	server := &accountServer{
		accountErr: status.Error(codes.Unavailable, "upstream unavailable for "+testSession),
	}
	verifier := verifierAgainst(t, server)

	_, err := verifier.VerifySession(context.Background(), testSession)
	if err == nil {
		t.Fatal("VerifySession returned nil error")
	}
	if code := status.Code(err); code != codes.Unavailable {
		t.Fatalf("VerifySession status code = %s, want %s", code, codes.Unavailable)
	}
	if strings.Contains(err.Error(), testSession) {
		t.Fatalf("VerifySession error leaked the session token: %q", err)
	}
}

func TestVerifySessionFailsClosed(t *testing.T) {
	tests := []struct {
		name       string
		session    string
		account    *api.Account
		accountErr error
		wantCalls  int
		wantError  string
	}{
		{
			name:      "empty session",
			wantCalls: 0,
			wantError: "session is empty",
		},
		{
			name:       "Nakama rejects session",
			session:    testSession,
			accountErr: status.Error(codes.Unauthenticated, "rejected "+testSession),
			wantCalls:  1,
			wantError:  "Unauthenticated",
		},
		{
			name:      "account has no user",
			session:   testSession,
			account:   &api.Account{},
			wantCalls: 1,
			wantError: "account response has no user ID",
		},
		{
			name:      "account user has no ID",
			session:   testSession,
			account:   &api.Account{User: &api.User{}},
			wantCalls: 1,
			wantError: "account response has no user ID",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := &accountServer{
				account:    test.account,
				accountErr: test.accountErr,
			}
			verifier := verifierAgainst(t, server)

			userID, err := verifier.VerifySession(context.Background(), test.session)
			if err == nil {
				t.Fatal("VerifySession returned nil error")
			}
			if userID != "" {
				t.Fatalf("VerifySession user ID = %q, want empty", userID)
			}
			if !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("VerifySession error = %q, want it to contain %q", err, test.wantError)
			}
			if strings.Contains(err.Error(), testSession) {
				t.Fatalf("VerifySession error leaked the session token: %q", err)
			}
			calls, _ := server.observed()
			if calls != test.wantCalls {
				t.Fatalf("GetAccount calls = %d, want %d", calls, test.wantCalls)
			}
		})
	}
}
