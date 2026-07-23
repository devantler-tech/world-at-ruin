package handoff

import (
	"bytes"
	"context"
	"errors"
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

const (
	testSession       = "signed.nakama.session"
	testReservationID = "handoff-42"
)

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
	requests   []AllocationRequest
	releases   []AllocationRequest
	releaseErr error
	afterAlloc func()
}

func (a *recordingAllocator) Allocate(
	_ context.Context,
	request AllocationRequest,
) (Allocation, error) {
	a.requests = append(a.requests, request)
	if a.afterAlloc != nil {
		a.afterAlloc()
	}
	return a.allocation, a.err
}

func (a *recordingAllocator) Release(
	_ context.Context,
	request AllocationRequest,
) error {
	a.releases = append(a.releases, request)
	return a.releaseErr
}

func validAllocation() Allocation {
	return Allocation{
		ID:              "gameserver-17",
		ServerName:      "zone-17.edge.example",
		Port:            8443,
		Observer:        sim.EntityID(42),
		AdmissionSecret: testSecret(),
	}
}

func testSecret() []byte {
	return bytes.Repeat([]byte{0x42}, 32)
}

func validConfig() Config {
	return Config{
		ZoneDomain: "edge.example",
	}
}

func validRequest() Request {
	return Request{
		Session:       testSession,
		ReservationID: testReservationID,
	}
}

func validAllocationRequest() AllocationRequest {
	return AllocationRequest{
		UserID:        "player-42",
		ReservationID: testReservationID,
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
			ZoneDomain: "edge.example",
			TokenTTL:   45 * time.Second,
			Now:        func() time.Time { return now },
		},
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("CreateHandoff returned an error: %v", err)
	}
	if len(allocator.requests) != 1 ||
		allocator.requests[0] != (AllocationRequest{
			UserID:        "player-42",
			ReservationID: testReservationID,
		}) {
		t.Fatalf(
			"allocator requests = %+v, want one verified player and reservation ID",
			allocator.requests,
		)
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

	zoneVerifier, err := zonesock.NewHMACVerifier(
		allocator.allocation.AdmissionSecret,
		"gameserver-17",
	)
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

	got, err := service.CreateHandoff(context.Background(), validRequest())
	if err == nil {
		t.Fatal("CreateHandoff returned nil error")
	}
	if got != (Handoff{}) {
		t.Fatalf("failed handoff = %+v, want zero value", got)
	}
	if len(allocator.requests) != 0 {
		t.Fatalf(
			"allocator requests = %+v, want no allocation after auth failure",
			allocator.requests,
		)
	}
	if len(allocator.releases) != 0 {
		t.Fatalf("released allocations after auth failure = %+v, want none", allocator.releases)
	}
	if strings.Contains(err.Error(), testSession) {
		t.Fatalf("handoff error leaked the session: %q", err)
	}
}

