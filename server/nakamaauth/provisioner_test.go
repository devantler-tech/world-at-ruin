package nakamaauth

import (
	"context"
	"encoding/base64"
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
	testIdentityProof     = "eyJhbGciOiJSUzI1NiJ9.e30.c2lnbmF0dXJl"
	testGoogleClientID    = "world-at-ruin.apps.googleusercontent.com"
	testGoogleSubject     = "google-player-subject"
	testNakamaCustomIDKey = "nakama-custom-id-key-with-at-least-32-bytes"
	testNakamaServerKey   = "nakama-server-key"
	testNakamaSession     = "nakama-session"
)

type customAuthentication struct {
	customID             string
	create               bool
	username             string
	authorization        []string
	gatewayAuthorization []string
	trace                []string
}

type fakeGoogleIdentityVerifier struct {
	mu          sync.Mutex
	credentials []string
	audiences   []string
	subject     string
	err         error
}

func (v *fakeGoogleIdentityVerifier) VerifyGoogleIDToken(
	_ context.Context,
	credential string,
	audience string,
) (string, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.credentials = append(v.credentials, credential)
	v.audiences = append(v.audiences, audience)
	return v.subject, v.err
}

func (v *fakeGoogleIdentityVerifier) observed() ([]string, []string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	return append([]string(nil), v.credentials...), append([]string(nil), v.audiences...)
}

type provisioningServer struct {
	apigrpc.UnimplementedNakamaServer

	mu                          sync.Mutex
	authentication              []customAuthentication
	accountCalls                int
	accountGatewayAuthorization []string
	rejectCustom                bool
	failCustomInternal          bool
	ambiguousCreate             bool
	emptySession                bool
	emptyUserID                 bool
	issuedSession               string
	provisionedUser             string
}

func (s *provisioningServer) AuthenticateCustom(
	ctx context.Context,
	request *api.AuthenticateCustomRequest,
) (*api.Session, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	account := request.GetAccount()
	authentication := customAuthentication{
		customID:      account.GetId(),
		create:        request.GetCreate().GetValue(),
		username:      request.GetUsername(),
		authorization: append([]string(nil), md.Get("authorization")...),
		gatewayAuthorization: append(
			[]string(nil),
			md.Get("grpcgateway-authorization")...,
		),
		trace: append([]string(nil), md.Get("x-trace-id")...),
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.authentication = append(s.authentication, authentication)
	if s.failCustomInternal {
		return nil, status.Error(codes.Internal, "custom identity storage unavailable")
	}
	if s.ambiguousCreate && len(s.authentication) == 1 && authentication.create {
		return nil, status.Error(codes.Internal, "custom identity insert raced")
	}
	if s.rejectCustom {
		return nil, status.Error(
			codes.Unauthenticated,
			"rejected custom identity "+account.GetId()+" with server key "+testNakamaServerKey,
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
	s.accountGatewayAuthorization = append(
		[]string(nil),
		md.Get("grpcgateway-authorization")...,
	)
	authorization := md.Get("authorization")
	if len(authorization) != 1 || authorization[0] != "Bearer "+s.issuedSession {
		return nil, status.Error(codes.Unauthenticated, "unknown Nakama session")
	}
	if s.emptyUserID {
		return &api.Account{User: &api.User{}}, nil
	}
	return &api.Account{User: &api.User{Id: s.provisionedUser}}, nil
}

func (s *provisioningServer) observed() ([]customAuthentication, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]customAuthentication(nil), s.authentication...), s.accountCalls
}

func (s *provisioningServer) observedAccountGatewayAuthorization() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.accountGatewayAuthorization...)
}

func provisionerAgainst(
	t *testing.T,
	server *provisioningServer,
	identityVerifier googleIdentityVerifier,
	config ProvisionerConfig,
) *Provisioner {
	t.Helper()

	listener := bufconn.Listen(1024 * 1024)
	grpcServer := grpc.NewServer(grpc.UnaryInterceptor(
		func(
			ctx context.Context,
			request any,
			info *grpc.UnaryServerInfo,
			handler grpc.UnaryHandler,
		) (any, error) {
			if info.FullMethod == apigrpc.Nakama_AuthenticateCustom_FullMethodName {
				md, _ := metadata.FromIncomingContext(ctx)
				if gatewayAuthorization := md.Get("grpcgateway-authorization"); len(
					gatewayAuthorization,
				) != 0 {
					return nil, status.Error(
						codes.Unauthenticated,
						"inherited gRPC-Gateway authorization",
					)
				}
				authorization := md.Get("authorization")
				wantAuthorization := "Basic " + base64.StdEncoding.EncodeToString(
					[]byte(testNakamaServerKey+":"),
				)
				if len(authorization) != 1 || authorization[0] != wantAuthorization {
					return nil, status.Error(
						codes.Unauthenticated,
						"invalid Nakama server-key authorization",
					)
				}
			}
			return handler(ctx, request)
		},
	))
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

	return newProvisioner(apigrpc.NewNakamaClient(conn), identityVerifier, config)
}

