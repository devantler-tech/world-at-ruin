package allocatorpeer

import (
	"bytes"
	"crypto"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
)

func staticTLS(input Credentials) (*tls.Config, error) {
	if len(input.RootDER) == 0 || len(input.RootDER) > 16 || len(input.CertificateDER) == 0 || len(input.CertificateDER) > 8 || len(input.PrivateKeyDER) == 0 || len(input.PrivateKeyDER) > 16384 {
		return nil, ErrInvalidArgument
	}
	roots := x509.NewCertPool()
	for _, der := range input.RootDER {
		if len(der) == 0 || len(der) > 65536 {
			return nil, ErrInvalidArgument
		}
		cert, err := x509.ParseCertificate(bytes.Clone(der))
		if err != nil || !cert.IsCA {
			return nil, ErrInvalidArgument
		}
		roots.AddCert(cert)
	}
	chain := make([][]byte, len(input.CertificateDER))
	for index, der := range input.CertificateDER {
		if len(der) == 0 || len(der) > 65536 {
			return nil, ErrInvalidArgument
		}
		chain[index] = bytes.Clone(der)
		if _, err := x509.ParseCertificate(chain[index]); err != nil {
			return nil, ErrInvalidArgument
		}
	}
	privateKey, err := x509.ParsePKCS8PrivateKey(bytes.Clone(input.PrivateKeyDER))
	if err != nil {
		return nil, ErrInvalidArgument
	}
	signer, ok := privateKey.(crypto.Signer)
	if !ok {
		return nil, ErrInvalidArgument
	}
	leaf, err := x509.ParseCertificate(chain[0])
	if err != nil {
		return nil, ErrInvalidArgument
	}
	publicKey, err := x509.MarshalPKIXPublicKey(signer.Public())
	if err != nil || !bytes.Equal(publicKey, leaf.RawSubjectPublicKeyInfo) {
		return nil, ErrInvalidArgument
	}
	return &tls.Config{RootCAs: roots, Certificates: []tls.Certificate{{Certificate: chain, PrivateKey: privateKey, Leaf: leaf}}, MinVersion: tls.VersionTLS13}, nil
}

func verifyPeer(expected [32]byte) func(tls.ConnectionState) error {
	return func(state tls.ConnectionState) error {
		if len(state.VerifiedChains) == 0 || len(state.PeerCertificates) == 0 || sha256.Sum256(state.PeerCertificates[0].RawSubjectPublicKeyInfo) != expected {
			return ErrConnection
		}
		return nil
	}
}
