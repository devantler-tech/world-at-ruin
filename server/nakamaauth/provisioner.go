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
	AuthenticateEmail(
		context.Context,
		*api.AuthenticateEmailRequest,
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
	// NakamaIdentityKey separates the logged identifier from its password.
	NakamaIdentityKey []byte
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
	config.NakamaIdentityKey = bytes.Clone(config.NakamaIdentityKey)
	return &Provisioner{
		client:           client,
		sessionVerifier:  NewVerifier(client),
		identityVerifier: identityVerifier,
		config:           config,
	}
}

func googleNakamaHMAC(key []byte, purpose string, subject string) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte("google:" + purpose + ":" + subject))
	return mac.Sum(nil)
}

func googleNakamaEmail(key []byte, subject string) string {
	identifier := googleNakamaHMAC(key, "email", subject)
	return hex.EncodeToString(identifier) + "@identity.world-at-ruin.invalid"
}

func googleNakamaPassword(key []byte, subject string) string {
	password := googleNakamaHMAC(key, "password", subject)
	return base64.RawURLEncoding.EncodeToString(password)
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

func (p *Provisioner) authenticateEmail(
	ctx context.Context,
	email string,
	password string,
	create bool,
) (*api.Session, error) {
	return p.client.AuthenticateEmail(ctx, &api.AuthenticateEmailRequest{
		Account: &api.AccountEmail{
			Email:    email,
			Password: password,
		},
		Create: wrapperspb.Bool(create),
	})
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
	if len(p.config.NakamaIdentityKey) < 32 {
		return "", errors.New("nakama auth: Nakama identity key must be at least 32 bytes")
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

	email := googleNakamaEmail(p.config.NakamaIdentityKey, subject)
	password := googleNakamaPassword(p.config.NakamaIdentityKey, subject)
	session, err := p.authenticateEmail(ctx, email, password, true)
	if status.Code(err) == codes.Internal {
		// Nakama v3.40 reports the losing side of concurrent email
		// creation as Internal after the winning insert commits. One
		// create=false lookup adopts that winner without opening another
		// account-creation race.
		reconciled, reconcileErr := p.authenticateEmail(ctx, email, password, false)
		if reconcileErr == nil {
			session = reconciled
			err = nil
		} else if status.Code(reconcileErr) == codes.Canceled ||
			status.Code(reconcileErr) == codes.DeadlineExceeded {
			err = reconcileErr
		}
	}
	if err != nil {
		return "", status.Error(
			status.Code(err),
			"nakama auth: AuthenticateEmail rejected identity",
		)
	}
	if session.GetToken() == "" {
		return "", errors.New("nakama auth: AuthenticateEmail response has no session")
	}

	return p.sessionVerifier.VerifySession(ctx, session.GetToken())
}