func enabledProvisionerConfig() ProvisionerConfig {
	return ProvisionerConfig{
		GoogleProvisioningEnabled: true,
		GoogleClientID:            testGoogleClientID,
		NakamaCustomIDKey:         []byte(testNakamaCustomIDKey),
		NakamaServerKey:           testNakamaServerKey,
	}
}

func acceptingGoogleVerifier() *fakeGoogleIdentityVerifier {
	return &fakeGoogleIdentityVerifier{subject: testGoogleSubject}
}

func TestProvisionGoogleIsDefaultOff(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	identityVerifier := acceptingGoogleVerifier()
	provisioner := provisionerAgainst(t, server, identityVerifier, ProvisionerConfig{})

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
	credentials, audiences := identityVerifier.observed()
	if len(credentials) != 0 || len(audiences) != 0 {
		t.Fatalf(
			"disabled provisioning made %d identity-verification calls",
			len(credentials),
		)
	}
}

func TestProvisionGoogleReturnsStableUserID(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	identityVerifier := acceptingGoogleVerifier()
	provisioner := provisionerAgainst(t, server, identityVerifier, enabledProvisionerConfig())

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
	credentials, audiences := identityVerifier.observed()
	if len(credentials) != 2 || len(audiences) != 2 {
		t.Fatalf(
			"Google identity-verification calls = %d, want 2",
			len(credentials),
		)
	}
	for index, request := range authentication {
		if request.customID != googleCustomID(
			[]byte(testNakamaCustomIDKey),
			testGoogleSubject,
		) {
			t.Fatalf(
				"AuthenticateCustom call %d custom ID = %q, want derived identity",
				index+1,
				request.customID,
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
		if credentials[index] != testIdentityProof {
			t.Fatalf(
				"identity-verification call %d credential = %q, want supplied credential",
				index+1,
				credentials[index],
			)
		}
		if audiences[index] != testGoogleClientID {
			t.Fatalf(
				"identity-verification call %d audience = %q, want Google client ID",
				index+1,
				audiences[index],
			)
		}
	}
}

func TestProvisionGoogleReconcilesConcurrentFirstUse(t *testing.T) {
	server := &provisioningServer{
		ambiguousCreate: true,
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	provisioner := provisionerAgainst(
		t,
		server,
		acceptingGoogleVerifier(),
		enabledProvisionerConfig(),
	)

	userID, err := provisioner.ProvisionGoogle(context.Background(), testIdentityProof)
	if err != nil {
		t.Fatalf("ProvisionGoogle returned an error: %v", err)
	}
	if userID != "player-42" {
		t.Fatalf("ProvisionGoogle user ID = %q, want player-42", userID)
	}

	authentication, accountCalls := server.observed()
	if len(authentication) != 2 {
		t.Fatalf("AuthenticateCustom calls = %d, want 2", len(authentication))
	}
	if !authentication[0].create {
		t.Fatal("first AuthenticateCustom call did not permit account creation")
	}
	if authentication[1].create {
		t.Fatal("reconciliation AuthenticateCustom call permitted account creation")
	}
	if authentication[0].customID != authentication[1].customID {
		t.Fatalf(
			"reconciliation custom ID = %q, want first custom ID %q",
			authentication[1].customID,
			authentication[0].customID,
		)
	}
	if accountCalls != 1 {
		t.Fatalf("GetAccount calls = %d, want 1", accountCalls)
	}
}

func TestGoogleCustomIDIsKeyedAndStable(t *testing.T) {
	first := googleCustomID([]byte(testNakamaCustomIDKey), testGoogleSubject)
	repeated := googleCustomID([]byte(testNakamaCustomIDKey), testGoogleSubject)
	otherKey := googleCustomID(
		[]byte("different-custom-id-key-with-at-least-32-bytes"),
		testGoogleSubject,
	)

	if first != repeated {
		t.Fatalf("googleCustomID repeated value changed: %q != %q", first, repeated)
	}
	if first == otherKey {
		t.Fatalf("googleCustomID ignored the backend key: %q", first)
	}
	if strings.Contains(first, testGoogleSubject) {
		t.Fatalf("googleCustomID exposed the Google subject: %q", first)
	}
}

func TestProvisionGoogleReplacesInheritedAuthorizationWithServerKey(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	provisioner := provisionerAgainst(
		t,
		server,
		acceptingGoogleVerifier(),
		enabledProvisionerConfig(),
	)
	ctx := metadata.NewOutgoingContext(
		context.Background(),
		metadata.Pairs(
			"authorization", "Bearer unrelated-session",
			"grpcgateway-authorization", "Bearer unrelated-gateway-session",
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
	wantAuthorization := "Basic " + base64.StdEncoding.EncodeToString(
		[]byte(testNakamaServerKey+":"),
	)
	if len(authentication[0].authorization) != 1 ||
		authentication[0].authorization[0] != wantAuthorization {
		t.Fatalf(
			"AuthenticateGoogle authorization metadata = %q, want Nakama server key",
			authentication[0].authorization,
		)
	}
	if len(authentication[0].gatewayAuthorization) != 0 {
		t.Fatalf(
			"AuthenticateCustom gRPC-Gateway authorization metadata = %q, want stripped",
			authentication[0].gatewayAuthorization,
		)
	}
	if gatewayAuth := server.observedAccountGatewayAuthorization(); len(gatewayAuth) != 0 {
		t.Fatalf(
			"GetAccount gRPC-Gateway authorization metadata = %q, want stripped",
			gatewayAuth,
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
		verifier      *fakeGoogleIdentityVerifier
		wantCode      codes.Code
		wantError     string
		wantAuthCalls int
		wantAcctCalls int
	}{
		{
			name:       "empty credential",
			config:     enabledProvisionerConfig(),
			wantCode:   codes.Unknown,
			wantError:  "credential is empty",
			credential: "",
		},
		{
			name:       "empty Nakama server key",
			credential: testIdentityProof,
			config: ProvisionerConfig{
				GoogleProvisioningEnabled: true,
				GoogleClientID:            testGoogleClientID,
				NakamaCustomIDKey:         []byte(testNakamaCustomIDKey),
			},
			wantCode:  codes.Unknown,
			wantError: "server key is empty",
		},
		{
			name:       "empty Google client ID",
			credential: testIdentityProof,
			config: ProvisionerConfig{
				GoogleProvisioningEnabled: true,
				NakamaCustomIDKey:         []byte(testNakamaCustomIDKey),
				NakamaServerKey:           testNakamaServerKey,
			},
			wantCode:  codes.Unknown,
			wantError: "Google client ID is empty",
		},
		{
			name:       "empty Nakama custom ID key",
			credential: testIdentityProof,
			config: ProvisionerConfig{
				GoogleProvisioningEnabled: true,
				GoogleClientID:            testGoogleClientID,
				NakamaServerKey:           testNakamaServerKey,
			},
			wantCode:  codes.Unknown,
			wantError: "custom ID key must be at least 32 bytes",
		},
		{
			name:       "short Nakama custom ID key",
			credential: testIdentityProof,
			config: ProvisionerConfig{
				GoogleProvisioningEnabled: true,
				GoogleClientID:            testGoogleClientID,
				NakamaCustomIDKey:         []byte("too-short"),
				NakamaServerKey:           testNakamaServerKey,
			},
			wantCode:  codes.Unknown,
			wantError: "custom ID key must be at least 32 bytes",
		},
		{
			name:       "Google verifier rejects credential",
			credential: testIdentityProof,
			config:     enabledProvisionerConfig(),
			verifier: &fakeGoogleIdentityVerifier{
				err: errors.New("rejected credential " + testIdentityProof),
			},
			wantCode:  codes.Unauthenticated,
			wantError: "Google identity rejected credential",
		},
		{
			name:       "Google verification is unavailable",
			credential: testIdentityProof,
			config:     enabledProvisionerConfig(),
			verifier: &fakeGoogleIdentityVerifier{
				err: status.Error(
					codes.Unavailable,
					"Google unavailable for "+testIdentityProof,
				),
			},
			wantCode:  codes.Unavailable,
			wantError: "Google identity verification unavailable",
		},
		{
			name:       "Google verification is canceled",
			credential: testIdentityProof,
			config:     enabledProvisionerConfig(),
			verifier: &fakeGoogleIdentityVerifier{
				err: context.Canceled,
			},
			wantCode:  codes.Canceled,
			wantError: "Google identity verification canceled",
		},
		{
			name:       "Google verifier returns no subject",
			credential: testIdentityProof,
			config:     enabledProvisionerConfig(),
			verifier:   &fakeGoogleIdentityVerifier{},
			wantCode:   codes.Unknown,
			wantError:  "Google identity has no subject",
		},
		{
			name:       "Nakama rejects custom identity",
			credential: testIdentityProof,
			config:     enabledProvisionerConfig(),
			configure: func(server *provisioningServer) {
				server.rejectCustom = true
			},
			wantCode:      codes.Unauthenticated,
			wantError:     "AuthenticateCustom rejected identity",
			wantAuthCalls: 1,
		},
		{
			name:       "Nakama ambiguous create does not converge",
			credential: testIdentityProof,
			config:     enabledProvisionerConfig(),
			configure: func(server *provisioningServer) {
				server.failCustomInternal = true
			},
			wantCode:      codes.Internal,
			wantError:     "AuthenticateCustom rejected identity",
			wantAuthCalls: 2,
		},
		{
			name:       "Nakama returns no session",
			credential: testIdentityProof,
			config:     enabledProvisionerConfig(),
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
			config:     enabledProvisionerConfig(),
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
			identityVerifier := test.verifier
			if identityVerifier == nil {
				identityVerifier = acceptingGoogleVerifier()
			}
			provisioner := provisionerAgainst(t, server, identityVerifier, test.config)

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
			if strings.Contains(err.Error(), testNakamaServerKey) {
				t.Fatalf("ProvisionGoogle error leaked the Nakama server key: %q", err)
			}
			if strings.Contains(err.Error(), testNakamaCustomIDKey) {
				t.Fatalf("ProvisionGoogle error leaked the Nakama custom ID key: %q", err)
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