func TestInvalidReservationNeverAuthenticates(t *testing.T) {
	tests := []struct {
		name          string
		reservationID string
	}{
		{name: "empty", reservationID: ""},
		{name: "header unsafe", reservationID: "handoff-42\r\nX-Injected: yes"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			nakama := &accountServer{
				account: &api.Account{User: &api.User{Id: "player-42"}},
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

			got, err := service.CreateHandoff(context.Background(), Request{
				Session:       testSession,
				ReservationID: test.reservationID,
			})
			if err == nil {
				t.Fatal("CreateHandoff returned nil error")
			}
			if got != (Handoff{}) {
				t.Fatalf("failed handoff = %+v, want zero value", got)
			}
			if auth := nakama.observedAuthorization(); len(auth) != 0 {
				t.Fatalf("Nakama authorization metadata = %q, want no authentication", auth)
			}
			if len(allocator.requests) != 0 || len(allocator.releases) != 0 {
				t.Fatalf(
					"allocator requests/releases = %+v/%+v, want none",
					allocator.requests,
					allocator.releases,
				)
			}
		})
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
			ZoneDomain: "edge.example",
			TokenTTL:   45 * time.Second,
			Now:        func() time.Time { return now },
		},
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(context.Background(), validRequest())
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

func TestMinimumTokenLifetimeSurvivesSecondPrecision(t *testing.T) {
	nakama := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	allocator := &recordingAllocator{allocation: validAllocation()}
	now := time.Unix(2_000_000_000, 900_000_000)
	service, err := NewService(
		verifierAgainst(t, nakama),
		allocator,
		Config{
			ZoneDomain: "edge.example",
			TokenTTL:   time.Second,
			Now:        func() time.Time { return now },
		},
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("CreateHandoff returned an error: %v", err)
	}
	if lifetime := got.ExpiresAt.Sub(now); lifetime < time.Second {
		t.Fatalf("signed token lifetime = %s, want at least one second", lifetime)
	}
}

func TestCancellationAfterAllocationReleasesReservation(t *testing.T) {
	nakama := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	ctx, cancel := context.WithCancel(context.Background())
	allocator := &recordingAllocator{
		allocation: validAllocation(),
		afterAlloc: cancel,
	}
	service, err := NewService(
		verifierAgainst(t, nakama),
		allocator,
		validConfig(),
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(ctx, validRequest())
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("CreateHandoff error = %v, want context canceled", err)
	}
	if got != (Handoff{}) {
		t.Fatalf("cancelled handoff = %+v, want zero value", got)
	}
	if len(allocator.releases) != 1 ||
		allocator.releases[0] != validAllocationRequest() {
		t.Fatalf(
			"released reservations = %+v, want exactly %+v",
			allocator.releases,
			validAllocationRequest(),
		)
	}
}

func TestCancellationDuringTokenMintReleasesReservation(t *testing.T) {
	nakama := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	ctx, cancel := context.WithCancel(context.Background())
	armed := false
	now := time.Now().UTC()
	allocator := &recordingAllocator{allocation: validAllocation()}
	service, err := NewService(
		verifierAgainst(t, nakama),
		allocator,
		Config{
			ZoneDomain: "edge.example",
			Now: func() time.Time {
				if armed {
					cancel()
				}
				return now
			},
		},
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}
	armed = true

	got, err := service.CreateHandoff(ctx, validRequest())
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("CreateHandoff error = %v, want context canceled", err)
	}
	if got != (Handoff{}) {
		t.Fatalf("cancelled handoff = %+v, want zero value", got)
	}
	if len(allocator.releases) != 1 ||
		allocator.releases[0] != validAllocationRequest() {
		t.Fatalf(
			"released reservations = %+v, want exactly %+v",
			allocator.releases,
			validAllocationRequest(),
		)
	}
}

func TestEachAllocationUsesItsOwnAdmissionSecret(t *testing.T) {
	nakama := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	allocation := validAllocation()
	allocation.AdmissionSecret = bytes.Repeat([]byte{0x24}, 32)
	allocator := &recordingAllocator{allocation: allocation}
	service, err := NewService(
		verifierAgainst(t, nakama),
		allocator,
		validConfig(),
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("CreateHandoff returned an error: %v", err)
	}
	zoneVerifier, err := zonesock.NewHMACVerifier(
		allocation.AdmissionSecret,
		allocation.ID,
	)
	if err != nil {
		t.Fatalf("NewHMACVerifier returned an error: %v", err)
	}
	if _, err := zoneVerifier.Verify(got.Token); err != nil {
		t.Fatalf("allocated zone refused its per-allocation token: %v", err)
	}
	otherZoneVerifier, err := zonesock.NewHMACVerifier(testSecret(), allocation.ID)
	if err != nil {
		t.Fatalf("NewHMACVerifier for other zone returned an error: %v", err)
	}
	if _, err := otherZoneVerifier.Verify(got.Token); !errors.Is(err, zonesock.ErrTokenForged) {
		t.Fatalf("other zone verification error = %v, want forged", err)
	}
}

