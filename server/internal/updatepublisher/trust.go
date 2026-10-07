package updatepublisher

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const Algorithm = "ecdsa-p256-sha256"

// ParsePrivateKey accepts one unencrypted P-256 key without echoing private bytes.
func ParsePrivateKey(raw []byte) (*ecdsa.PrivateKey, error) {
	block, rest := pem.Decode(raw)
	if block == nil || len(bytes.TrimSpace(rest)) != 0 || len(block.Headers) != 0 {
		return nil, errors.New("private key must be one unencrypted P-256 PEM")
	}
	var k *ecdsa.PrivateKey
	switch block.Type {
	case "PRIVATE KEY":
		v, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			return nil, errors.New("invalid private key")
		}
		var ok bool
		k, ok = v.(*ecdsa.PrivateKey)
		if !ok {
			return nil, errors.New("private key is not P-256")
		}
	case "EC PRIVATE KEY":
		var err error
		k, err = x509.ParseECPrivateKey(block.Bytes)
		if err != nil {
			return nil, errors.New("invalid private key")
		}
	default:
		return nil, errors.New("unsupported private key encoding")
	}
	if k.Curve != elliptic.P256() {
		return nil, errors.New("private key is not P-256")
	}
	return k, nil
}

// ParsePublicKey requires a single P-256 SubjectPublicKeyInfo PEM block.
func ParsePublicKey(raw []byte) (*ecdsa.PublicKey, error) {
	block, rest := pem.Decode(raw)
	if block == nil || block.Type != "PUBLIC KEY" || len(block.Headers) != 0 || len(bytes.TrimSpace(rest)) != 0 || !bytes.HasPrefix(bytes.TrimSpace(raw), []byte("-----BEGIN PUBLIC KEY-----")) {
		return nil, errors.New("public key must be one P-256 SubjectPublicKeyInfo PEM")
	}
	v, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, errors.New("invalid public key")
	}
	k, ok := v.(*ecdsa.PublicKey)
	if !ok || k.Curve != elliptic.P256() {
		return nil, errors.New("public key is not P-256")
	}
	return k, nil
}

// SignDocument root-signs a validated certificate, revocation list or fresh head.
func SignDocument(kind string, raw []byte, key *ecdsa.PrivateKey, at time.Time) ([]byte, error) {
	if key == nil || key.Curve != elliptic.P256() {
		return nil, errors.New("signer must be P-256")
	}
	doc, err := object(raw)
	if err != nil {
		return nil, err
	}
	if err := validateDocument(kind, doc, at); err != nil {
		return nil, err
	}
	if err := issuanceBudget(kind, doc, at); err != nil {
		return nil, err
	}
	if _, exists := doc["root_signature"]; exists {
		return nil, errors.New("refusing to replace an existing signature")
	}
	return signObject(doc, "root_signature", key)
}

// signObject signs canonical unsigned fields using standard DER P-256 signatures.
func signObject(doc map[string]any, field string, key *ecdsa.PrivateKey) ([]byte, error) {
	payload, err := encode(doc)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(payload)
	sig, err := ecdsa.SignASN1(rand.Reader, key, sum[:])
	if err != nil {
		return nil, errors.New("document signing failed")
	}
	doc[field] = base64.StdEncoding.EncodeToString(sig)
	return encode(doc)
}

// VerifyDocument independently authenticates root-signed fields and their validity.
func VerifyDocument(kind string, raw []byte, key *ecdsa.PublicKey, at time.Time) error {
	doc, err := object(raw)
	if err != nil {
		return err
	}
	if err := verifyObject(doc, "root_signature", key); err != nil {
		return err
	}
	return validateDocument(kind, doc, at)
}

