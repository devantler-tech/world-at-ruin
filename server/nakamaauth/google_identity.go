package nakamaauth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"

	"google.golang.org/api/idtoken"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type googleIDTokenVerifier struct {
	validate func(context.Context, string, string) (*idtoken.Payload, error)
}

const maxGoogleIDTokenBytes = 16 * 1024

func validateGoogleCredentialShape(credential string) error {
	if len(credential) > maxGoogleIDTokenBytes {
		return status.Error(codes.Unauthenticated, "google ID token is too large")
	}
	headerSegment, remainder, ok := strings.Cut(credential, ".")
	if !ok {
		return status.Error(codes.Unauthenticated, "google ID token has an invalid shape")
	}
	payloadSegment, signatureSegment, ok := strings.Cut(remainder, ".")
	if !ok || headerSegment == "" || payloadSegment == "" || signatureSegment == "" ||
		strings.Contains(signatureSegment, ".") {
		return status.Error(codes.Unauthenticated, "google ID token has an invalid shape")
	}

	encodedHeader, err := base64.RawURLEncoding.DecodeString(headerSegment)
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

	encodedPayload, err := base64.RawURLEncoding.DecodeString(payloadSegment)
	if err != nil {
		return status.Error(codes.Unauthenticated, "google ID token has an invalid payload")
	}
	var payload idtoken.Payload
	if err := json.Unmarshal(encodedPayload, &payload); err != nil {
		return status.Error(codes.Unauthenticated, "google ID token has an invalid payload")
	}
	var claims map[string]any
	if err := json.Unmarshal(encodedPayload, &claims); err != nil {
		return status.Error(codes.Unauthenticated, "google ID token has an invalid payload")
	}
	if _, err := base64.RawURLEncoding.DecodeString(signatureSegment); err != nil {
		return status.Error(codes.Unauthenticated, "google ID token has an invalid signature")
	}
	return nil
}

func googleVerificationUnavailable(err error) bool {
	var networkError net.Error
	var syntaxError *json.SyntaxError
	var typeError *json.UnmarshalTypeError
	var encodingError base64.CorruptInputError
	return errors.As(err, &networkError) ||
		errors.Is(err, io.EOF) ||
		errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.As(err, &syntaxError) ||
		errors.As(err, &typeError) ||
		errors.As(err, &encodingError) ||
		strings.HasPrefix(err.Error(), "idtoken: unable to retrieve cert")
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
			if googleVerificationUnavailable(err) {
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
