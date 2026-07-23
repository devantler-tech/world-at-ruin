// Package nakamaauth verifies player sessions against Nakama's account API.
package nakamaauth

import (
	"context"
	"errors"
	"fmt"

	"github.com/heroiclabs/nakama-common/api"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

type accountClient interface {
	GetAccount(context.Context, *emptypb.Empty, ...grpc.CallOption) (*api.Account, error)
}

// Verifier resolves the authenticated Nakama user behind a session.
type Verifier struct {
	client accountClient
}

// NewVerifier builds a verifier over Nakama's generated gRPC client.
func NewVerifier(client accountClient) *Verifier {
	return &Verifier{client: client}
}

// VerifySession asks Nakama to authenticate session and returns its user ID.
func (v *Verifier) VerifySession(ctx context.Context, session string) (string, error) {
	if session == "" {
		return "", errors.New("nakama auth: session is empty")
	}

	ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+session)
	account, err := v.client.GetAccount(ctx, &emptypb.Empty{})
	if err != nil {
		// Nakama owns the detailed rejection reason. Only carry the stable
		// status code across this boundary so an upstream message can never
		// reflect the bearer credential into our logs.
		return "", fmt.Errorf("nakama auth: GetAccount rejected session (%s)", status.Code(err))
	}

	userID := account.GetUser().GetId()
	if userID == "" {
		return "", errors.New("nakama auth: account response has no user ID")
	}
	return userID, nil
}