func TestAbsoluteGameServerDNSNameIsNormalized(t *testing.T) {
	nakama := &accountServer{
		account: &api.Account{User: &api.User{Id: "player-42"}},
	}
	allocation := validAllocation()
	allocation.ServerName += "."
	allocator := &recordingAllocator{allocation: allocation}
	service, err := NewService(
		verifierAgainst(t, nakama),
		allocator,
		validConfig(),
	)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}

	got, err := service.CreateHandoff(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("CreateHandoff returned an error: %v", err)
	}
	if got.ServerName != "zone-17.edge.example" {
		t.Fatalf("normalized server name = %q, want zone-17.edge.example", got.ServerName)
	}
	if len(allocator.releases) != 0 {
		t.Fatalf("released valid absolute DNS allocation = %+v, want none", allocator.releases)
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

	got, err := service.CreateHandoff(context.Background(), validRequest())
	if err == nil {
		t.Fatal("CreateHandoff returned nil error")
	}
	if got != (Handoff{}) {
		t.Fatalf("failed handoff = %+v, want zero value", got)
	}
	if len(allocator.requests) != 1 ||
		allocator.requests[0].UserID != "player-42" ||
		allocator.requests[0].ReservationID != testReservationID {
		t.Fatalf(
			"allocator requests = %+v, want one verified player and reservation ID",
			allocator.requests,
		)
	}
	if len(allocator.releases) != 1 ||
		allocator.releases[0] != validAllocationRequest() {
		t.Fatalf(
			"reconciled reservations after ambiguous allocation failure = %+v, want exactly %+v",
			allocator.releases,
			validAllocationRequest(),
		)
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
			name:   "header-unsafe allocation ID",
			mutate: func(a *Allocation) { a.ID = "gameserver-17\r\nX-Injected: yes" },
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
		{
			name:   "missing per-allocation admission secret",
			mutate: func(a *Allocation) { a.AdmissionSecret = nil },
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

			got, err := service.CreateHandoff(context.Background(), validRequest())
			if err == nil {
				t.Fatal("CreateHandoff returned nil error")
			}
			if got != (Handoff{}) {
				t.Fatalf("failed handoff = %+v, want zero value", got)
			}
			if len(allocator.releases) != 1 ||
				allocator.releases[0] != validAllocationRequest() {
				t.Fatalf(
					"released reservations = %+v, want exactly %+v",
					allocator.releases,
					validAllocationRequest(),
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

	got, err := service.CreateHandoff(context.Background(), validRequest())
	if err == nil {
		t.Fatal("CreateHandoff returned nil error")
	}
	if got != (Handoff{}) {
		t.Fatalf("failed handoff = %+v, want zero value", got)
	}
	if len(allocator.releases) != 1 ||
		allocator.releases[0] != validAllocationRequest() {
		t.Fatalf(
			"released reservations = %+v, want exactly %+v",
			allocator.releases,
			validAllocationRequest(),
		)
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
			name:   "negative token TTL",
			verify: verifier,
			alloc:  allocator,
			config: Config{
				ZoneDomain: "edge.example",
				TokenTTL:   -time.Second,
			},
		},
		{
			name:   "sub-second token TTL",
			verify: verifier,
			alloc:  allocator,
			config: Config{
				ZoneDomain: "edge.example",
				TokenTTL:   500 * time.Millisecond,
			},
		},
		{
			name:   "token TTL is not short-lived",
			verify: verifier,
			alloc:  allocator,
			config: Config{
				ZoneDomain: "edge.example",
				TokenTTL:   6 * time.Minute,
			},
		},
		{
			name:   "missing managed zone domain",
			verify: verifier,
			alloc:  allocator,
			config: Config{},
		},
		{
			name:   "raw IP managed zone domain",
			verify: verifier,
			alloc:  allocator,
			config: Config{
				ZoneDomain: "203.0.113.17",
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
		})
	}
}
