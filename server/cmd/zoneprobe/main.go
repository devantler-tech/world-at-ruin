// Command zoneprobe verifies an operator-only zone trial without sending
// gameplay inputs or exposing connection material in its output.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

const (
	maxCABytes = 1 << 20
	// Match the protocol's maximum legal delta, including both cast lists.
	maxFrameBytes = wire.MaxEntities*(2*(8+3*8+8)+8) + wire.MaxCasts*((8+1+3*8+3*8+4*8+2*8)+8) + 96
)

func main() {
	os.Exit(run(context.Background(), os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}

func run(parent context.Context, args []string, getenv func(string) string, out, errOut io.Writer) int {
	flags := flag.NewFlagSet("zoneprobe", flag.ContinueOnError)
	// flag errors include supplied values. None may reach shared CI logs.
	flags.SetOutput(io.Discard)
	target := flags.String("url", "", "verified wss zone endpoint")
	caFile := flags.String("ca-file", "", "optional PEM trust roots")
	serverName := flags.String("tls-server-name", "", "certificate DNS identity for a loopback tunnel")
	tlsOnly := flags.Bool("tls-only", false, "verify TLS listener health without admission or HTTP")
	identityFile := flags.String("tls-server-name-file", "", "TLS-only loopback identity from the configured leaf certificate")
	timeout := flags.Duration("timeout", 10*time.Second, "total probe deadline, at most one minute")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return outputResult(out, "zoneprobe -url <wss endpoint> [-tls-only] [-ca-file <PEM>] [-tls-server-name <DNS name> | -tls-server-name-file <PEM>] [-timeout 10s]")
		}
		return failure(errOut, "invalid arguments", 2)
	}
	parsed, err := url.Parse(*target)
	if err != nil || flags.NArg() != 0 || *timeout <= 0 || *timeout > time.Minute || !validTarget(parsed) {
		return failure(errOut, "invalid arguments", 2)
	}
	if *serverName != "" && (!loopbackHost(parsed.Hostname()) || !validDNSName(*serverName)) {
		return failure(errOut, "invalid TLS identity override", 2)
	}
	if *identityFile != "" {
		if !*tlsOnly || *serverName != "" || !loopbackHost(parsed.Hostname()) {
			return failure(errOut, "invalid TLS identity override", 2)
		}
		name, err := certificateDNSName(*identityFile)
		if err != nil {
			return failure(errOut, "invalid TLS identity material", 2)
		}
		*serverName = name
	}
	var token string
	if !*tlsOnly {
		token = getenv("WAR_ZONE_TOKEN")
		if token == "" || len(token) > 8192 || strings.ContainsAny(token, "\r\n\x00") {
			return failure(errOut, "WAR_ZONE_TOKEN is missing or invalid", 2)
		}
	}
	trust, err := roots(*caFile)
	if err != nil {
		return failure(errOut, "invalid CA material", 2)
	}
	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS12, RootCAs: trust, ServerName: *serverName,
	}
	ctx, cancel := context.WithTimeout(parent, *timeout)
	defer cancel()
	if *tlsOnly {
		if err := verifyTLSHealth(ctx, parsed, tlsConfig); err != nil {
			return failure(errOut, "TLS health verification failed", 1)
		}
		return outputResult(out, "ZONEPROBE TLS PASS")
	}
	transport := &http.Transport{TLSClientConfig: tlsConfig}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	for _, rejected := range []string{"", wrongToken(token)} {
		if err := denied(ctx, client, *target, rejected); err != nil {
			return failure(errOut, "TLS or admission refusal verification failed", 1)
		}
	}
	frames := 0
	for _, version := range []uint16{wire.LegacyVersion, wire.Version} {
		count, err := verifyStream(ctx, client, *target, token, version)
		if err != nil {
			return failure(errOut, "stream verification failed", 1)
		}
		frames += count
		if version != wire.Version {
			// The simulation releases a closed observer on its next tick. Never
			// evict or release an existing observer to make the probe pass.
			timer := time.NewTimer(100 * time.Millisecond)
			select {
			case <-ctx.Done():
				timer.Stop()
				return failure(errOut, "probe deadline exceeded", 1)
			case <-timer.C:
			}
		}
	}
	return outputResult(out, fmt.Sprintf("ZONEPROBE PASS denied=2 protocols=%d,%d frames=%d state=advancing", wire.LegacyVersion, wire.Version, frames))
}

func verifyTLSHealth(ctx context.Context, target *url.URL, config *tls.Config) error {
	port := target.Port()
	if port == "" {
		port = "443"
	}
	raw, err := (&net.Dialer{}).DialContext(ctx, "tcp", net.JoinHostPort(target.Hostname(), port))
	if err != nil {
		return err
	}
	if config.ServerName == "" {
		config = config.Clone()
		config.ServerName = target.Hostname()
	}
	return completeTLSHealth(ctx, raw, config)
}

