package nakamaauth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"strings"
	"testing"

	"google.golang.org/api/idtoken"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func unsignedGoogleTokenWithPayloadForTest(
	t *testing.T,
	algorithm string,
	payload []byte,
	signature []byte,
) string {
	t.Helper()
	header, err := json.Marshal(map[string]string{"alg": algorithm})
	if err != nil {
		t.Fatalf("marshal test JWT header: %v", err)
	}
	return strings.Join(
		[]string{
			base64.RawURLEncoding.EncodeToString(header),
			base64.RawURLEncoding.EncodeToString(payload),
			base64.RawURLEncoding.EncodeToString(signature),
		},
		".",
	)
}

func unsignedGoogleTokenForTest(t *testing.T, algorithm string, signature []byte) string {
	t.Helper()
	return unsignedGoogleTokenWithPayloadForTest(t, algorithm, []byte("{}"), signature)
}

func TestGoogleIDTokenVerifierAudienceBindsCredential(t *testing.T) {
	var observedCredential string
	var observedAudience string
	verifier := googleIDTokenVerifier{
		validate: func(
			_ context.Context,
			credential string,
			audience string,
		) (*idtoken.Payload, error) {
			observedCredential = credential
			observedAudience = audience
			return &idtoken.Payload{
				Issuer:  "https://accounts.google.com",
				Subject: testGoogleSubject,
			}, nil
		},
	}

	subject, err := verifier.VerifyGoogleIDToken(
		context.Background(),
		testIdentityProof,
		testGoogleClientID,
	)
	if err != nil {
		t.Fatalf("VerifyGoogleIDToken returned an error: %v", err)
	}
	if subject != testGoogleSubject {
		t.Fatalf("VerifyGoogleIDToken subject = %q, want %q", subject, testGoogleSubject)
	}
	if observedCredential != testIdentityProof {
		t.Fatalf("validated credential = %q, want supplied credential", observedCredential)
	}
	if observedAudience != testGoogleClientID {
		t.Fatalf("validated audience = %q, want Google client ID", observedAudience)
	}
}

func TestGoogleIDTokenVerifierRejectsUnsafeTokenShapeBeforeValidation(t *testing.T) {
	invalidSignatureToken := unsignedGoogleTokenForTest(
		t,
		"RS256",
		[]byte("signature"),
	)
	signatureSeparator := strings.LastIndex(invalidSignatureToken, ".")
	invalidSignatureToken = invalidSignatureToken[:signatureSeparator+1] + "*"

	tests := []struct {
		name      string
		token     string
		wantError string
	}{
		{
			name:      "not a JWT",
			token:     "not-a-jwt",
			wantError: "invalid shape",
		},
		{
			name:      "missing algorithm",
			token:     unsignedGoogleTokenForTest(t, "", []byte("signature")),
			wantError: "unsupported algorithm",
		},
		{
			name:      "unsupported ES256 algorithm",
			token:     unsignedGoogleTokenForTest(t, "ES256", []byte("signature")),
			wantError: "unsupported algorithm",
		},
		{
			name:      "invalid RS256 signature encoding",
			token:     invalidSignatureToken,
			wantError: "invalid signature",
		},
		{
			name: "malformed payload",
			token: unsignedGoogleTokenWithPayloadForTest(
				t,
				"RS256",
				[]byte("not-json"),
				[]byte("signature"),
			),
			wantError: "invalid payload",
		},
		{
			name:      "oversized token",
			token:     strings.Repeat(".", 64*1024),
			wantError: "too large",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			validateCalled := false
			verifier := googleIDTokenVerifier{
				validate: func(
					context.Context,
					string,
					string,
				) (*idtoken.Payload, error) {
					validateCalled = true
					return nil, errors.New("validator should not be called")
				},
			}

			_, err := verifier.VerifyGoogleIDToken(
				context.Background(),
				test.token,
				testGoogleClientID,
			)
			if code := status.Code(err); code != codes.Unauthenticated {
				t.Fatalf(
					"VerifyGoogleIDToken status code = %s, want %s (error %v)",
					code,
					codes.Unauthenticated,
					err,
				)
			}
			if validateCalled {
				t.Fatal("VerifyGoogleIDToken called the validator for an unsafe token shape")
			}
			if !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf(
					"VerifyGoogleIDToken error = %q, want it to contain %q",
					err,
					test.wantError,
				)
			}
			if strings.Contains(err.Error(), test.token) {
				t.Fatalf("VerifyGoogleIDToken error leaked the credential: %q", err)
			}
		})
	}
}

