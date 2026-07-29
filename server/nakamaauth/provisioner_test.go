package nakamaauth

import (
	"context"
	"errors"
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

const (
	testIdentityProof = "google-oidc-fixture"
	testNakamaSession = "nakama-session"
)

type googleAuthentication struct {
	credential    string
	create        bool
	username      string
	authorization []string
	trace         []string
}

type provisioningServer struct {
	apigrpc.UnimplementedNakamaServer

	mu              sync.Mutex
	authentication  []googleAuthentication
	accountCalls    int
	rejectGoogle    bool
	emptySession    bool
	emptyUserID     bool
	issuedSession   string
	provisionedUser string
}

func (s *provisioningServer) AuthenticateGoogle(
	ctx context.Context,
	request *api.AuthenticateGoogleRequest,
) (*api.Session, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	account := request.GetAccount()
	authentication := googleAuthentication{
		credential:    account.GetToken(),
		create:        request.GetCreate().GetValue(),
		username:      request.GetUsername(),
		authorization: append([]string(nil), md.Get("authorization")...),
		trace:         append([]string(nil), md.Get("x-trace-id")...),
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.authentication = append(s.authentication, authentication)
	if s.rejectGoogle {
		return nil, status.Error(
			codes.Unauthenticated,
			"rejected Google credential "+account.GetToken(),
		)
	}
	if s.emptySession {
		return &api.Session{}, nil
	}
	return &api.Session{
		Created: len(s.authentication) == 1,
		Token:   s.issuedSession,
	}, nil
}

func (s *provisioningServer) GetAccount(
	ctx context.Context,
	_ *emptypb.Empty,
) (*api.Account, error) {
	md, _ := metadata.FromIncomingContext(ctx)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.accountCalls++
	authorization := md.Get("authorization")
	if len(authorization) != 1 || authorization[0] != "Bearer "+s.issuedSession {
		return nil, status.Error(codes.Unauthenticated, "unknown Nakama session")
	}
	if s.emptyUserID {
		return &api.Account{User: &api.User{}}, nil
	}
	return &api.Account{User: &api.User{Id: s.provisionedUser}}, nil
}

func (s *provisioningServer) observed() ([]googleAuthentication, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]googleAuthentication(nil), s.authentication...), s.accountCalls
}

func provisionerAgainst(
	t *testing.T,
	server *provisioningServer,
	config ProvisionerConfig,
) *Provisioner {
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
		"passthrough:///nakama-provisioning-test",
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

	return NewProvisioner(apigrpc.NewNakamaClient(conn), config)
}

func TestProvisionGoogleIsDefaultOff(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	provisioner := provisionerAgainst(t, server, ProvisionerConfig{})

	userID, err := provisioner.ProvisionGoogle(context.Background(), testIdentityProof)
	if !errors.Is(err, ErrGoogleProvisioningDisabled) {
		t.Fatalf("ProvisionGoogle error = %v, want ErrGoogleProvisioningDisabled", err)
	}
	if userID != "" {
		t.Fatalf("ProvisionGoogle user ID = %q, want empty", userID)
	}
	authentication, accountCalls := server.observed()
	if len(authentication) != 0 || accountCalls != 0 {
		t.Fatalf(
			"disabled provisioning made %d authentication and %d account calls",
			len(authentication),
			accountCalls,
		)
	}
}

func TestProvisionGoogleReturnsStableUserID(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	provisioner := provisionerAgainst(t, server, ProvisionerConfig{
		GoogleProvisioningEnabled: true,
	})

	for attempt := 1; attempt <= 2; attempt++ {
		userID, err := provisioner.ProvisionGoogle(context.Background(), testIdentityProof)
		if err != nil {
			t.Fatalf("ProvisionGoogle attempt %d returned an error: %v", attempt, err)
		}
		if userID != "player-42" {
			t.Fatalf(
				"ProvisionGoogle attempt %d user ID = %q, want player-42",
				attempt,
				userID,
			)
		}
	}

	authentication, accountCalls := server.observed()
	if len(authentication) != 2 {
		t.Fatalf("AuthenticateGoogle calls = %d, want 2", len(authentication))
	}
	if accountCalls != 2 {
		t.Fatalf("GetAccount calls = %d, want 2", accountCalls)
	}
	for index, request := range authentication {
		if request.credential != testIdentityProof {
			t.Fatalf(
				"AuthenticateGoogle call %d credential = %q, want supplied credential",
				index+1,
				request.credential,
			)
		}
		if !request.create {
			t.Fatalf("AuthenticateGoogle call %d did not permit account creation", index+1)
		}
		if request.username != "" {
			t.Fatalf(
				"AuthenticateGoogle call %d generated username %q, want Nakama default",
				index+1,
				request.username,
			)
		}
	}
}

