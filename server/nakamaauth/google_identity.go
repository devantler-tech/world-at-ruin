package nakamaauth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"strings"

	"google.golang.org/api/idtoken"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type googleIDTokenVerifier struct {
	validate func(context.Context, string, string) (*idtoken.Payload, error)
}

func validateGoogleCredentialShape(credential string) error {
	segments := strings.Split(credential, ".")
	if len(segments) != 3 || segments[0] == "" || segments[1] == "" || segments[2] == "" {
		return status.Error(codes.Unauthenticated, "google ID token has an invalid shape")
	}

	encodedHeader, err := base64.RawURLEncoding.DecodeString(segments[0])
	if err != nil {
		return status.Error(codes.Unauthenticated, "google ID token has an invalid header")
	}
	var header struct {
		Algorithm string `json:"alg"`
	}
	if err := json.Unmarshal(encodedHeader, &header); err != nil {
		return status.Error(codes.Unauthenticated, "google ID token has an invalid header")
	}
	if header.Algorithm != "RS256" {
		return status.Error(codes.Unauthenticated, "google ID token has an unsupported algorithm")
	}
	return nil
}

func (v googleIDTokenVerifier) VerifyGoogleIDToken(
	ctx context.Context,
	credential string,
	audience string,
) (string, error) {
	if err := validateGoogleCredentialShape(credential); err != nil {
		return "", err
	}

	validate := v.validate
	if validate == nil {
		validate = idtoken.Validate
	}
	payload, err := validate(ctx, credential, audience)
	if err != nil {
		switch {
		case errors.Is(err, context.Canceled):
			return "", status.Error(codes.Canceled, "google ID token verification canceled")
		case errors.Is(err, context.DeadlineExceeded):
			return "", status.Error(
				codes.DeadlineExceeded,
				"google ID token verification deadline exceeded",
			)
		default:
			var networkError net.Error
			if errors.As(err, &networkError) ||
				strings.HasPrefix(err.Error(), "idtoken: unable to retrieve cert") {
				return "", status.Error(
					codes.Unavailable,
					"google ID token verification unavailable",
				)
			}
			return "", status.Error(
				codes.Unauthenticated,
				"google ID token rejected credential",
			)
		}
	}
	if payload.Issuer != "accounts.google.com" &&
		payload.Issuer != "https://accounts.google.com" {
		return "", status.Error(
			codes.Unauthenticated,
			"google ID token has an unexpected issuer",
		)
	}
	if payload.Subject == "" {
		return "", status.Error(codes.Unauthenticated, "google ID token has no subject")
	}
	return payload.Subject, nil
}