// validateDocument enforces each public document's supported field shape.
func validateDocument(kind string, d map[string]any, at time.Time) error {
	if at.IsZero() {
		return errors.New("explicit observation time is required")
	}
	switch kind {
	case "certificate":
		if err := fields(d, "algorithm", "public_key", "id", "epoch", "not_before", "not_after"); err != nil {
			return err
		}
		if d["algorithm"] != Algorithm || !identifier(d["id"]) || !integerAtLeast(d["epoch"], 1) {
			return errors.New("certificate algorithm, id or epoch is invalid")
		}
		pub, ok := d["public_key"].(string)
		if !ok {
			return errors.New("certificate public key is missing")
		}
		if _, err := ParsePublicKey([]byte(pub)); err != nil {
			return err
		}
		before, err := timestamp(d["not_before"])
		if err != nil {
			return err
		}
		after, err := timestamp(d["not_after"])
		if err != nil {
			return err
		}
		if !before.Before(after) || at.Before(before) || !at.Before(after) {
			return errors.New("certificate window is invalid or expired")
		}
	case "revocation":
		if err := fields(d, "version", "head_url", "revoked_ids"); err != nil {
			return err
		}
		if !integerAtLeast(d["version"], 0) || !endpoint(d["head_url"]) {
			return errors.New("revocation version or endpoint is invalid")
		}
		ids, ok := d["revoked_ids"].([]any)
		if !ok {
			return errors.New("revocation ids must be an array")
		}
		seen := map[string]bool{}
		for _, value := range ids {
			id, ok := value.(string)
			if !ok || !identifier(id) || seen[id] {
				return errors.New("revocation ids must be unique nonempty identifiers")
			}
			seen[id] = true
		}
	case "head":
		if err := fields(d, "head_url", "version_floor", "not_after"); err != nil {
			return err
		}
		expiry, err := timestamp(d["not_after"])
		if err != nil {
			return err
		}
		if !integerAtLeast(d["version_floor"], 0) || !endpoint(d["head_url"]) || !at.Before(expiry) {
			return errors.New("head endpoint, floor or expiry is invalid")
		}
	default:
		return errors.New("unsupported document kind")
	}
	return nil
}

// fields refuses missing or unsupported members before they can be root-signed.
func fields(d map[string]any, names ...string) error {
	allowed := map[string]bool{"root_signature": true}
	for _, name := range names {
		allowed[name] = true
		if _, ok := d[name]; !ok {
			return errors.New("document is missing a required field")
		}
	}
	for name := range d {
		if !allowed[name] {
			return errors.New("document contains an unsupported field")
		}
	}
	return nil
}

// identifier restricts key identifiers to bounded, unambiguous strings.
func identifier(v any) bool {
	s, ok := v.(string)
	return ok && s != "" && len(s) <= 128 && strings.TrimSpace(s) == s
}

// integerAtLeast checks parsed integers without converting through floats.
func integerAtLeast(v any, min int64) bool {
	n, ok := v.(json.Number)
	if !ok {
		return false
	}
	i, err := strconv.ParseInt(string(n), 10, 64)
	return err == nil && i >= min
}

// endpoint requires explicit HTTPS resources without credentials or query state.
func endpoint(v any) bool {
	s, ok := v.(string)
	if !ok {
		return false
	}
	u, err := url.Parse(s)
	return err == nil && u.Scheme == "https" && u.Hostname() != "" && u.User == nil && u.RawQuery == "" && u.Fragment == "" && u.Path != ""
}