func TestProvisionGoogleStripsInheritedAuthorization(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	provisioner := provisionerAgainst(t, server, ProvisionerConfig{
		GoogleProvisioningEnabled: true,
	})
	ctx := metadata.NewOutgoingContext(
		context.Background(),
		metadata.Pairs(
			"authorization", "Bearer unrelated-session",
			"x-trace-id", "trace-9",
		),
	)

	_, err := provisioner.ProvisionGoogle(ctx, testIdentityProof)
	if err != nil {
		t.Fatalf("ProvisionGoogle returned an error: %v", err)
	}

	authentication, _ := server.observed()
	if len(authentication) != 1 {
		t.Fatalf("AuthenticateGoogle calls = %d, want 1", len(authentication))
	}
	if len(authentication[0].authorization) != 0 {
		t.Fatalf(
			"AuthenticateGoogle authorization metadata = %q, want none",
			authentication[0].authorization,
		)
	}
	if len(authentication[0].trace) != 1 || authentication[0].trace[0] != "trace-9" {
		t.Fatalf(
			"AuthenticateGoogle trace metadata = %q, want preserved trace-9",
			authentication[0].trace,
		)
	}
}

func TestProvisionGoogleFailsClosed(t *testing.T) {
	tests := []struct {
		name          string
		credential    string
		config        ProvisionerConfig
		configure     func(*provisioningServer)
		wantCode      codes.Code
		wantError     string
		wantAuthCalls int
		wantAcctCalls int
	}{
		{
			name:       "empty credential",
			config:     ProvisionerConfig{GoogleProvisioningEnabled: true},
			wantCode:   codes.Unknown,
			wantError:  "credential is empty",
			credential: "",
		},
		{
			name:       "Nakama rejects credential",
			credential: testIdentityProof,
			config:     ProvisionerConfig{GoogleProvisioningEnabled: true},
			configure: func(server *provisioningServer) {
				server.rejectGoogle = true
			},
			wantCode:      codes.Unauthenticated,
			wantError:     "AuthenticateGoogle rejected credential",
			wantAuthCalls: 1,
		},
		{
			name:       "Nakama returns no session",
			credential: testIdentityProof,
			config:     ProvisionerConfig{GoogleProvisioningEnabled: true},
			configure: func(server *provisioningServer) {
				server.emptySession = true
			},
			wantCode:      codes.Unknown,
			wantError:     "response has no session",
			wantAuthCalls: 1,
		},
		{
			name:       "verified account has no user ID",
			credential: testIdentityProof,
			config:     ProvisionerConfig{GoogleProvisioningEnabled: true},
			configure: func(server *provisioningServer) {
				server.emptyUserID = true
			},
			wantCode:      codes.Unknown,
			wantError:     "account response has no user ID",
			wantAuthCalls: 1,
			wantAcctCalls: 1,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := &provisioningServer{
				issuedSession:   testNakamaSession,
				provisionedUser: "player-42",
			}
			if test.configure != nil {
				test.configure(server)
			}
			provisioner := provisionerAgainst(t, server, test.config)

			userID, err := provisioner.ProvisionGoogle(
				context.Background(),
				test.credential,
			)
			if err == nil {
				t.Fatal("ProvisionGoogle returned nil error")
			}
			if userID != "" {
				t.Fatalf("ProvisionGoogle user ID = %q, want empty", userID)
			}
			if !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf(
					"ProvisionGoogle error = %q, want it to contain %q",
					err,
					test.wantError,
				)
			}
			if strings.Contains(err.Error(), testIdentityProof) {
				t.Fatalf("ProvisionGoogle error leaked the Google credential: %q", err)
			}
			if code := status.Code(err); code != test.wantCode {
				t.Fatalf(
					"ProvisionGoogle status code = %s, want %s",
					code,
					test.wantCode,
				)
			}
			authentication, accountCalls := server.observed()
			if len(authentication) != test.wantAuthCalls {
				t.Fatalf(
					"AuthenticateGoogle calls = %d, want %d",
					len(authentication),
					test.wantAuthCalls,
				)
			}
			if accountCalls != test.wantAcctCalls {
				t.Fatalf(
					"GetAccount calls = %d, want %d",
					accountCalls,
					test.wantAcctCalls,
				)
			}
		})
	}
}
