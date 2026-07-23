package handoff

import (
	"bytes"
	"context"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/nakamaauth"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
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

const testSession = "signed.nakama.session"

type accountServer struct {
	apigrpc.UnimplementedNakamaServer

	mu         sync.Mutex
	auth       []string
	account    *api.Account
	accountErr error
}

func (s *accountServer) GetAccount(ctx context.Context, _ *emptypb.Empty) (*api.Account, error) {
	md, _ := metadata.FromIncomingContext(ctx)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.auth = append([]string(nil), md.Get("authorization")...)
	return s.account, s.accountErr
}

func (s *accountServer) observedAuthorization() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.auth...)
}

func verifierAgainst(t *testing.T, server *accountServer) *nakamaauth.Verifier {
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
		"passthrough:///nakama-handoff-test",
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

	return nakamaauth.NewVerifier(apigrpc.NewNakamaClient(conn))
}

type recordingAllocator struct {
	allocation Allocation
	err        error
	users      []string
	releases   []Allocation
	releaseErr error
}

func (a *recordingAllocator) Allocate(_ context.Context, userID string) (Allocation, error) {
	a.users = append(a.users, userID)
	return a.allocation, a.err
}

func (a *recordingAllocator) Release(_ context.Context, allocation Allocation) error {
	a.releases = append(a.releases, allocation)
	return a.releaseErr
}

func validAllocation() Allocation {
	return Allocation{
		ID:         "gameserver-17",
		ServerName: "zone-17.edge.example",
		Port:       8443,
		Observer:   sim.EntityID(42),
	}
}

func testSecret() []byte {
	return bytes.Repeat([]byte{0x42}, 32)
}

func validConfig() Config {
	return Config{
		AdmissionSecret: testSecret(),
		ZoneDomain:      "edge.example",
	}
}

