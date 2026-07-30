package nakamaauth

import (
	"context"
	"encoding/base64"
	"errors"

	"github.com/heroiclabs/nakama-common/api"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

// ErrGoogleProvisioningDisabled reports that the opt-in Google path is off.
var ErrGoogleProvisioningDisabled = errors.New(
	"nakama auth: Google account provisioning is disabled",
)

type provisioningClient interface {
	accountClient
	AuthenticateGoogle(
		context.Context,
		*api.AuthenticateGoogleRequest,
		...grpc.CallOption,
	) (*api.Session, error)
}

// ProvisionerConfig controls opt-in account provisioning paths.
type ProvisionerConfig struct {
	GoogleProvisioningEnabled bool
	// NakamaServerKey authenticates account-creation RPCs with Nakama.
	NakamaServerKey string
}

// Provisioner creates or resolves stable Nakama accounts from external identities.
type Provisioner struct {
	client   provisioningClient
	verifier *Verifier
	config   ProvisionerConfig
}

// NewProvisioner builds a default-off account provisioner.
func NewProvisioner(client provisioningClient, config ProvisionerConfig) *Provisioner {
	return &Provisioner{
		client:   client,
		verifier: NewVerifier(client),
		config:   config,
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
	if p.config.NakamaServerKey == "" {
		return "", errors.New("nakama auth: Nakama server key is empty")
	}

	outgoing, _ := metadata.FromOutgoingContext(ctx)
	outgoing = outgoing.Copy()
	outgoing.Set(
		"authorization",
		"Basic "+base64.StdEncoding.EncodeToString([]byte(p.config.NakamaServerKey+":")),
	)
	ctx = metadata.NewOutgoingContext(ctx, outgoing)

	session, err := p.client.AuthenticateGoogle(ctx, &api.AuthenticateGoogleRequest{
		Account: &api.AccountGoogle{Token: credential},
		Create:  wrapperspb.Bool(true),
	})
	if err != nil {
		return "", status.Error(
			status.Code(err),
			"nakama auth: AuthenticateGoogle rejected credential",
		)
	}
	if session.GetToken() == "" {
		return "", errors.New("nakama auth: AuthenticateGoogle response has no session")
	}

	return p.verifier.VerifySession(ctx, session.GetToken())
}