func completeTLSHealth(ctx context.Context, raw net.Conn, config *tls.Config) error {
	// On success TLS Close checks socket cleanup; failed handshakes already
	// fail the proof and still need their underlying connection released.
	defer func() { _ = raw.Close() }()
	// TLS Close uses its own write deadline. Close the underlying socket on
	// cancellation so close_notify cannot outlive the total probe deadline.
	stop := context.AfterFunc(ctx, func() { _ = raw.Close() })
	defer stop()
	conn := tls.Client(raw, config)
	if err := conn.HandshakeContext(ctx); err != nil {
		return err
	}
	if err := conn.Close(); err != nil {
		return err
	}
	return ctx.Err()
}

func validTarget(target *url.URL) bool {
	return target != nil && target.Scheme == "wss" && target.Hostname() != "" && target.Path == "/zone" &&
		target.User == nil && target.RawQuery == "" && !target.ForceQuery && target.Fragment == "" && target.Opaque == ""
}

func loopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func validDNSName(name string) bool {
	if len(name) > 253 || !strings.Contains(name, ".") || net.ParseIP(name) != nil {
		return false
	}
	for _, label := range strings.Split(name, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, char := range label {
			valid := char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' || char >= '0' && char <= '9' || char == '-'
			if !valid {
				return false
			}
		}
	}
	return true
}

func roots(path string) (*x509.CertPool, error) {
	if path == "" {
		return nil, nil // net/http uses the system trust roots.
	}
	certs, err := certificates(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	for _, cert := range certs {
		pool.AddCert(cert)
	}
	return pool, nil
}

func certificateDNSName(path string) (string, error) {
	certs, err := certificates(path)
	if err != nil {
		return "", err
	}
	if len(certs[0].DNSNames) != 1 || !validDNSName(certs[0].DNSNames[0]) {
		return "", errors.New("ambiguous certificate identity")
	}
	return certs[0].DNSNames[0], nil
}

func certificates(path string) ([]*x509.Certificate, error) {
	cleanPath := filepath.Clean(path)
	file, err := os.DirFS(filepath.Dir(cleanPath)).Open(filepath.Base(cleanPath))
	if err != nil {
		return nil, errors.New("CA unavailable")
	}
	data, readErr := io.ReadAll(io.LimitReader(file, maxCABytes+1))
	closeErr := file.Close()
	if readErr != nil || closeErr != nil || len(data) > maxCABytes {
		return nil, errors.New("CA read refused")
	}
	var certs []*x509.Certificate
	for len(bytes.TrimSpace(data)) > 0 {
		data = bytes.TrimSpace(data)
		if !bytes.HasPrefix(data, []byte("-----BEGIN CERTIFICATE-----")) {
			return nil, errors.New("CA PEM refused")
		}
		const endMarker = "-----END CERTIFICATE-----"
		end := bytes.Index(data, []byte(endMarker))
		if end < 0 {
			return nil, errors.New("CA PEM refused")
		}
		end += len(endMarker)
		if end < len(data) {
			lineEnd := bytes.IndexByte(data[end:], '\n')
			if lineEnd < 0 {
				lineEnd = len(data) - end
			}
			if len(bytes.TrimSpace(data[end:end+lineEnd])) != 0 {
				return nil, errors.New("CA PEM refused")
			}
			end += lineEnd
			if end < len(data) {
				end++
			}
		}
		encoded := data[:end]
		// pem.Decode scans past malformed blocks. Isolate the first block and
		// reject nested BEGIN markers so it cannot select a later certificate.
		if bytes.Count(encoded, []byte("-----BEGIN")) != 1 {
			return nil, errors.New("CA PEM refused")
		}
		block, rest := pem.Decode(encoded)
		if block == nil || len(rest) != 0 || block.Type != "CERTIFICATE" || len(block.Headers) != 0 {
			return nil, errors.New("CA PEM refused")
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, errors.New("CA certificate refused")
		}
		certs = append(certs, cert)
		data = data[end:]
	}
	if len(certs) == 0 {
		return nil, errors.New("CA is empty")
	}
	return certs, nil
}

func wrongToken(token string) string {
	const rejected = "zoneprobe-invalid-bearer"
	if token == rejected {
		return rejected + "-different"
	}
	return rejected
}

func dial(ctx context.Context, client *http.Client, target, token string, version uint16) (*websocket.Conn, *http.Response, error) {
	headers := http.Header{}
	if token != "" {
		headers.Set("Authorization", "Bearer "+token)
	}
	if version != wire.LegacyVersion {
		headers.Set(zonesock.WireVersionHeader, fmt.Sprint(version))
	}
	return websocket.Dial(ctx, target, &websocket.DialOptions{HTTPClient: client, HTTPHeader: headers})
}

func closeResponse(response *http.Response) error {
	if response != nil && response.Body != nil {
		return response.Body.Close()
	}
	return nil
}

func denied(ctx context.Context, client *http.Client, target, token string) error {
	conn, response, err := dial(ctx, client, target, token, wire.LegacyVersion)
	closeErr := closeResponse(response)
	if conn != nil {
		_ = conn.CloseNow() // Unexpected anonymous admission must not retain a socket.
		return errors.New("unexpected admission")
	}
	if err == nil || closeErr != nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		return errors.New("refusal not proven")
	}
	return nil
}

