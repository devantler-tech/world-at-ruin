package nakamaauth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

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
	testNakamaIdentityKey = "nakama-identity-key-with-at-least-32-bytes"
	testNakamaServerKey   = "nakama-server-key"
	testNakamaSession     = "nakama-session"
)

type emailAuthentication struct {
	email                string
	password             string
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

type fakeGoogleBindingStore struct {
	mu                   sync.Mutex
	bindings             map[string]string
	resolveErr           error
	bindErr              error
	resolveAuthorization []string
	resolveGatewayAuth   []string
	bindAuthorization    []string
	bindGatewayAuth      []string
	resolveTrace         []string
	bindTrace            []string
	verifyBoundErr       error
	verifyBoundCalls     int
	bindingWrites        int
}

type deadlineRaceGoogleBindingStore struct {
	mu           sync.Mutex
	resolveCalls int
}

func (s *deadlineRaceGoogleBindingStore) ResolveGoogleBinding(
	_ context.Context,
	_ string,
) (string, bool, error) {
	s.mu.Lock()
	s.resolveCalls++
	call := s.resolveCalls
	s.mu.Unlock()
	if call == 1 {
		time.Sleep(5 * time.Millisecond)
		return "", false, nil
	}
	return testBoundUserID, true, nil
}

func (*deadlineRaceGoogleBindingStore) BindGoogleIdentity(
	context.Context,
	string,
	string,
) (string, error) {
	return "", errors.New("unexpected binding write")
}

func (*deadlineRaceGoogleBindingStore) VerifyGoogleBoundAccount(
	context.Context,
	string,
) error {
	return nil
}

type barrierGoogleBindingStore struct {
	*fakeGoogleBindingStore
	mu       sync.Mutex
	arrived  int
	target   int
	released chan struct{}
}

func newFakeGoogleBindingStore() *fakeGoogleBindingStore {
	return &fakeGoogleBindingStore{bindings: make(map[string]string)}
}

func newBarrierGoogleBindingStore(target int) *barrierGoogleBindingStore {
	return &barrierGoogleBindingStore{
		fakeGoogleBindingStore: newFakeGoogleBindingStore(),
		target:                 target,
		released:               make(chan struct{}),
	}
}

func (s *barrierGoogleBindingStore) ResolveGoogleBinding(
	ctx context.Context,
	key string,
) (string, bool, error) {
	s.mu.Lock()
	s.arrived++
	arrival := s.arrived
	if arrival == s.target {
		close(s.released)
	}
	s.mu.Unlock()
	if arrival <= s.target {
		select {
		case <-s.released:
		case <-ctx.Done():
			return "", false, ctx.Err()
		}
	}
	return s.fakeGoogleBindingStore.ResolveGoogleBinding(ctx, key)
}

func (s *fakeGoogleBindingStore) ResolveGoogleBinding(
	ctx context.Context,
	key string,
) (string, bool, error) {
	md, _ := metadata.FromOutgoingContext(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.resolveAuthorization = append([]string(nil), md.Get("authorization")...)
	s.resolveGatewayAuth = append(
		[]string(nil),
		md.Get("grpcgateway-authorization")...,
	)
	s.resolveTrace = append([]string(nil), md.Get("x-trace-id")...)
	if s.resolveErr != nil {
		return "", false, s.resolveErr
	}
	userID, found := s.bindings[key]
	return userID, found, nil
}

func (s *fakeGoogleBindingStore) BindGoogleIdentity(
	ctx context.Context,
	key string,
	userID string,
) (string, error) {
	md, _ := metadata.FromOutgoingContext(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.bindAuthorization = append([]string(nil), md.Get("authorization")...)
	s.bindGatewayAuth = append(
		[]string(nil),
		md.Get("grpcgateway-authorization")...,
	)
	s.bindTrace = append([]string(nil), md.Get("x-trace-id")...)
	if s.bindErr != nil {
		return "", s.bindErr
	}
	if boundUserID, found := s.bindings[key]; found {
		return boundUserID, nil
	}
	s.bindings[key] = userID
	s.bindingWrites++
	return userID, nil
}

func (s *fakeGoogleBindingStore) VerifyGoogleBoundAccount(
	_ context.Context,
	_ string,
) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.verifyBoundCalls++
	return s.verifyBoundErr
}

func (s *fakeGoogleBindingStore) observedMetadata() (
	resolveAuthorization []string,
	resolveGatewayAuth []string,
	bindAuthorization []string,
	bindGatewayAuth []string,
	resolveTrace []string,
	bindTrace []string,
) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.resolveAuthorization...),
		append([]string(nil), s.resolveGatewayAuth...),
		append([]string(nil), s.bindAuthorization...),
		append([]string(nil), s.bindGatewayAuth...),
		append([]string(nil), s.resolveTrace...),
		append([]string(nil), s.bindTrace...)
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
	authentication              []emailAuthentication
	accountCalls                int
	accountGatewayAuthorization []string
	rejectEmail                 bool
	failEmailInternal           bool
	ambiguousCreate             bool
	emptySession                bool
	emptyUserID                 bool
	issuedSession               string
	provisionedUser             string
}

