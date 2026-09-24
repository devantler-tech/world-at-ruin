package nakamaauth

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"
)

const runtimeUser = "d95d6008-7542-4a3b-9519-0e2c9b66c50a"

type runtimeAccount struct {
	account *api.Account
	err     error
	called  string
}

func (a *runtimeAccount) AccountGetId(_ context.Context, id string) (*api.Account, error) {
	a.called = id
	return a.account, a.err
}

func TestRuntimeVerifierBindsOnlyAuthenticatedContext(t *testing.T) {
	now := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name    string
		id      any
		exp     any
		session string
		account *api.Account
		err     error
		want    codes.Code
		read    bool
	}{
		{"signed in", runtimeUser, now.Add(time.Minute).Unix(), "", &api.Account{User: &api.User{Id: runtimeUser}}, nil, codes.OK, true},
		{"anonymous", nil, nil, "", nil, nil, codes.Unauthenticated, false},
		{"server key", "", now.Add(time.Minute).Unix(), "", nil, nil, codes.Unauthenticated, false},
		{"forged type", 42, now.Add(time.Minute).Unix(), "", nil, nil, codes.Unauthenticated, false},
		{"malformed id", "not-a-user", now.Add(time.Minute).Unix(), "", nil, nil, codes.Unauthenticated, false},
		{"expired", runtimeUser, now.Unix(), "", nil, nil, codes.Unauthenticated, false},
		{"missing expiry", runtimeUser, nil, "", nil, nil, codes.Unauthenticated, false},
		{"wrong expiry type", runtimeUser, "99999999999", "", nil, nil, codes.Unauthenticated, false},
		{"payload session", runtimeUser, now.Add(time.Minute).Unix(), "private-bearer", nil, nil, codes.Unauthenticated, false},
		{"wrong account", runtimeUser, now.Add(time.Minute).Unix(), "", &api.Account{User: &api.User{Id: "other"}}, nil, codes.Unauthenticated, true},
		{"missing account", runtimeUser, now.Add(time.Minute).Unix(), "", nil, nil, codes.Unauthenticated, true},
		{"banned", runtimeUser, now.Add(time.Minute).Unix(), "", &api.Account{User: &api.User{Id: runtimeUser}, DisableTime: timestamppb.New(now)}, nil, codes.PermissionDenied, true},
		{"storage failure", runtimeUser, now.Add(time.Minute).Unix(), "", nil, errors.New("private-bearer"), codes.Unavailable, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			if tc.id != nil {
				ctx = context.WithValue(ctx, runtime.RUNTIME_CTX_USER_ID, tc.id)
			}
			if tc.exp != nil {
				ctx = context.WithValue(ctx, runtime.RUNTIME_CTX_USER_SESSION_EXP, tc.exp)
			}
			accounts := &runtimeAccount{account: tc.account, err: tc.err}
			verifier := NewRuntimeVerifier(accounts)
			verifier.now = func() time.Time { return now }
			id, err := verifier.VerifySession(ctx, tc.session)
			if status.Code(err) != tc.want {
				t.Fatalf("code = %v, want %v", status.Code(err), tc.want)
			}
			if tc.want == codes.OK && id != runtimeUser {
				t.Fatal("lost authenticated identity")
			}
			if tc.want != codes.OK && id != "" {
				t.Fatal("failure returned identity")
			}
			if (accounts.called != "") != tc.read || (tc.read && accounts.called != runtimeUser) {
				t.Fatal("account lookup did not use only the authenticated caller")
			}
			if err != nil && strings.Contains(err.Error(), "private-bearer") {
				t.Fatal("secret escaped in error")
			}
		})
	}
}

func TestRuntimeVerifierPreservesCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	a := &runtimeAccount{}
	_, err := NewRuntimeVerifier(a).VerifySession(ctx, "")
	if status.Code(err) != codes.Canceled || a.called != "" {
		t.Fatal("canceled request reached storage or lost its status")
	}
}
