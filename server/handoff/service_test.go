package handoff

import (
	"bytes"
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/nakamaaccounttest"
	"github.com/devantler-tech/world-at-ruin/server/nakamaauth"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
	"github.com/heroiclabs/nakama-common/api"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	testSession       = "signed.nakama.session"
	testReservationID = "handoff-42"
	testAttemptID     = "attempt-7"
)

type accountServer = nakamaaccounttest.Server

func verifierAgainst(t *testing.T, server *accountServer) *nakamaauth.Verifier {
	t.Helper()
	return nakamaauth.NewVerifier(nakamaaccounttest.Client(t, server))
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
		ID:              "gameserver-17.games",
		ServerName:      "zone-17.edge.example",
		Port:            8443,
		Observer:        sim.EntityID(42),
		AdmissionSecret: testSecret(),
		LeaseExpiresAt:  time.Unix(4_000_000_000, 0),
	}
}

func testSecret() []byte {
	return bytes.Repeat([]byte{0x42}, 32)
}

func validConfig() Config {
	return Config{
		ZoneDomain:   "edge.example",
		NewAttemptID: func() (string, error) { return testAttemptID, nil },
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
		AttemptID:     testAttemptID,
	}
}

func TestServiceCreatesAllocationScopedHandoffThroughRealNakama(t *testing.T) {
	nakama := validAccountServer()
	allocator := &recordingAllocator{allocation: validAllocation()}
	now := time.Now().UTC().Truncate(time.Second)
	service := mustService(t,
		verifierAgainst(t, nakama),
		allocator,
		Config{
			ZoneDomain:   "edge.example",
			TokenTTL:     45 * time.Second,
			Now:          func() time.Time { return now },
			NewAttemptID: func() (string, error) { return testAttemptID, nil },
		},
	)

	got := mustHandoff(t, service)
	if len(allocator.requests) != 1 ||
		allocator.requests[0] != validAllocationRequest() {
		t.Fatalf(
			"allocator requests = %+v, want one verified player and reservation ID",
			allocator.requests,
		)
	}
	if len(allocator.releases) != 0 {
		t.Fatalf("released successful allocations = %+v, want none", allocator.releases)
	}
	if auth := nakama.ObservedAuthorization(); len(auth) != 1 || auth[0] != "Bearer "+testSession {
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
		"gameserver-17.games",
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

func TestKubernetesDNSSubdomainAllocationCreatesHandoff(t *testing.T) {
	tests := []struct {
		name         string
		allocationID string
	}{
		{name: "numeric labels", allocationID: "1.2.3.4"},
		{name: "long label", allocationID: strings.Repeat("a", 64) + ".games"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			nakama := validAccountServer()
			allocation := validAllocation()
			allocation.ID = test.allocationID
			allocator := &recordingAllocator{allocation: allocation}
			service := serviceAgainst(t, nakama, allocator, validConfig())

			handoff, err := service.CreateHandoff(context.Background(), validRequest())
			if err != nil {
				t.Fatalf("CreateHandoff rejected a valid Kubernetes DNS subdomain: %v", err)
			}
			zoneVerifier, err := zonesock.NewHMACVerifier(allocation.AdmissionSecret, allocation.ID)
			if err != nil {
				t.Fatalf("NewHMACVerifier returned an error: %v", err)
			}
			if _, err := zoneVerifier.Verify(handoff.Token); err != nil {
				t.Fatalf("zone refused Kubernetes DNS-subdomain handoff token: %v", err)
			}
		})
	}
}

func TestRetriesUseDistinctAttemptOwnership(t *testing.T) {
	nakama := validAccountServer()
	allocator := &recordingAllocator{allocation: validAllocation()}
	service := mustService(t,
		verifierAgainst(t, nakama),
		allocator,
		Config{ZoneDomain: "edge.example"},
	)

	for range 2 {
		if _, err := service.CreateHandoff(context.Background(), validRequest()); err != nil {
			t.Fatalf("CreateHandoff returned an error: %v", err)
		}
	}
	if len(allocator.requests) != 2 {
		t.Fatalf("allocator requests = %+v, want two attempts", allocator.requests)
	}
	first, second := allocator.requests[0], allocator.requests[1]
	if first.UserID != second.UserID ||
		first.ReservationID != second.ReservationID ||
		first.AttemptID == "" ||
		first.AttemptID == second.AttemptID {
		t.Fatalf(
			"retry ownership = %+v then %+v, want stable owner/key and distinct attempts",
			first,
			second,
		)
	}
}

func TestAttemptIDFailureNeverAllocates(t *testing.T) {
	nakama := validAccountServer()
	allocator := &recordingAllocator{allocation: validAllocation()}
	service := mustService(t,
		verifierAgainst(t, nakama),
		allocator,
		Config{
			ZoneDomain: "edge.example",
			NewAttemptID: func() (string, error) {
				return "", errors.New("generator leaked " + testSession)
			},
		},
	)

	got, err := service.CreateHandoff(context.Background(), validRequest())
	requireFailedHandoff(t, got, err)
	if len(allocator.requests) != 0 || len(allocator.releases) != 0 {
		t.Fatalf(
			"allocator requests/releases = %+v/%+v, want none",
			allocator.requests,
			allocator.releases,
		)
	}
	if strings.Contains(err.Error(), testSession) {
		t.Fatalf("handoff error leaked attempt generator detail: %q", err)
	}
}

func TestAuthenticationFailureNeverAllocates(t *testing.T) {
	nakama := &accountServer{
		AccountErr: status.Error(codes.Unauthenticated, "rejected "+testSession),
	}
	allocator := &recordingAllocator{allocation: validAllocation()}
	service := serviceAgainst(t, nakama, allocator, validConfig())

	got, err := service.CreateHandoff(context.Background(), validRequest())
	requireFailedHandoff(t, got, err)
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
		{name: "token separator", reservationID: "handoff.42"},
		{name: "header unsafe", reservationID: "handoff-42\r\nX-Injected: yes"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			nakama := validAccountServer()
			allocator := &recordingAllocator{allocation: validAllocation()}
			service := serviceAgainst(t, nakama, allocator, validConfig())

			got, err := service.CreateHandoff(context.Background(), Request{
				Session:       testSession,
				ReservationID: test.reservationID,
			})
			requireFailedHandoff(t, got, err)
			if auth := nakama.ObservedAuthorization(); len(auth) != 0 {
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

func TestReportedExpiryMatchesTokenNanosecondPrecision(t *testing.T) {
	now := time.Unix(2_000_000_000, 900_000_000)
	service := timedService(t, now, 45*time.Second)

	got := mustHandoff(t, service)
	parts := strings.Split(got.Token, ".")
	if len(parts) < 5 {
		t.Fatalf("token has %d fields, want at least 5", len(parts))
	}
	tokenExpiryNanos, err := strconv.ParseInt(parts[len(parts)-2], 10, 64)
	if err != nil {
		t.Fatalf("parse token expiry: %v", err)
	}
	if got.ExpiresAt.UnixNano() != tokenExpiryNanos {
		t.Fatalf(
			"reported expiry = %s, token expiry = %s; want the same nanosecond instant",
			got.ExpiresAt,
			time.Unix(0, tokenExpiryNanos),
		)
	}
}

func TestMinimumTokenLifetimeSurvivesSecondPrecision(t *testing.T) {
	now := time.Unix(2_000_000_000, 900_000_000)
	service := timedService(t, now, time.Second)

	got := mustHandoff(t, service)
	if lifetime := got.ExpiresAt.Sub(now); lifetime != time.Second {
		t.Fatalf("signed token lifetime = %s, want exactly one second", lifetime)
	}
}

func TestTokenNeverOutlivesUnclaimedAllocationLease(t *testing.T) {
	nakama := validAccountServer()
	now := time.Unix(2_000_000_000, 123_456_789)
	allocation := validAllocation()
	allocation.LeaseExpiresAt = now.Add(5 * time.Second)
	allocator := &recordingAllocator{allocation: allocation}
	service := mustService(t,
		verifierAgainst(t, nakama),
		allocator,
		Config{
			ZoneDomain:   "edge.example",
			TokenTTL:     30 * time.Second,
			Now:          func() time.Time { return now },
			NewAttemptID: func() (string, error) { return testAttemptID, nil },
		},
	)

	got := mustHandoff(t, service)
	if !got.ExpiresAt.Equal(allocation.LeaseExpiresAt) {
		t.Fatalf(
			"token expiry = %s, want lease expiry %s",
			got.ExpiresAt,
			allocation.LeaseExpiresAt,
		)
	}
}

func TestCancellationAfterAllocationReleasesReservation(t *testing.T) {
	nakama := validAccountServer()
	ctx, cancel := context.WithCancel(context.Background())
	allocator := &recordingAllocator{
		allocation: validAllocation(),
		afterAlloc: cancel,
	}
	service := serviceAgainst(t, nakama, allocator, validConfig())

	requireCancelledHandoff(t, service, ctx, allocator)
}

func TestCancellationDuringTokenMintReleasesReservation(t *testing.T) {
	nakama := validAccountServer()
	ctx, cancel := context.WithCancel(context.Background())
	armed := false
	now := time.Now().UTC()
	allocator := &recordingAllocator{allocation: validAllocation()}
	service := mustService(t,
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
			NewAttemptID: func() (string, error) { return testAttemptID, nil },
		},
	)
	armed = true

	requireCancelledHandoff(t, service, ctx, allocator)
}

func TestEachAllocationUsesItsOwnAdmissionSecret(t *testing.T) {
	nakama := validAccountServer()
	allocation := validAllocation()
	allocation.AdmissionSecret = bytes.Repeat([]byte{0x24}, 32)
	allocator := &recordingAllocator{allocation: allocation}
	service := serviceAgainst(t, nakama, allocator, validConfig())

	got := mustHandoff(t, service)
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
	nakama := validAccountServer()
	allocation := validAllocation()
	allocation.ServerName += "."
	allocator := &recordingAllocator{allocation: allocation}
	service := serviceAgainst(t, nakama, allocator, validConfig())

	got := mustHandoff(t, service)
	if got.ServerName != "zone-17.edge.example" {
		t.Fatalf("normalized server name = %q, want zone-17.edge.example", got.ServerName)
	}
	if len(allocator.releases) != 0 {
		t.Fatalf("released valid absolute DNS allocation = %+v, want none", allocator.releases)
	}
}

func TestAllocationFailureReturnsNoHandoff(t *testing.T) {
	nakama := validAccountServer()
	allocator := &recordingAllocator{
		err: status.Error(codes.ResourceExhausted, "allocator unavailable for "+testSession),
	}
	service := serviceAgainst(t, nakama, allocator, validConfig())

	got, err := service.CreateHandoff(context.Background(), validRequest())
	requireFailedHandoff(t, got, err)
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

func TestRetainedAllocationFailureSkipsOuterRelease(t *testing.T) {
	tests := []struct {
		name string
		err  error
		code codes.Code
	}{
		{
			name: "unavailable",
			err:  status.Error(codes.Unavailable, "durable dispatch outcome is ambiguous"),
			code: codes.Unavailable,
		},
		{name: "canceled", err: context.Canceled, code: codes.Canceled},
		{
			name: "deadline exceeded",
			err:  context.DeadlineExceeded,
			code: codes.DeadlineExceeded,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			nakama := validAccountServer()
			allocator := &recordingAllocator{
				err: RetainAllocationOutcome(test.err),
			}
			service := serviceAgainst(t, nakama, allocator, validConfig())

			got, err := service.CreateHandoff(context.Background(), validRequest())
			if status.Code(err) != test.code {
				t.Fatalf("CreateHandoff status = %s, want %s", status.Code(err), test.code)
			}
			if got != (Handoff{}) {
				t.Fatalf("failed retained handoff = %+v, want zero value", got)
			}
			if len(allocator.releases) != 0 {
				t.Fatalf("retained allocation error released outcome: %+v", allocator.releases)
			}
		})
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
			name:   "header-unsafe allocation ID",
			mutate: func(a *Allocation) { a.ID = "gameserver-17\r\nX-Injected: yes" },
		},
		{
			name:   "empty allocation DNS label",
			mutate: func(a *Allocation) { a.ID = "gameserver..17" },
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
		{
			name:   "missing no-show lease expiry",
			mutate: func(a *Allocation) { a.LeaseExpiresAt = time.Time{} },
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			nakama := validAccountServer()
			allocation := validAllocation()
			test.mutate(&allocation)
			allocator := &recordingAllocator{allocation: allocation}
			service := serviceAgainst(t, nakama, allocator, validConfig())

			got, err := service.CreateHandoff(context.Background(), validRequest())
			requireFailedHandoff(t, got, err)
			requireReleasedAllocation(t, allocator)
		})
	}
}

func TestReleaseFailureRemainsClosedAndSanitized(t *testing.T) {
	nakama := validAccountServer()
	allocation := validAllocation()
	allocation.Port = 0
	allocator := &recordingAllocator{
		allocation: allocation,
		releaseErr: status.Error(codes.Unavailable, "release failed for "+testSession),
	}
	service := serviceAgainst(t, nakama, allocator, validConfig())

	got, err := service.CreateHandoff(context.Background(), validRequest())
	requireFailedHandoff(t, got, err)
	requireReleasedAllocation(t, allocator)
	if strings.Contains(err.Error(), testSession) {
		t.Fatalf("handoff error leaked a credential: %q", err)
	}
	if code := status.Code(err); code != codes.Unavailable {
		t.Fatalf("handoff status code = %s, want %s", code, codes.Unavailable)
	}
}

func TestNewServiceRejectsUnsafeConfiguration(t *testing.T) {
	verifier := verifierAgainst(t, validAccountServer())
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

func mustService(t *testing.T, verifier SessionVerifier, allocator Allocator, cfg Config) *Service {
	t.Helper()
	service, err := NewService(verifier, allocator, cfg)
	if err != nil {
		t.Fatalf("NewService returned an error: %v", err)
	}
	return service
}

func validAccountServer() *accountServer {
	return &accountServer{Account: &api.Account{User: &api.User{Id: "player-42"}}}
}

func requireFailedHandoff(t *testing.T, got Handoff, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("CreateHandoff returned nil error")
	}
	if got != (Handoff{}) {
		t.Fatalf("failed handoff = %+v, want zero value", got)
	}
}

func serviceAgainst(t *testing.T, account *accountServer, allocator Allocator, cfg Config) *Service {
	t.Helper()
	return mustService(t, verifierAgainst(t, account), allocator, cfg)
}

func mustHandoff(t *testing.T, service *Service) Handoff {
	t.Helper()
	got, err := service.CreateHandoff(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("CreateHandoff returned an error: %v", err)
	}
	return got
}

func requireReleasedAllocation(t *testing.T, allocator *recordingAllocator) {
	t.Helper()
	if len(allocator.releases) != 1 || allocator.releases[0] != validAllocationRequest() {
		t.Fatalf("released reservations = %+v, want exactly %+v", allocator.releases, validAllocationRequest())
	}
}

func timedService(t *testing.T, now time.Time, ttl time.Duration) *Service {
	t.Helper()
	return serviceAgainst(t, validAccountServer(), &recordingAllocator{allocation: validAllocation()}, Config{
		ZoneDomain: "edge.example",
		TokenTTL:   ttl,
		Now:        func() time.Time { return now },
	})
}

func requireCancelledHandoff(t *testing.T, service *Service, ctx context.Context, allocator *recordingAllocator) {
	t.Helper()
	got, err := service.CreateHandoff(ctx, validRequest())
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("CreateHandoff error = %v, want context canceled", err)
	}
	if got != (Handoff{}) {
		t.Fatalf("cancelled handoff = %+v, want zero value", got)
	}
	requireReleasedAllocation(t, allocator)
}
