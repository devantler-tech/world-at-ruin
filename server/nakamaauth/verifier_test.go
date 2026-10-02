package nakamaauth

import (
	"context"
	"github.com/devantler-tech/world-at-ruin/server/internal/nakamaaccounttest"
	"strings"
	"testing"

	"github.com/heroiclabs/nakama-common/api"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const testSession = "signed-session-token"

type accountServer = nakamaaccounttest.Server

func verifierAgainst(t *testing.T, server *accountServer) *Verifier {
	t.Helper()
	return NewVerifier(nakamaaccounttest.Client(t, server))
}

func TestVerifySessionForwardsBearerAndReturnsUserID(t *testing.T) {
	server := &accountServer{
		Account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	verifier := verifierAgainst(t, server)

	userID, err := verifier.VerifySession(context.Background(), testSession)
	if err != nil {
		t.Fatalf("VerifySession returned an error: %v", err)
	}
	if userID != "player-42" {
		t.Fatalf("VerifySession user ID = %q, want player-42", userID)
	}

	calls, auth := server.Observed()
	if calls != 1 {
		t.Fatalf("GetAccount calls = %d, want 1", calls)
	}
	if len(auth) != 1 || auth[0] != "Bearer "+testSession {
		t.Fatalf("authorization metadata = %q, want one bearer credential", auth)
	}
}

func TestVerifySessionReplacesInheritedAuthorizationMetadata(t *testing.T) {
	server := &accountServer{
		Account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	verifier := verifierAgainst(t, server)
	ctx := metadata.NewOutgoingContext(
		context.Background(),
		metadata.Pairs(
			"authorization", "Bearer inherited-session",
			"grpcgateway-authorization", "Bearer inherited-gateway-session",
			"x-trace-id", "trace-7",
		),
	)

	_, err := verifier.VerifySession(ctx, testSession)
	if err != nil {
		t.Fatalf("VerifySession returned an error: %v", err)
	}

	_, auth := server.Observed()
	if len(auth) != 1 || auth[0] != "Bearer "+testSession {
		t.Fatalf("authorization metadata = %q, want only supplied bearer credential", auth)
	}
	if gatewayAuth := server.ObservedGatewayAuthorization(); len(gatewayAuth) != 0 {
		t.Fatalf(
			"gRPC-Gateway authorization metadata = %q, want stripped",
			gatewayAuth,
		)
	}
	trace := server.ObservedTrace()
	if len(trace) != 1 || trace[0] != "trace-7" {
		t.Fatalf("trace metadata = %q, want preserved trace-7", trace)
	}
}

func TestVerifySessionPreservesSanitizedGRPCCode(t *testing.T) {
	server := &accountServer{
		AccountErr: status.Error(codes.Unavailable, "upstream unavailable for "+testSession),
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
		Account    *api.Account
		AccountErr error
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
			AccountErr: status.Error(codes.Unauthenticated, "rejected "+testSession),
			wantCalls:  1,
			wantError:  "Unauthenticated",
		},
		{
			name:      "account has no user",
			session:   testSession,
			Account:   &api.Account{},
			wantCalls: 1,
			wantError: "account response has no user ID",
		},
		{
			name:      "account user has no ID",
			session:   testSession,
			Account:   &api.Account{User: &api.User{}},
			wantCalls: 1,
			wantError: "account response has no user ID",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := &accountServer{
				Account:    test.Account,
				AccountErr: test.AccountErr,
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
			calls, _ := server.Observed()
			if calls != test.wantCalls {
				t.Fatalf("GetAccount calls = %d, want %d", calls, test.wantCalls)
			}
		})
	}
}
