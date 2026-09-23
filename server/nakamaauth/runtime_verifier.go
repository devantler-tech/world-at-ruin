package nakamaauth

import (
	"context"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"time"
)

type runtimeAccountReader interface {
	AccountGetId(context.Context, string) (*api.Account, error)
}

// RuntimeVerifier authenticates a Nakama RPC from server-provided context only.
// It never accepts a second session or a caller-selected account from payloads.
type RuntimeVerifier struct {
	accounts runtimeAccountReader
	now      func() time.Time
}

// NewRuntimeVerifier binds RPC authentication to Nakama's authoritative accounts.
func NewRuntimeVerifier(accounts runtimeAccountReader) *RuntimeVerifier {
	return &RuntimeVerifier{accounts: accounts, now: time.Now}
}

// VerifySession implements handoff.SessionVerifier; session must be empty because
// Nakama already verified the transport token before invoking the RPC.
func (v *RuntimeVerifier) VerifySession(ctx context.Context, session string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", status.FromContextError(err).Err()
	}
	id, _ := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	expiry, _ := ctx.Value(runtime.RUNTIME_CTX_USER_SESSION_EXP).(int64)
	if session != "" || !nakamastorage.ValidSubjectID(id) || expiry <= v.now().Unix() {
		return "", status.Error(codes.Unauthenticated, "nakama auth: authenticated RPC session required")
	}
	if v.accounts == nil {
		return "", status.Error(codes.Unavailable, "nakama auth: account unavailable")
	}
	account, err := v.accounts.AccountGetId(ctx, id)
	if cancellation := ctx.Err(); cancellation != nil {
		return "", status.FromContextError(cancellation).Err()
	}
	if err != nil {
		return "", status.Error(codes.Unavailable, "nakama auth: account unavailable")
	}
	if account.GetUser().GetId() != id {
		return "", status.Error(codes.Unauthenticated, "nakama auth: account unavailable")
	}
	if account.GetDisableTime() != nil {
		return "", status.Error(codes.PermissionDenied, "nakama auth: account disabled")
	}
	if expiry <= v.now().Unix() {
		return "", status.Error(codes.Unauthenticated, "nakama auth: session expired")
	}
	return id, nil
}