type revokingProvisioningServer struct {
	apigrpc.UnimplementedNakamaServer

	mu                  sync.Mutex
	authenticationCalls int
	accountCalls        int
	currentSession      string
	secondAuthenticated chan struct{}
}

func newRevokingProvisioningServer() *revokingProvisioningServer {
	return &revokingProvisioningServer{
		secondAuthenticated: make(chan struct{}),
	}
}

func (s *revokingProvisioningServer) AuthenticateEmail(
	_ context.Context,
	_ *api.AuthenticateEmailRequest,
) (*api.Session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.authenticationCalls++
	session := fmt.Sprintf("single-session-%d", s.authenticationCalls)
	s.currentSession = session
	if s.authenticationCalls == 2 {
		close(s.secondAuthenticated)
	}
	return &api.Session{
		Created: s.authenticationCalls == 1,
		Token:   session,
	}, nil
}

func (s *revokingProvisioningServer) GetAccount(
	ctx context.Context,
	_ *emptypb.Empty,
) (*api.Account, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	authorization := md.Get("authorization")
	if len(authorization) != 1 {
		return nil, status.Error(codes.Unauthenticated, "missing Nakama session")
	}
	session := strings.TrimPrefix(authorization[0], "Bearer ")
	if session == "single-session-1" {
		select {
		case <-s.secondAuthenticated:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.accountCalls++
	if session != s.currentSession {
		return nil, status.Error(codes.Unauthenticated, "revoked Nakama session")
	}
	return &api.Account{User: &api.User{Id: testBoundUserID}}, nil
}

func (s *provisioningServer) AuthenticateEmail(
	ctx context.Context,
	request *api.AuthenticateEmailRequest,
) (*api.Session, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	account := request.GetAccount()
	authentication := emailAuthentication{
		email:         account.GetEmail(),
		password:      account.GetPassword(),
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
	if s.failEmailInternal {
		return nil, status.Error(codes.Internal, "email identity storage unavailable")
	}
	if s.ambiguousCreate && len(s.authentication) == 1 && authentication.create {
		return nil, status.Error(codes.Internal, "email identity insert raced")
	}
	if s.rejectEmail {
		return nil, status.Error(
			codes.Unauthenticated,
			"rejected email identity "+account.GetEmail()+
				" with password "+account.GetPassword()+
				" and server key "+testNakamaServerKey,
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

func (s *provisioningServer) observed() ([]emailAuthentication, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]emailAuthentication(nil), s.authentication...), s.accountCalls
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
	return provisionerAgainstWithBindings(
		t,
		server,
		identityVerifier,
		newFakeGoogleBindingStore(),
		config,
	)
}

func provisionerAgainstWithBindings(
	t *testing.T,
	server apigrpc.NakamaServer,
	identityVerifier googleIdentityVerifier,
	bindings GoogleBindingStore,
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
			if info.FullMethod == apigrpc.Nakama_AuthenticateEmail_FullMethodName {
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

	return newProvisioner(
		apigrpc.NewNakamaClient(conn),
		identityVerifier,
		bindings,
		config,
	)
}

func enabledProvisionerConfig() ProvisionerConfig {
	return ProvisionerConfig{
		GoogleProvisioningEnabled: true,
		GoogleClientID:            testGoogleClientID,
		NakamaIdentityKey:         []byte(testNakamaIdentityKey),
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
	bindings := newFakeGoogleBindingStore()
	provisioner := provisionerAgainstWithBindings(
		t,
		server,
		identityVerifier,
		bindings,
		enabledProvisionerConfig(),
	)

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
	if len(authentication) != 1 {
		t.Fatalf("AuthenticateEmail calls = %d, want 1", len(authentication))
	}
	if accountCalls != 1 {
		t.Fatalf("GetAccount calls = %d, want 1", accountCalls)
	}
	bindings.mu.Lock()
	verifyBoundCalls := bindings.verifyBoundCalls
	bindings.mu.Unlock()
	if verifyBoundCalls != 2 {
		t.Fatalf("VerifyGoogleBoundAccount calls = %d, want 2", verifyBoundCalls)
	}
	credentials, audiences := identityVerifier.observed()
	if len(credentials) != 2 || len(audiences) != 2 {
		t.Fatalf(
			"Google identity-verification calls = %d, want 2",
			len(credentials),
		)
	}
	for index, request := range authentication {
		wantEmail := googleNakamaEmail([]byte(testNakamaIdentityKey), testGoogleSubject)
		wantPassword := googleNakamaPassword(
			[]byte(testNakamaIdentityKey),
			testGoogleSubject,
		)
		if request.email != wantEmail {
			t.Fatalf(
				"AuthenticateEmail call %d email = %q, want %q",
				index+1,
				request.email,
				wantEmail,
			)
		}
		if request.password != wantPassword {
			t.Fatalf(
				"AuthenticateEmail call %d password did not match derived secret",
				index+1,
			)
		}
		if !request.create {
			t.Fatalf("AuthenticateEmail call %d did not permit account creation", index+1)
		}
		if request.username != "" {
			t.Fatalf(
				"AuthenticateEmail call %d generated username %q, want Nakama default",
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

func TestProvisionGoogleKeepsBindingAfterNakamaEmailIsDetached(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	bindings := newFakeGoogleBindingStore()
	provisioner := provisionerAgainstWithBindings(
		t,
		server,
		acceptingGoogleVerifier(),
		bindings,
		enabledProvisionerConfig(),
	)

	firstUserID, err := provisioner.ProvisionGoogle(context.Background(), testIdentityProof)
	if err != nil {
		t.Fatalf("first ProvisionGoogle returned an error: %v", err)
	}

	server.mu.Lock()
	server.rejectEmail = true
	server.provisionedUser = "duplicate-player"
	server.mu.Unlock()

	repeatedUserID, err := provisioner.ProvisionGoogle(
		context.Background(),
		testIdentityProof,
	)
	if err != nil {
		t.Fatalf("repeated ProvisionGoogle returned an error: %v", err)
	}
	if firstUserID != "player-42" || repeatedUserID != firstUserID {
		t.Fatalf(
			"ProvisionGoogle user IDs = first %q, repeated %q; want stable player-42",
			firstUserID,
			repeatedUserID,
		)
	}
	authentication, accountCalls := server.observed()
	if len(authentication) != 1 || accountCalls != 1 {
		t.Fatalf(
			"detached email caused %d authentication and %d account calls; want 1 each",
			len(authentication),
			accountCalls,
		)
	}
}

func TestProvisionGoogleRejectsDisabledBoundAccount(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	bindings := newFakeGoogleBindingStore()
	provisioner := provisionerAgainstWithBindings(
		t,
		server,
		acceptingGoogleVerifier(),
		bindings,
		enabledProvisionerConfig(),
	)

	if _, err := provisioner.ProvisionGoogle(
		context.Background(),
		testIdentityProof,
	); err != nil {
		t.Fatalf("first ProvisionGoogle returned an error: %v", err)
	}
	bindings.mu.Lock()
	bindings.verifyBoundErr = status.Error(
		codes.PermissionDenied,
		"disabled account player-42",
	)
	bindings.mu.Unlock()

	userID, err := provisioner.ProvisionGoogle(context.Background(), testIdentityProof)
	if status.Code(err) != codes.PermissionDenied {
		t.Fatalf(
			"disabled ProvisionGoogle = (%q, %v), want PermissionDenied",
			userID,
			err,
		)
	}
	if userID != "" || strings.Contains(err.Error(), "player-42") {
		t.Fatalf("disabled ProvisionGoogle exposed identity: (%q, %v)", userID, err)
	}
	authentication, accountCalls := server.observed()
	if len(authentication) != 1 || accountCalls != 1 {
		t.Fatalf(
			"disabled repeat made %d authentication and %d account calls; want 1 each",
			len(authentication),
			accountCalls,
		)
	}
}

func TestProvisionGoogleRequiresDurableBindingStore(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	identityVerifier := acceptingGoogleVerifier()
	provisioner := provisionerAgainstWithBindings(
		t,
		server,
		identityVerifier,
		nil,
		enabledProvisionerConfig(),
	)

	userID, err := provisioner.ProvisionGoogle(context.Background(), testIdentityProof)
	if err == nil || !strings.Contains(err.Error(), "binding store is nil") {
		t.Fatalf("ProvisionGoogle error = %v, want missing binding store", err)
	}
	if userID != "" {
		t.Fatalf("ProvisionGoogle user ID = %q, want empty", userID)
	}
	authentication, accountCalls := server.observed()
	if len(authentication) != 0 || accountCalls != 0 {
		t.Fatalf(
			"missing binding store made %d authentication and %d account calls",
			len(authentication),
			accountCalls,
		)
	}
	credentials, _ := identityVerifier.observed()
	if len(credentials) != 0 {
		t.Fatalf("missing binding store verified %d Google credentials", len(credentials))
	}
}

func TestProvisionGoogleRequiresNakamaClientWhenEnabled(t *testing.T) {
	identityVerifier := acceptingGoogleVerifier()
	provisioner := newProvisioner(
		nil,
		identityVerifier,
		newFakeGoogleBindingStore(),
		enabledProvisionerConfig(),
	)

	userID, err := provisioner.ProvisionGoogle(context.Background(), testIdentityProof)
	if err == nil || !strings.Contains(err.Error(), "Nakama client is nil") {
		t.Fatalf("ProvisionGoogle error = %v, want missing Nakama client", err)
	}
	if userID != "" {
		t.Fatalf("ProvisionGoogle user ID = %q, want empty", userID)
	}
	credentials, _ := identityVerifier.observed()
	if len(credentials) != 0 {
		t.Fatalf("missing Nakama client verified %d Google credentials", len(credentials))
	}
}

func TestProvisionGoogleSanitizesBindingStoreFailures(t *testing.T) {
	tests := []struct {
		name       string
		configure  func(*fakeGoogleBindingStore)
		wantDetail string
		wantAuth   int
	}{
		{
			name: "lookup",
			configure: func(store *fakeGoogleBindingStore) {
				store.resolveErr = errors.New(
					"lookup leaked " + testGoogleSubject + " " + testNakamaIdentityKey,
				)
			},
			wantDetail: "binding lookup failed",
		},
		{
			name: "write",
			configure: func(store *fakeGoogleBindingStore) {
				store.bindErr = errors.New(
					"write leaked " + testGoogleSubject + " " + testNakamaIdentityKey,
				)
			},
			wantDetail: "binding write failed",
			wantAuth:   1,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := &provisioningServer{
				issuedSession:   testNakamaSession,
				provisionedUser: "player-42",
			}
			bindings := newFakeGoogleBindingStore()
			test.configure(bindings)
			provisioner := provisionerAgainstWithBindings(
				t,
				server,
				acceptingGoogleVerifier(),
				bindings,
				enabledProvisionerConfig(),
			)

			userID, err := provisioner.ProvisionGoogle(
				context.Background(),
				testIdentityProof,
			)
			if err == nil ||
				status.Code(err) != codes.Internal ||
				!strings.Contains(err.Error(), test.wantDetail) {
				t.Fatalf(
					"ProvisionGoogle = (%q, %v), want sanitized Internal %q",
					userID,
					err,
					test.wantDetail,
				)
			}
			if strings.Contains(err.Error(), testGoogleSubject) ||
				strings.Contains(err.Error(), testNakamaIdentityKey) {
				t.Fatalf("ProvisionGoogle leaked binding details: %v", err)
			}
			authentication, _ := server.observed()
			if len(authentication) != test.wantAuth {
				t.Fatalf(
					"AuthenticateEmail calls = %d, want %d",
					len(authentication),
					test.wantAuth,
				)
			}
		})
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
		t.Fatalf("AuthenticateEmail calls = %d, want 2", len(authentication))
	}
	if !authentication[0].create {
		t.Fatal("first AuthenticateEmail call did not permit account creation")
	}
	if authentication[1].create {
		t.Fatal("reconciliation AuthenticateEmail call permitted account creation")
	}
	if authentication[0].email != authentication[1].email {
		t.Fatalf(
			"reconciliation email = %q, want first email %q",
			authentication[1].email,
			authentication[0].email,
		)
	}
	if authentication[0].password != authentication[1].password {
		t.Fatalf(
			"reconciliation password changed between attempts",
		)
	}
	if accountCalls != 1 {
		t.Fatalf("GetAccount calls = %d, want 1", accountCalls)
	}
}

func TestProvisionGoogleConvergesConcurrentFirstSignIns(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	const attempts = 8
	bindings := newBarrierGoogleBindingStore(attempts)
	provisioner := provisionerAgainstWithBindings(
		t,
		server,
		acceptingGoogleVerifier(),
		bindings,
		enabledProvisionerConfig(),
	)

	type result struct {
		userID string
		err    error
	}
	start := make(chan struct{})
	results := make(chan result, attempts)
	var wait sync.WaitGroup
	for range attempts {
		wait.Add(1)
		go func() {
			defer wait.Done()
			<-start
			userID, err := provisioner.ProvisionGoogle(
				context.Background(),
				testIdentityProof,
			)
			results <- result{userID: userID, err: err}
		}()
	}
	close(start)
	wait.Wait()
	close(results)

	for observed := range results {
		if observed.err != nil {
			t.Fatalf("concurrent ProvisionGoogle returned an error: %v", observed.err)
		}
		if observed.userID != "player-42" {
			t.Fatalf(
				"concurrent ProvisionGoogle user ID = %q, want player-42",
				observed.userID,
			)
		}
	}

	authentication, _ := server.observed()
	if len(authentication) != 1 {
		t.Fatalf(
			"concurrent first sign-ins made %d AuthenticateEmail calls; want 1 so single-session mode cannot revoke an in-flight verification",
			len(authentication),
		)
	}
	bindings.fakeGoogleBindingStore.mu.Lock()
	bindingWrites := bindings.bindingWrites
	boundUserID := bindings.bindings[googleBindingKey(
		[]byte(testNakamaIdentityKey),
		testGoogleSubject,
	)]
	bindings.fakeGoogleBindingStore.mu.Unlock()
	if bindingWrites != 1 || boundUserID != "player-42" {
		t.Fatalf(
			"concurrent binding state = %d write(s), user %q; want one player-42 binding",
			bindingWrites,
			boundUserID,
		)
	}
}

func TestProvisionGoogleConvergesAcrossProvisionerReplicasAfterSessionRevocation(
	t *testing.T,
) {
	server := newRevokingProvisioningServer()
	bindings := newBarrierGoogleBindingStore(2)
	first := provisionerAgainstWithBindings(
		t,
		server,
		acceptingGoogleVerifier(),
		bindings,
		enabledProvisionerConfig(),
	)
	second := provisionerAgainstWithBindings(
		t,
		server,
		acceptingGoogleVerifier(),
		bindings,
		enabledProvisionerConfig(),
	)

	type result struct {
		userID string
		err    error
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	for _, provisioner := range []*Provisioner{first, second} {
		go func() {
			<-start
			userID, err := provisioner.ProvisionGoogle(
				context.Background(),
				testIdentityProof,
			)
			results <- result{userID: userID, err: err}
		}()
	}
	close(start)

	for range 2 {
		observed := <-results
		if observed.err != nil {
			t.Fatalf("replica ProvisionGoogle returned an error: %v", observed.err)
		}
		if observed.userID != testBoundUserID {
			t.Fatalf(
				"replica ProvisionGoogle user ID = %q, want %q",
				observed.userID,
				testBoundUserID,
			)
		}
	}

	server.mu.Lock()
	authenticationCalls := server.authenticationCalls
	accountCalls := server.accountCalls
	server.mu.Unlock()
	if authenticationCalls != 2 || accountCalls != 2 {
		t.Fatalf(
			"replica convergence made %d authentication and %d account calls; want 2 each",
			authenticationCalls,
			accountCalls,
		)
	}
	bindings.fakeGoogleBindingStore.mu.Lock()
	bindingWrites := bindings.bindingWrites
	bindings.fakeGoogleBindingStore.mu.Unlock()
	if bindingWrites != 1 {
		t.Fatalf("replica convergence made %d binding writes, want 1", bindingWrites)
	}
}

func TestWaitForGoogleBindingRechecksAfterDeadline(t *testing.T) {
	bindings := &deadlineRaceGoogleBindingStore{}
	provisioner := &Provisioner{bindings: bindings}

	userID, found, err := provisioner.waitForGoogleBindingWithin(
		context.Background(),
		googleBindingKey([]byte(testNakamaIdentityKey), testGoogleSubject),
		time.Hour,
		time.Millisecond,
	)
	if err != nil || !found || userID != testBoundUserID {
		t.Fatalf(
			"waitForGoogleBindingWithin = (%q, %t, %v), want final durable binding %q",
			userID,
			found,
			err,
			testBoundUserID,
		)
	}
	bindings.mu.Lock()
	resolveCalls := bindings.resolveCalls
	bindings.mu.Unlock()
	if resolveCalls != 2 {
		t.Fatalf("ResolveGoogleBinding calls = %d, want initial and deadline reads", resolveCalls)
	}
}

func TestGoogleNakamaCredentialsAreSeparatedKeyedAndStable(t *testing.T) {
	contractData, err := os.ReadFile(
		"testdata/golden_google_identity_address_v1.json",
	)
	if err != nil {
		t.Fatalf("read permanent Google identity address contract: %v", err)
	}
	var contract struct {
		Schema              int      `json:"schema"`
		TestIdentityKey     string   `json:"test_identity_key"`
		TestSubject         string   `json:"test_subject"`
		Collection          string   `json:"collection"`
		EmailParts          []string `json:"email_parts"`
		ProofParts          []string `json:"proof_parts"`
		BindingAddressParts []string `json:"binding_address_parts"`
	}
	if err := json.Unmarshal(contractData, &contract); err != nil {
		t.Fatalf("decode permanent Google identity address contract: %v", err)
	}
	if contract.Schema != 1 {
		t.Fatalf("Google identity address contract schema = %d, want 1", contract.Schema)
	}
	if contract.TestIdentityKey != testNakamaIdentityKey ||
		contract.TestSubject != testGoogleSubject {
		t.Fatal("Google identity address contract no longer pins the canonical test inputs")
	}
	if contract.Collection != googleBindingCollection {
		t.Fatalf(
			"googleBindingCollection = %q, want permanent collection %q",
			googleBindingCollection,
			contract.Collection,
		)
	}

	key := []byte(contract.TestIdentityKey)
	firstEmail := googleNakamaEmail(key, contract.TestSubject)
	repeatedEmail := googleNakamaEmail(key, contract.TestSubject)
	password := googleNakamaPassword(key, contract.TestSubject)
	repeatedPassword := googleNakamaPassword(key, contract.TestSubject)
	bindingKey := googleBindingKey(key, contract.TestSubject)
	otherKeyEmail := googleNakamaEmail(
		[]byte("different-identity-key-with-at-least-32-bytes"),
		contract.TestSubject,
	)

	wantEmail := strings.Join(contract.EmailParts, "")
	wantPassword := strings.Join(contract.ProofParts, "")
	wantBindingKey := strings.Join(contract.BindingAddressParts, "")
	if firstEmail != wantEmail {
		t.Fatalf(
			"googleNakamaEmail = %q, want permanent identity address %q",
			firstEmail,
			wantEmail,
		)
	}
	if password != wantPassword {
		t.Fatalf("googleNakamaPassword = %q, want permanent identity password", password)
	}
	if bindingKey != wantBindingKey {
		t.Fatalf(
			"googleBindingKey = %q, want permanent binding address %q",
			bindingKey,
			wantBindingKey,
		)
	}
	if firstEmail != repeatedEmail {
		t.Fatalf("googleNakamaEmail repeated value changed: %q != %q", firstEmail, repeatedEmail)
	}
	if password != repeatedPassword {
		t.Fatal("googleNakamaPassword repeated value changed")
	}
	if firstEmail == otherKeyEmail {
		t.Fatalf("googleNakamaEmail ignored the backend key: %q", firstEmail)
	}
	if strings.Contains(firstEmail, contract.TestSubject) {
		t.Fatalf("googleNakamaEmail exposed the Google subject: %q", firstEmail)
	}
	if strings.Contains(password, firstEmail) || strings.Contains(firstEmail, password) {
		t.Fatal("logged email and authentication password were not domain-separated")
	}
}

func TestProvisionGoogleReplacesInheritedAuthorizationWithServerKey(t *testing.T) {
	server := &provisioningServer{
		issuedSession:   testNakamaSession,
		provisionedUser: "player-42",
	}
	bindings := newFakeGoogleBindingStore()
	provisioner := provisionerAgainstWithBindings(
		t,
		server,
		acceptingGoogleVerifier(),
		bindings,
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
		t.Fatalf("AuthenticateEmail calls = %d, want 1", len(authentication))
	}
	wantAuthorization := "Basic " + base64.StdEncoding.EncodeToString(
		[]byte(testNakamaServerKey+":"),
	)
	if len(authentication[0].authorization) != 1 ||
		authentication[0].authorization[0] != wantAuthorization {
		t.Fatalf(
			"AuthenticateEmail authorization metadata = %q, want Nakama server key",
			authentication[0].authorization,
		)
	}
	if len(authentication[0].gatewayAuthorization) != 0 {
		t.Fatalf(
			"AuthenticateEmail gRPC-Gateway authorization metadata = %q, want stripped",
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
			"AuthenticateEmail trace metadata = %q, want preserved trace-9",
			authentication[0].trace,
		)
	}
	resolveAuthorization, resolveGatewayAuth, bindAuthorization, bindGatewayAuth,
		resolveTrace, bindTrace := bindings.observedMetadata()
	if len(resolveAuthorization) != 0 ||
		len(resolveGatewayAuth) != 0 ||
		len(bindAuthorization) != 0 ||
		len(bindGatewayAuth) != 0 {
		t.Fatalf(
			"binding store received inherited authorization metadata: resolve=(%q, %q), bind=(%q, %q)",
			resolveAuthorization,
			resolveGatewayAuth,
			bindAuthorization,
			bindGatewayAuth,
		)
	}
	if len(resolveTrace) != 1 ||
		resolveTrace[0] != "trace-9" ||
		len(bindTrace) != 1 ||
		bindTrace[0] != "trace-9" {
		t.Fatalf(
			"binding store trace metadata = resolve %q, bind %q; want trace-9",
			resolveTrace,
			bindTrace,
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
				NakamaIdentityKey:         []byte(testNakamaIdentityKey),
			},
			wantCode:  codes.Unknown,
			wantError: "server key is empty",
		},
		{
			name:       "empty Google client ID",
			credential: testIdentityProof,
			config: ProvisionerConfig{
				GoogleProvisioningEnabled: true,
				NakamaIdentityKey:         []byte(testNakamaIdentityKey),
				NakamaServerKey:           testNakamaServerKey,
			},
			wantCode:  codes.Unknown,
			wantError: "Google client ID is empty",
		},
		{
			name:       "empty Nakama identity key",
			credential: testIdentityProof,
			config: ProvisionerConfig{
				GoogleProvisioningEnabled: true,
				GoogleClientID:            testGoogleClientID,
				NakamaServerKey:           testNakamaServerKey,
			},
			wantCode:  codes.Unknown,
			wantError: "identity key must be at least 32 bytes",
		},
		{
			name:       "short Nakama identity key",
			credential: testIdentityProof,
			config: ProvisionerConfig{
				GoogleProvisioningEnabled: true,
				GoogleClientID:            testGoogleClientID,
				NakamaIdentityKey:         []byte("too-short"),
				NakamaServerKey:           testNakamaServerKey,
			},
			wantCode:  codes.Unknown,
			wantError: "identity key must be at least 32 bytes",
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
			name:       "Nakama rejects email identity",
			credential: testIdentityProof,
			config:     enabledProvisionerConfig(),
			configure: func(server *provisioningServer) {
				server.rejectEmail = true
			},
			wantCode:      codes.Unauthenticated,
			wantError:     "AuthenticateEmail rejected identity",
			wantAuthCalls: 1,
		},
		{
			name:       "Nakama ambiguous create does not converge",
			credential: testIdentityProof,
			config:     enabledProvisionerConfig(),
			configure: func(server *provisioningServer) {
				server.failEmailInternal = true
			},
			wantCode:      codes.Internal,
			wantError:     "AuthenticateEmail rejected identity",
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
			if strings.Contains(err.Error(), testNakamaIdentityKey) {
				t.Fatalf("ProvisionGoogle error leaked the Nakama identity key: %q", err)
			}
			derivedPassword := googleNakamaPassword(
				[]byte(testNakamaIdentityKey),
				testGoogleSubject,
			)
			if strings.Contains(err.Error(), derivedPassword) {
				t.Fatalf("ProvisionGoogle error leaked the Nakama email password: %q", err)
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
					"AuthenticateEmail calls = %d, want %d",
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
