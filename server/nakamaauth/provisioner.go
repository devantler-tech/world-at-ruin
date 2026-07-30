package nakamaauth

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"sync"
	"time"

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

const (
	googleBindingReconcileInterval = 10 * time.Millisecond
	googleBindingReconcileWindow   = time.Second
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

// GoogleBindingStore owns the durable, immutable Google-subject-to-user binding.
//
// ResolveGoogleBinding receives only a server-keyed opaque binding key.
// BindGoogleIdentity must atomically preserve the first user ID stored for that
// key and return that winner on every later call. Production implementations
// must keep bindings in server-owned storage that player sessions cannot
// update or delete.
type GoogleBindingStore interface {
	ResolveGoogleBinding(context.Context, string) (userID string, found bool, err error)
	BindGoogleIdentity(context.Context, string, string) (boundUserID string, err error)
	VerifyGoogleBoundAccount(context.Context, string) error
}

type googleProvisioningGateEntry struct {
	token chan struct{}
	users int
}

type googleProvisioningGate struct {
	mu      sync.Mutex
	entries map[string]*googleProvisioningGateEntry
}

func (g *googleProvisioningGate) acquire(
	ctx context.Context,
	key string,
) (func(), error) {
	g.mu.Lock()
	if g.entries == nil {
		g.entries = make(map[string]*googleProvisioningGateEntry)
	}
	entry := g.entries[key]
	if entry == nil {
		entry = &googleProvisioningGateEntry{token: make(chan struct{}, 1)}
		entry.token <- struct{}{}
		g.entries[key] = entry
	}
	entry.users++
	g.mu.Unlock()

	if err := ctx.Err(); err != nil {
		g.done(key, entry)
		return nil, err
	}
	select {
	case <-ctx.Done():
		g.done(key, entry)
		return nil, ctx.Err()
	case <-entry.token:
		return func() {
			entry.token <- struct{}{}
			g.done(key, entry)
		}, nil
	}
}

func (g *googleProvisioningGate) done(
	key string,
	entry *googleProvisioningGateEntry,
) {
	g.mu.Lock()
	defer g.mu.Unlock()
	entry.users--
	if entry.users == 0 && g.entries[key] == entry {
		delete(g.entries, key)
	}
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
	bindings         GoogleBindingStore
	config           ProvisionerConfig
	provisioningGate googleProvisioningGate
}

// NewProvisioner builds a default-off account provisioner.
func NewProvisioner(
	client provisioningClient,
	bindings GoogleBindingStore,
	config ProvisionerConfig,
) *Provisioner {
	return newProvisioner(client, googleIDTokenVerifier{}, bindings, config)
}

func newProvisioner(
	client provisioningClient,
	identityVerifier googleIdentityVerifier,
	bindings GoogleBindingStore,
	config ProvisionerConfig,
) *Provisioner {
	config.NakamaIdentityKey = bytes.Clone(config.NakamaIdentityKey)
	return &Provisioner{
		client:           client,
		sessionVerifier:  NewVerifier(client),
		identityVerifier: identityVerifier,
		bindings:         bindings,
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

func googleBindingKey(key []byte, subject string) string {
	binding := googleNakamaHMAC(key, "binding", subject)
	return hex.EncodeToString(binding)
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

func sanitizedGoogleBindingError(operation string, err error) error {
	switch {
	case errors.Is(err, context.Canceled) || status.Code(err) == codes.Canceled:
		return status.Error(
			codes.Canceled,
			"nakama auth: Google identity binding "+operation+" canceled",
		)
	case errors.Is(err, context.DeadlineExceeded) ||
		status.Code(err) == codes.DeadlineExceeded:
		return status.Error(
			codes.DeadlineExceeded,
			"nakama auth: Google identity binding "+operation+" deadline exceeded",
		)
	case status.Code(err) == codes.Unavailable:
		return status.Error(
			codes.Unavailable,
			"nakama auth: Google identity binding "+operation+" unavailable",
		)
	case status.Code(err) == codes.PermissionDenied:
		return status.Error(
			codes.PermissionDenied,
			"nakama auth: Google-bound account is disabled",
		)
	default:
		return status.Error(
			codes.Internal,
			"nakama auth: Google identity binding "+operation+" failed",
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

func (p *Provisioner) resolveGoogleBinding(
	ctx context.Context,
	bindingKey string,
) (string, bool, error) {
	boundUserID, found, err := p.bindings.ResolveGoogleBinding(ctx, bindingKey)
	if err != nil {
		return "", false, sanitizedGoogleBindingError("lookup", err)
	}
	if !found {
		return "", false, nil
	}
	if boundUserID == "" {
		return "", false, status.Error(
			codes.Internal,
			"nakama auth: Google identity binding has no user ID",
		)
	}
	if err := p.bindings.VerifyGoogleBoundAccount(ctx, boundUserID); err != nil {
		return "", false, sanitizedGoogleBindingError("account check", err)
	}
	return boundUserID, true, nil
}

func (p *Provisioner) waitForGoogleBinding(
	ctx context.Context,
	bindingKey string,
) (string, bool, error) {
	retry := time.NewTicker(googleBindingReconcileInterval)
	defer retry.Stop()
	deadline := time.NewTimer(googleBindingReconcileWindow)
	defer deadline.Stop()

	for {
		boundUserID, found, err := p.resolveGoogleBinding(ctx, bindingKey)
		if err != nil || found {
			return boundUserID, found, err
		}
		select {
		case <-ctx.Done():
			return "", false, sanitizedGoogleBindingError("lookup", ctx.Err())
		case <-deadline.C:
			return "", false, nil
		case <-retry.C:
		}
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
	if len(p.config.NakamaIdentityKey) < 32 {
		return "", errors.New("nakama auth: Nakama identity key must be at least 32 bytes")
	}
	if p.client == nil {
		return "", errors.New("nakama auth: Nakama client is nil")
	}
	if p.bindings == nil {
		return "", errors.New("nakama auth: Google binding store is nil")
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

	bindingCtx := outgoingContextWithoutAuthorization(ctx)
	bindingKey := googleBindingKey(p.config.NakamaIdentityKey, subject)
	boundUserID, found, err := p.resolveGoogleBinding(bindingCtx, bindingKey)
	if err != nil {
		return "", err
	}
	if found {
		return boundUserID, nil
	}

	// Nakama's optional single-session mode revokes the previous token when a
	// second authentication succeeds. Serialize the absent-binding path per
	// opaque identity key so one in-process first sign-in can authenticate,
	// verify, and publish the durable winner before another issues a token.
	release, err := p.provisioningGate.acquire(bindingCtx, bindingKey)
	if err != nil {
		return "", sanitizedGoogleBindingError("lookup", err)
	}
	defer release()

	// Another request may have published the binding while this request waited.
	boundUserID, found, err = p.resolveGoogleBinding(bindingCtx, bindingKey)
	if err != nil {
		return "", err
	}
	if found {
		return boundUserID, nil
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

	candidateUserID, err := p.sessionVerifier.VerifySession(ctx, session.GetToken())
	if err != nil {
		if status.Code(err) == codes.Unauthenticated {
			// A first sign-in on another replica can revoke this session before
			// verification when Nakama single-session mode is enabled. That
			// concurrent winner has the same derived identity and publishes the
			// authoritative binding; wait briefly for it instead of returning a
			// transient failure from this replica.
			reconciledUserID, found, reconcileErr := p.waitForGoogleBinding(
				bindingCtx,
				bindingKey,
			)
			if reconcileErr != nil {
				return "", reconcileErr
			}
			if found {
				return reconciledUserID, nil
			}
		}
		return "", err
	}
	boundUserID, err = p.bindings.BindGoogleIdentity(
		bindingCtx,
		bindingKey,
		candidateUserID,
	)
	if err != nil {
		return "", sanitizedGoogleBindingError("write", err)
	}
	if boundUserID == "" {
		return "", status.Error(
			codes.Internal,
			"nakama auth: Google identity binding write returned no user ID",
		)
	}
	if err := p.bindings.VerifyGoogleBoundAccount(bindingCtx, boundUserID); err != nil {
		return "", sanitizedGoogleBindingError("account check", err)
	}
	return boundUserID, nil
}