func TestGoogleIDTokenVerifierClassifiesValidationFailures(t *testing.T) {
	tests := []struct {
		name     string
		err      error
		wantCode codes.Code
	}{
		{
			name:     "invalid token",
			err:      errors.New("idtoken: token expired"),
			wantCode: codes.Unauthenticated,
		},
		{
			name:     "canceled certificate request",
			err:      context.Canceled,
			wantCode: codes.Canceled,
		},
		{
			name:     "timed out certificate request",
			err:      context.DeadlineExceeded,
			wantCode: codes.DeadlineExceeded,
		},
		{
			name: "network certificate failure",
			err: &url.Error{
				Op:  "Get",
				URL: "https://www.googleapis.com/oauth2/v3/certs",
				Err: &net.DNSError{IsTimeout: true},
			},
			wantCode: codes.Unavailable,
		},
		{
			name:     "certificate endpoint failure",
			err:      errors.New("idtoken: unable to retrieve cert, got status code 503"),
			wantCode: codes.Unavailable,
		},
		{
			name:     "truncated certificate body",
			err:      io.ErrUnexpectedEOF,
			wantCode: codes.Unavailable,
		},
		{
			name:     "malformed certificate body",
			err:      &json.SyntaxError{Offset: 1},
			wantCode: codes.Unavailable,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			verifier := googleIDTokenVerifier{
				validate: func(
					context.Context,
					string,
					string,
				) (*idtoken.Payload, error) {
					return nil, test.err
				},
			}

			_, err := verifier.VerifyGoogleIDToken(
				context.Background(),
				testIdentityProof,
				testGoogleClientID,
			)
			if code := status.Code(err); code != test.wantCode {
				t.Fatalf(
					"VerifyGoogleIDToken status code = %s, want %s (error %v)",
					code,
					test.wantCode,
					err,
				)
			}
			if strings.Contains(err.Error(), testIdentityProof) {
				t.Fatalf("VerifyGoogleIDToken error leaked the credential: %q", err)
			}
		})
	}
}

func TestGoogleIDTokenVerifierRejectsInvalidClaims(t *testing.T) {
	tests := []struct {
		name      string
		payload   *idtoken.Payload
		wantError string
	}{
		{
			name: "unexpected issuer",
			payload: &idtoken.Payload{
				Issuer:  "https://identity.example.com",
				Subject: testGoogleSubject,
			},
			wantError: "unexpected issuer",
		},
		{
			name: "empty subject",
			payload: &idtoken.Payload{
				Issuer: "accounts.google.com",
			},
			wantError: "no subject",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			verifier := googleIDTokenVerifier{
				validate: func(
					context.Context,
					string,
					string,
				) (*idtoken.Payload, error) {
					return test.payload, nil
				},
			}

			subject, err := verifier.VerifyGoogleIDToken(
				context.Background(),
				testIdentityProof,
				testGoogleClientID,
			)
			if err == nil {
				t.Fatal("VerifyGoogleIDToken returned nil error")
			}
			if subject != "" {
				t.Fatalf("VerifyGoogleIDToken subject = %q, want empty", subject)
			}
			if !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf(
					"VerifyGoogleIDToken error = %q, want it to contain %q",
					err,
					test.wantError,
				)
			}
		})
	}
}
