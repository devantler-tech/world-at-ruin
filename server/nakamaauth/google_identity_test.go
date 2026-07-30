package nakamaauth

import (
	"context"
	"strings"
	"testing"

	"google.golang.org/api/idtoken"
)

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