func verifyStream(ctx context.Context, client *http.Client, target, token string, version uint16) (frames int, result error) {
	conn, response, err := dial(ctx, client, target, token, version)
	if closeErr := closeResponse(response); closeErr != nil || err != nil {
		if conn != nil {
			_ = conn.CloseNow()
		}
		return 0, errors.New("connection refused")
	}
	defer func() {
		if err := conn.CloseNow(); err != nil && !errors.Is(err, net.ErrClosed) {
			result = errors.New("socket cleanup failed")
		}
	}()
	conn.SetReadLimit(maxFrameBytes)
	var tick uint64
	var observer sim.EntityID
	entities := map[sim.EntityID]sim.EntityState{}
	casts := map[sim.EntityID]sim.ActiveCast{}
	for {
		kind, data, err := conn.Read(ctx)
		if err != nil || kind != websocket.MessageBinary {
			return frames, errors.New("binary stream unavailable")
		}
		message, err := wire.Decode(data)
		if err != nil || message.Version != version {
			return frames, errors.New("wire frame refused")
		}
		var changed bool
		switch message.Kind {
		case wire.KindSnapshot:
			snapshot := message.Snapshot
			if snapshot.Observer == 0 || frames > 0 && (snapshot.Observer != observer || snapshot.Tick <= tick) {
				return frames, errors.New("snapshot continuity refused")
			}
			next := make(map[sim.EntityID]sim.EntityState, len(snapshot.Entities))
			for _, entity := range snapshot.Entities {
				if entity.ID == snapshot.Observer {
					return frames, errors.New("observer replicated")
				}
				next[entity.ID] = entity
			}
			changed = frames > 0 && !maps.Equal(entities, next)
			entities, observer, tick = next, snapshot.Observer, snapshot.Tick
			casts = make(map[sim.EntityID]sim.ActiveCast, len(snapshot.Casts))
			for _, cast := range snapshot.Casts {
				casts[cast.Caster] = cast
			}
		case wire.KindSnapshotDelta:
			if frames == 0 || message.Delta.Tick <= tick {
				return frames, errors.New("delta continuity refused")
			}
			changed, err = applyEntities(entities, observer, message.Delta)
			if err != nil {
				return frames, err
			}
			if err := applyCasts(casts, entities, message.Delta); err != nil {
				return frames, err
			}
			tick = message.Delta.Tick
		default:
			return frames, errors.New("message kind refused")
		}
		frames++
		if changed {
			return frames, nil
		}
	}
}

func applyCasts(casts map[sim.EntityID]sim.ActiveCast, entities map[sim.EntityID]sim.EntityState, delta sim.SnapshotDelta) error {
	ended := make(map[sim.EntityID]bool, len(delta.EndedCasts))
	for _, id := range delta.EndedCasts {
		if _, exists := casts[id]; !exists {
			return errors.New("invalid ended cast")
		}
		ended[id] = true
	}
	for id := range casts {
		if _, remains := entities[id]; !remains && !ended[id] {
			return errors.New("leaving entity retains cast")
		}
	}
	for _, cast := range delta.StartedCasts {
		_, present := entities[cast.Caster]
		_, active := casts[cast.Caster]
		if !present || active && !ended[cast.Caster] {
			return errors.New("invalid started cast")
		}
	}
	for id := range ended {
		delete(casts, id)
	}
	for _, cast := range delta.StartedCasts {
		casts[cast.Caster] = cast
	}
	if len(casts) > wire.MaxCasts {
		return errors.New("cast capacity refused")
	}
	return nil
}

func applyEntities(entities map[sim.EntityID]sim.EntityState, observer sim.EntityID, delta sim.SnapshotDelta) (bool, error) {
	changed := false
	for _, entity := range delta.Entered {
		if _, exists := entities[entity.ID]; exists || entity.ID == observer {
			return false, errors.New("invalid entered entity")
		}
		entities[entity.ID], changed = entity, true
	}
	for _, entity := range delta.Moved {
		previous, exists := entities[entity.ID]
		if !exists || entity.ID == observer {
			return false, errors.New("invalid moved entity")
		}
		changed = changed || previous != entity
		entities[entity.ID] = entity
	}
	for _, id := range delta.Left {
		if _, exists := entities[id]; !exists || id == observer {
			return false, errors.New("invalid leaving entity")
		}
		delete(entities, id)
		changed = true
	}
	if len(entities) > wire.MaxEntities {
		return false, errors.New("entity capacity refused")
	}
	return changed, nil
}

func failure(out io.Writer, reason string, code int) int {
	if _, err := fmt.Fprintln(out, "zoneprobe: "+reason); err != nil {
		return 1
	}
	return code
}

func outputResult(out io.Writer, message string) int {
	if _, err := fmt.Fprintln(out, message); err != nil {
		return 1
	}
	return 0
}
