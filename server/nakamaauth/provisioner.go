package nakamaauth

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"

	"github.com/heroiclabs/nakama-common/api"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

// ErrGoogleProvisioningDisabled reports that the opt-in Google path is off.
var ErrGoogleProvisioningDisabled = errors.New(
	"nakama auth: Google account provisioning is disabled",
)

type provisioningClient interface {
	accountClient
	AuthenticateCustom(
		context.Context,
		*api.AuthenticateCustomRequest,
		...grpc.CallOption,
	) (*api.Session, error)
}

type googleIdentityVerifier interface {
	VerifyGoogleIDToken(context.Context, string, string) (string, error)
}

// ProvisionerConfig controls opt-in account provisioning paths.
type ProvisionerConfig struct {
	GoogleProvisioningEnabled bool
	// GoogleClientID audience-binds accepted Google ID tokens.
	GoogleClientID string
	// NakamaCustomIDKey makes the custom-auth credential unguessable.
	NakamaCustomIDKey []byte
	// NakamaServerKey authenticates account-creation RPCs with Nakama.
	NakamaServerKey string
}

// Provisioner creates or resolves stable Nakama accounts from external identities.
type Provisioner struct {
	client           provisioningClient
	sessionVerifier  *Verifier
	identityVerifier googleIdentityVerifier
	config           ProvisionerConfig
}

// NewProvisioner builds a default-off account provisioner.
func NewProvisioner(client provisioningClient, config ProvisionerConfig) *Provisioner {
	return newProvisioner(client, googleIDTokenVerifier{}, config)
}

func newProvisioner(
	client provisioningClient,
	identityVerifier googleIdentityVerifier,
	config ProvisionerConfig,
) *Provisioner {
	config.NakamaCustomIDKey = bytes.Clone(config.NakamaCustomIDKey)
	return &Provisioner{
		client:           client,
		sessionVerifier:  NewVerifier(client),
		identityVerifier: identityVerifier,
		config:           config,
	}
}

func googleCustomID(key []byte, subject string) string {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte("google:" + subject))
	return hex.EncodeToString(mac.Sum(nil))
}

func sanitizedGoogleIdentityError(err error) error {
	switch {
	case errors.Is(err, context.Canceled) || status.Code(err) == codes.Canceled:
		return status.Error(
			codes.Canceled,
			"nakama auth: Google identity verification canceled",
		)
	case errors.Is(err, context.DeadlineExceeded) ||
		status.Code(err) == codes.DeadlineExceeded:
		return status.Error(
			codes.DeadlineExceeded,
			"nakama auth: Google identity verification deadline exceeded",
		)
	case status.Code(err) == codes.Unavailable:
		return status.Error(
			codes.Unavailable,
			"nakama auth: Google identity verification unavailable",
		)
	default:
		return status.Error(
			codes.Unauthenticated,
			"nakama auth: Google identity rejected credential",
		)
	}
}

// ProvisionGoogle creates or resolves the Nakama account for a Google identity.
func (p *Provisioner) ProvisionGoogle(
	ctx context.Context,
	credential string,
) (string, error) {
	if !p.config.GoogleProvisioningEnabled {
		return "", ErrGoogleProvisioningDisabled
	}
	if credential == "" {
		return "", errors.New("nakama auth: Google credential is empty")
	}
	if p.config.GoogleClientID == "" {
		return "", errors.New("nakama auth: Google client ID is empty")
	}
	if p.config.NakamaServerKey == "" {
		return "", errors.New("nakama auth: Nakama server key is empty")
	}
	if len(p.config.NakamaCustomIDKey) < 32 {
		return "", errors.New("nakama auth: Nakama custom ID key must be at least 32 bytes")
	}

	subject, err := p.identityVerifier.VerifyGoogleIDToken(
		ctx,
		credential,
		p.config.GoogleClientID,
	)
	if err != nil {
		return "", sanitizedGoogleIdentityError(err)
	}
	if subject == "" {
		return "", errors.New("nakama auth: Google identity has no subject")
	}

	ctx = outgoingAuthorizationContext(
		ctx,
		"Basic "+base64.StdEncoding.EncodeToString([]byte(p.config.NakamaServerKey+":")),
	)

	session, err := p.client.AuthenticateCustom(ctx, &api.AuthenticateCustomRequest{
		Account: &api.AccountCustom{
			Id: googleCustomID(p.config.NakamaCustomIDKey, subject),
		},
		Create: wrapperspb.Bool(true),
	})
	if err != nil {
		return "", status.Error(
			status.Code(err),
			"nakama auth: AuthenticateCustom rejected identity",
		)
	}
	if session.GetToken() == "" {
		return "", errors.New("nakama auth: AuthenticateCustom response has no session")
	}

	return p.sessionVerifier.VerifySession(ctx, session.GetToken())
}
