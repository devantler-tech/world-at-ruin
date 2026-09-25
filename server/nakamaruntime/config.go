// Package nakamaruntime composes the opt-in Nakama handoff runtime.
package nakamaruntime

import (
	"encoding/json"
	"fmt"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"net"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type config struct {
	enabled                                                    bool
	allocatorAddress, allocatorCA, allocatorCert, allocatorKey string
	unwrapKeys                                                 []string
	namespace, fleet, tlsPort, zoneDomain                      string
	leaseTTL, rpcTimeout                                       time.Duration
	claims                                                     privateConfig
}

func readConfig(env map[string]string) (config, error) {
	var cfg config
	switch env["WAR_HANDOFF_ENABLED"] {
	case "", "false":
		return cfg, nil
	case "true":
		cfg.enabled = true
	default:
		return config{}, invalidConfig("WAR_HANDOFF_ENABLED")
	}
	cfg.allocatorAddress = env["WAR_HANDOFF_ALLOCATOR_ADDRESS"]
	host, port, err := net.SplitHostPort(cfg.allocatorAddress)
	number, portErr := strconv.ParseUint(port, 10, 16)
	if err != nil || portErr != nil || number == 0 || !handoffidentity.DNSSubdomain(host) || net.ParseIP(host) != nil {
		return config{}, invalidConfig("WAR_HANDOFF_ALLOCATOR_ADDRESS")
	}
	for name, target := range map[string]*string{
		"WAR_HANDOFF_ALLOCATOR_CA_FILE":   &cfg.allocatorCA,
		"WAR_HANDOFF_ALLOCATOR_CERT_FILE": &cfg.allocatorCert,
		"WAR_HANDOFF_ALLOCATOR_KEY_FILE":  &cfg.allocatorKey,
	} {
		*target = env[name]
		if !validPath(*target) {
			return config{}, invalidConfig(name)
		}
	}
	keys := env["WAR_HANDOFF_UNWRAP_KEYS"]
	if len(keys) > 16384 || json.Unmarshal([]byte(keys), &cfg.unwrapKeys) != nil || len(cfg.unwrapKeys) == 0 || len(cfg.unwrapKeys) > 8 {
		return config{}, invalidConfig("WAR_HANDOFF_UNWRAP_KEYS")
	}
	seen := make(map[string]bool)
	for _, path := range cfg.unwrapKeys {
		if !validPath(path) || seen[filepath.Clean(path)] {
			return config{}, invalidConfig("WAR_HANDOFF_UNWRAP_KEYS")
		}
		seen[filepath.Clean(path)] = true
	}
	cfg.namespace, cfg.fleet, cfg.tlsPort, cfg.zoneDomain = env["WAR_HANDOFF_NAMESPACE"], env["WAR_HANDOFF_FLEET"], env["WAR_HANDOFF_TLS_PORT_NAME"], env["WAR_HANDOFF_ZONE_DOMAIN"]
	for name, value := range map[string]string{"WAR_HANDOFF_NAMESPACE": cfg.namespace, "WAR_HANDOFF_TLS_PORT_NAME": cfg.tlsPort} {
		if !handoffidentity.DNSLabel(value) {
			return config{}, invalidConfig(name)
		}
	}
	if len(cfg.fleet) > 63 || !handoffidentity.DNSSubdomain(cfg.fleet) {
		return config{}, invalidConfig("WAR_HANDOFF_FLEET")
	}
	if !handoffidentity.DNSSubdomain(cfg.zoneDomain) || !strings.Contains(cfg.zoneDomain, ".") || net.ParseIP(cfg.zoneDomain) != nil {
		return config{}, invalidConfig("WAR_HANDOFF_ZONE_DOMAIN")
	}
	cfg.leaseTTL, err = time.ParseDuration(env["WAR_HANDOFF_LEASE_TTL"])
	if err != nil || cfg.leaseTTL < 2*time.Second || cfg.leaseTTL > 10*time.Minute {
		return config{}, invalidConfig("WAR_HANDOFF_LEASE_TTL")
	}
	cfg.rpcTimeout = 30 * time.Second
	if value, supplied := env["WAR_HANDOFF_RPC_TIMEOUT"]; supplied {
		cfg.rpcTimeout, err = time.ParseDuration(value)
		if err != nil || cfg.rpcTimeout < time.Second || cfg.rpcTimeout > time.Minute {
			return config{}, invalidConfig("WAR_HANDOFF_RPC_TIMEOUT")
		}
	}
	cfg.claims, err = readPrivateConfig(env)
	cfg.claims.allocatorCA, cfg.claims.allocatorCert = cfg.allocatorCA, cfg.allocatorCert
	return cfg, err
}

func validPath(path string) bool {
	return len(path) <= 4096 && filepath.IsAbs(path) && strings.TrimSpace(path) == path && !strings.ContainsRune(path, 0)
}

func invalidConfig(name string) error { return fmt.Errorf("nakama handoff: invalid %s", name) }