// timestamp accepts real calendar timestamps in canonical whole-second UTC.
func timestamp(v any) (time.Time, error) {
	s, ok := v.(string)
	if !ok || len(s) != 20 {
		return time.Time{}, errors.New("timestamp must be canonical UTC")
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil || t.UTC().Format(time.RFC3339) != s {
		return time.Time{}, errors.New("timestamp must be canonical UTC")
	}
	return t, nil
}

// verifyObject authenticates unsigned members with canonical signature encoding.
func verifyObject(doc map[string]any, field string, key *ecdsa.PublicKey) error {
	if key == nil || key.Curve != elliptic.P256() {
		return errors.New("trusted root must be P-256")
	}
	s, ok := doc[field].(string)
	if !ok {
		return errors.New("document signature is missing")
	}
	sig, err := base64.StdEncoding.Strict().DecodeString(s)
	if err != nil || base64.StdEncoding.EncodeToString(sig) != s {
		return errors.New("signature is not canonical base64")
	}
	unsigned := make(map[string]any, len(doc))
	for k, v := range doc {
		if k != field {
			unsigned[k] = v
		}
	}
	payload, err := encode(unsigned)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(payload)
	if !ecdsa.VerifyASN1(key, sum[:], sig) {
		return errors.New("document signature did not verify")
	}
	return nil
}

// checkChain binds a certified leaf to authenticated revocation and independent freshness.
func checkChain(cert, rev, h map[string]any, root *ecdsa.PublicKey, at time.Time) (*ecdsa.PublicKey, error) {
	for _, part := range []struct {
		kind string
		doc  map[string]any
	}{{"certificate", cert}, {"revocation", rev}, {"head", h}} {
		if err := verifyObject(part.doc, "root_signature", root); err != nil {
			return nil, err
		}
		if err := validateDocument(part.kind, part.doc, at); err != nil {
			return nil, err
		}
	}
	if rev["head_url"] != h["head_url"] {
		return nil, errors.New("independent head belongs to another endpoint")
	}
	floor, ok := h["version_floor"].(json.Number)
	if !ok {
		return nil, errors.New("head floor is missing")
	}
	version, ok := rev["version"].(json.Number)
	if !ok {
		return nil, errors.New("revocation version is missing")
	}
	f, err := strconv.ParseInt(string(floor), 10, 64)
	if err != nil {
		return nil, errors.New("invalid floor")
	}
	v, err := strconv.ParseInt(string(version), 10, 64)
	if err != nil || v < f {
		return nil, errors.New("embedded revocation is below the independent floor")
	}
	ids, ok := rev["revoked_ids"].([]any)
	if !ok {
		return nil, errors.New("revocation ids missing")
	}
	for _, id := range ids {
		if id == cert["id"] {
			return nil, errors.New("signing key is revoked")
		}
	}
	pub, ok := cert["public_key"].(string)
	if !ok {
		return nil, errors.New("certificate key missing")
	}
	return ParsePublicKey([]byte(pub))
}

// Assemble issues a bounded-lived manifest for a valid, unrevoked certified leaf.
func Assemble(facts, certificate, revocation, headRaw []byte, root *ecdsa.PublicKey, leaf *ecdsa.PrivateKey, at time.Time) ([]byte, error) {
	m, err := object(facts)
	if err != nil {
		return nil, err
	}
	for _, field := range []string{"signature", "key", "revocation", "key_epoch"} {
		if _, ok := m[field]; ok {
			return nil, errors.New("build facts already carry trust fields")
		}
	}
	cert, err := object(certificate)
	if err != nil {
		return nil, err
	}
	rev, err := object(revocation)
	if err != nil {
		return nil, err
	}
	h, err := object(headRaw)
	if err != nil {
		return nil, err
	}
	pub, err := checkChain(cert, rev, h, root, at)
	if err != nil {
		return nil, err
	}
	if leaf == nil || leaf.Curve != elliptic.P256() || !pub.Equal(&leaf.PublicKey) {
		return nil, errors.New("signer does not own the certified leaf key")
	}
	m["key"] = cert
	m["revocation"] = rev
	m["key_epoch"] = cert["epoch"]
	if err := validateManifest(m, at); err != nil {
		return nil, err
	}
	if err := issuanceBudget("manifest", m, at); err != nil {
		return nil, err
	}
	out, err := signObject(m, "signature", leaf)
	if err != nil {
		return nil, err
	}
	if err := VerifyBundle(out, headRaw, root, at); err != nil {
		return nil, err
	}
	return out, nil
}

// VerifyBundle rechecks exact signed bytes against a separately obtained trusted head.
func VerifyBundle(raw, headRaw []byte, root *ecdsa.PublicKey, at time.Time) error {
	m, err := object(raw)
	if err != nil {
		return err
	}
	h, err := object(headRaw)
	if err != nil {
		return err
	}
	cert, ok := m["key"].(map[string]any)
	if !ok {
		return errors.New("manifest certificate is missing")
	}
	rev, ok := m["revocation"].(map[string]any)
	if !ok {
		return errors.New("manifest revocation is missing")
	}
	pub, err := checkChain(cert, rev, h, root, at)
	if err != nil {
		return err
	}
	if err := verifyObject(m, "signature", pub); err != nil {
		return err
	}
	return validateManifest(m, at)
}

// validateManifest checks authenticity facts; the client decides install eligibility.
func validateManifest(m map[string]any, at time.Time) error {
	if m["channel"] != "live" || m["schema"] != json.Number("1") || !integerAtLeast(m["sequence"], 0) {
		return errors.New("manifest channel, schema or sequence is invalid")
	}
	expiry, err := timestamp(m["not_after"])
	if err != nil {
		return err
	}
	if !at.Before(expiry) {
		return errors.New("manifest is expired")
	}
	cert, ok := m["key"].(map[string]any)
	if !ok {
		return errors.New("manifest certificate is missing")
	}
	if m["key_epoch"] != cert["epoch"] {
		return errors.New("manifest epoch disagrees with its certificate")
	}
	for _, field := range []string{"shell", "pack", "protocol", "save_schema"} {
		if _, ok := m[field].(map[string]any); !ok {
			return errors.New("manifest build facts are incomplete")
		}
	}
	if catalog, exists := m["rollback_targets"]; exists {
		if _, ok := catalog.([]any); !ok {
			return errors.New("manifest rollback catalog is invalid")
		}
	}
	return nil
}
