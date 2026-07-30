package nakamaauth

import (
	"context"
	"errors"

	"google.golang.org/api/idtoken"
)

type googleIDTokenVerifier struct {
	validate func(context.Context, string, string) (*idtoken.Payload, error)
}

func (v googleIDTokenVerifier) VerifyGoogleIDToken(
	ctx context.Context,
	credential string,
	audience string,
) (string, error) {
	validate := v.validate
	if validate == nil {
		validate = idtoken.Validate
	}
	payload, err := validate(ctx, credential, audience)
	if err != nil {
		return "", err
	}
	if payload.Issuer != "accounts.google.com" &&
		payload.Issuer != "https://accounts.google.com" {
		return "", errors.New("google ID token has an unexpected issuer")
	}
	if payload.Subject == "" {
		return "", errors.New("google ID token has no subject")
	}
	return payload.Subject, nil
}