func TestServiceCreatesAllocationScopedHandoffThroughRealNakama(t *testing.T) {
	nakama := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	allocator := &recordingAllocator{allocation: validAllocation()}
	now := time.Now().UTC().Truncate(time.Second)
	service, err := NewService(
		verifierAgainst(t, nakama),
		allocator,
		Config{
			AdmissionSecret: testSecret(),
			ZoneDomain:      "edge.example",
			TokenTTL:        45 * time.Second,
			Now:             func() time.Time { return now },
		},
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(context.Background(), testSession)
	if err != nil {
		t.Fatalf("CreateHandoff returned an error: %v", err)
	}
	if len(allocator.users) != 1 || allocator.users[0] != "player-42" {
		t.Fatalf("allocator users = %q, want only verified player-42", allocator.users)
	}
	if len(allocator.releases) != 0 {
		t.Fatalf("released successful allocations = %+v, want none", allocator.releases)
	}
	if auth := nakama.observedAuthorization(); len(auth) != 1 || auth[0] != "Bearer "+testSession {
		t.Fatalf("Nakama authorization metadata = %q, want one supplied bearer session", auth)
	}
	if got.ServerName != "zone-17.edge.example" || got.Port != 8443 {
		t.Fatalf("handoff endpoint = %s:%d, want zone-17.edge.example:8443", got.ServerName, got.Port)
	}
	if want := now.Add(45 * time.Second); !got.ExpiresAt.Equal(want) {
		t.Fatalf("handoff expiry = %s, want %s", got.ExpiresAt, want)
	}
	if got.Token == "" {
		t.Fatal("handoff token is empty")
	}
	if strings.Contains(got.Token, testSession) {
		t.Fatal("handoff token contains the Nakama session")
	}

	zoneVerifier, err := zonesock.NewHMACVerifier(testSecret(), "gameserver-17")
	if err != nil {
		t.Fatalf("NewHMACVerifier returned an error: %v", err)
	}
	observer, err := zoneVerifier.Verify(got.Token)
	if err != nil {
		t.Fatalf("zone refused minted handoff token: %v", err)
	}
	if observer != sim.EntityID(42) {
		t.Fatalf("zone token observer = %d, want 42", observer)
	}
}

func TestAuthenticationFailureNeverAllocates(t *testing.T) {
	nakama := &accountServer{
		accountErr: status.Error(codes.Unauthenticated, "rejected "+testSession),
	}
	allocator := &recordingAllocator{allocation: validAllocation()}
	service, err := NewService(
		verifierAgainst(t, nakama),
		allocator,
		validConfig(),
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(context.Background(), testSession)
	if err == nil {
		t.Fatal("CreateHandoff returned nil error")
	}
	if got != (Handoff{}) {
		t.Fatalf("failed handoff = %+v, want zero value", got)
	}
	if len(allocator.users) != 0 {
		t.Fatalf("allocator users = %q, want no allocation after auth failure", allocator.users)
	}
	if len(allocator.releases) != 0 {
		t.Fatalf("released allocations after auth failure = %+v, want none", allocator.releases)
	}
	if strings.Contains(err.Error(), testSession) {
		t.Fatalf("handoff error leaked the session: %q", err)
	}
}

func TestReportedExpiryMatchesTokenSecondPrecision(t *testing.T) {
	nakama := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	allocator := &recordingAllocator{allocation: validAllocation()}
	now := time.Unix(2_000_000_000, 900_000_000)
	service, err := NewService(
		verifierAgainst(t, nakama),
		allocator,
		Config{
			AdmissionSecret: testSecret(),
			ZoneDomain:      "edge.example",
			TokenTTL:        45 * time.Second,
			Now:             func() time.Time { return now },
		},
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(context.Background(), testSession)
	if err != nil {
		t.Fatalf("CreateHandoff returned an error: %v", err)
	}
	parts := strings.Split(got.Token, ".")
	if len(parts) != 5 {
		t.Fatalf("token has %d fields, want 5", len(parts))
	}
	tokenExpiry, err := strconv.ParseInt(parts[3], 10, 64)
	if err != nil {
		t.Fatalf("parse token expiry: %v", err)
	}
	if got.ExpiresAt.Unix() != tokenExpiry || got.ExpiresAt.Nanosecond() != 0 {
		t.Fatalf(
			"reported expiry = %s, token expiry = %s; want the same second-precision instant",
			got.ExpiresAt,
			time.Unix(tokenExpiry, 0),
		)
	}
}

func TestAllocationFailureReturnsNoHandoff(t *testing.T) {
	nakama := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	allocator := &recordingAllocator{
		err: status.Error(codes.ResourceExhausted, "allocator unavailable for "+testSession),
	}
	service, err := NewService(
		verifierAgainst(t, nakama),
		allocator,
		validConfig(),
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(context.Background(), testSession)
	if err == nil {
		t.Fatal("CreateHandoff returned nil error")
	}
	if got != (Handoff{}) {
		t.Fatalf("failed handoff = %+v, want zero value", got)
	}
	if len(allocator.users) != 1 || allocator.users[0] != "player-42" {
		t.Fatalf("allocator users = %q, want one verified player-42", allocator.users)
	}
	if len(allocator.releases) != 0 {
		t.Fatalf("released allocations after allocation failure = %+v, want none", allocator.releases)
	}
	if code := status.Code(err); code != codes.ResourceExhausted {
		t.Fatalf("handoff status code = %s, want %s", code, codes.ResourceExhausted)
	}
	if strings.Contains(err.Error(), testSession) ||
		strings.Contains(err.Error(), string(testSecret())) {
		t.Fatalf("handoff error leaked a credential: %q", err)
	}
}

func TestMalformedAllocationReturnsNoHandoff(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*Allocation)
	}{
		{
			name:   "empty allocation ID",
			mutate: func(a *Allocation) { a.ID = "" },
		},
		{
			name:   "token-ambiguous allocation ID",
			mutate: func(a *Allocation) { a.ID = "gameserver.17" },
		},
		{
			name:   "empty server name",
			mutate: func(a *Allocation) { a.ServerName = "" },
		},
		{
			name:   "raw IP instead of TLS server name",
			mutate: func(a *Allocation) { a.ServerName = "203.0.113.17" },
		},
		{
			name:   "DNS name outside managed zone domain",
			mutate: func(a *Allocation) { a.ServerName = "attacker.example" },
		},
		{
			name:   "invalid DNS label",
			mutate: func(a *Allocation) { a.ServerName = "-zone.edge.example" },
		},
		{
			name:   "missing TLS port",
			mutate: func(a *Allocation) { a.Port = 0 },
		},
		{
			name:   "missing observer binding",
			mutate: func(a *Allocation) { a.Observer = 0 },
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			nakama := &accountServer{
				account: &api.Account{User: &api.User{Id: "player-42"}},
			}
			allocation := validAllocation()
			test.mutate(&allocation)
			allocator := &recordingAllocator{allocation: allocation}
			service, err := NewService(
				verifierAgainst(t, nakama),
				allocator,
				validConfig(),
			)
			if err != nil {
				t.Fatalf("NewService returned an error: %v", err)
			}

			got, err := service.CreateHandoff(context.Background(), testSession)
			if err == nil {
				t.Fatal("CreateHandoff returned nil error")
			}
			if got != (Handoff{}) {
				t.Fatalf("failed handoff = %+v, want zero value", got)
			}
			if len(allocator.releases) != 1 || allocator.releases[0] != allocation {
				t.Fatalf(
					"released allocations = %+v, want exactly malformed allocation %+v",
					allocator.releases,
					allocation,
				)
			}
		})
	}
}

func TestReleaseFailureRemainsClosedAndSanitized(t *testing.T) {
	nakama := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	allocation := validAllocation()
	allocation.Port = 0
	allocator := &recordingAllocator{
		allocation: allocation,
		releaseErr: status.Error(codes.Unavailable, "release failed for "+testSession),
	}
	service, err := NewService(
		verifierAgainst(t, nakama),
		allocator,
		validConfig(),
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(context.Background(), testSession)
	if err == nil {
		t.Fatal("CreateHandoff returned nil error")
	}
	if got != (Handoff{}) {
		t.Fatalf("failed handoff = %+v, want zero value", got)
	}
	if len(allocator.releases) != 1 || allocator.releases[0] != allocation {
		t.Fatalf("released allocations = %+v, want exactly malformed allocation", allocator.releases)
	}
	if strings.Contains(err.Error(), testSession) {
		t.Fatalf("handoff error leaked a credential: %q", err)
	}
}

func TestNewServiceRejectsUnsafeConfiguration(t *testing.T) {
	verifier := verifierAgainst(t, &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	})
	allocator := &recordingAllocator{allocation: validAllocation()}

	tests := []struct {
		name   string
		verify SessionVerifier
		alloc  Allocator
		config Config
	}{
		{
			name:   "nil verifier",
			alloc:  allocator,
			config: validConfig(),
		},
		{
			name:   "nil allocator",
			verify: verifier,
			config: validConfig(),
		},
		{
			name:   "weak admission secret",
			verify: verifier,
			alloc:  allocator,
			config: Config{AdmissionSecret: []byte("too short"), ZoneDomain: "edge.example"},
		},
		{
			name:   "negative token TTL",
			verify: verifier,
			alloc:  allocator,
			config: Config{
				AdmissionSecret: testSecret(),
				ZoneDomain:      "edge.example",
				TokenTTL:        -time.Second,
			},
		},
		{
			name:   "sub-second token TTL",
			verify: verifier,
			alloc:  allocator,
			config: Config{
				AdmissionSecret: testSecret(),
				ZoneDomain:      "edge.example",
				TokenTTL:        500 * time.Millisecond,
			},
		},
		{
			name:   "token TTL is not short-lived",
			verify: verifier,
			alloc:  allocator,
			config: Config{
				AdmissionSecret: testSecret(),
				ZoneDomain:      "edge.example",
				TokenTTL:        6 * time.Minute,
			},
		},
		{
			name:   "missing managed zone domain",
			verify: verifier,
			alloc:  allocator,
			config: Config{AdmissionSecret: testSecret()},
		},
		{
			name:   "raw IP managed zone domain",
			verify: verifier,
			alloc:  allocator,
			config: Config{
				AdmissionSecret: testSecret(),
				ZoneDomain:      "203.0.113.17",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			service, err := NewService(test.verify, test.alloc, test.config)
			if err == nil {
				t.Fatal("NewService returned nil error")
			}
			if service != nil {
				t.Fatalf("NewService returned service %+v on error", service)
			}
			if strings.Contains(err.Error(), string(test.config.AdmissionSecret)) {
				t.Fatalf("configuration error leaked the admission secret: %q", err)
			}
		})
	}
}
