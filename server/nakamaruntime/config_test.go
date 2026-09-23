package nakamaruntime

import (
	"maps"
	"strings"
	"testing"
	"time"
)

func validEnvironment() map[string]string {
	return map[string]string{
		"WAR_HANDOFF_ENABLED":             "true",
		"WAR_HANDOFF_ALLOCATOR_ADDRESS":   "allocator.example:443",
		"WAR_HANDOFF_ALLOCATOR_CA_FILE":   "/keys/ca.pem",
		"WAR_HANDOFF_ALLOCATOR_CERT_FILE": "/keys/client.pem",
		"WAR_HANDOFF_ALLOCATOR_KEY_FILE":  "/keys/client-key.pem",
		"WAR_HANDOFF_UNWRAP_KEYS":         `["/keys/current.pem","/keys/retained.pem"]`,
		"WAR_HANDOFF_NAMESPACE":           "world-at-ruin",
		"WAR_HANDOFF_FLEET":               "cave",
		"WAR_HANDOFF_TLS_PORT_NAME":       "tls",
		"WAR_HANDOFF_ZONE_DOMAIN":         "zones.example",
		"WAR_HANDOFF_LEASE_TTL":           "1m",
	}
}

func TestConfigurationIsOptInAndComplete(t *testing.T) {
	cfg, err := readConfig(nil)
	if err != nil || cfg.enabled {
		t.Fatal("absent opt-in enabled the module")
	}
	cfg, err = readConfig(map[string]string{"WAR_HANDOFF_ENABLED": "false", "WAR_HANDOFF_UNWRAP_KEYS": "bad"})
	if err != nil || cfg.enabled {
		t.Fatal("disabled module inspected deployment configuration")
	}
	cfg, err = readConfig(validEnvironment())
	if err != nil || !cfg.enabled || cfg.leaseTTL != time.Minute || cfg.rpcTimeout != 30*time.Second || len(cfg.unwrapKeys) != 2 {
		t.Fatalf("valid configuration did not preserve explicit pool and key settings: %v", err)
	}
	for key := range validEnvironment() {
		if key == "WAR_HANDOFF_ENABLED" {
			continue
		}
		t.Run("missing "+key, func(t *testing.T) {
			env := validEnvironment()
			delete(env, key)
			if _, err := readConfig(env); err == nil {
				t.Fatal("accepted incomplete enabled configuration")
			}
		})
	}
}

func TestConfigurationRejectsMalformedValuesWithoutEchoingThem(t *testing.T) {
	for key, values := range map[string][]string{
		"WAR_HANDOFF_ENABLED":           {"TRUE", "1", "yes", "private-value"},
		"WAR_HANDOFF_ALLOCATOR_ADDRESS": {"http://allocator:443", "allocator", "allocator:0", "allocator:65536", "allocator:abc", "user@allocator:443", "allocator:443/path", "127.0.0.1:443"},
		"WAR_HANDOFF_ALLOCATOR_CA_FILE": {"relative.pem", " /keys/ca.pem"},
		"WAR_HANDOFF_UNWRAP_KEYS":       {`null`, `[]`, `["relative"]`, `["/a","/a"]`, `[null]`, `["/a"]{}`, strings.Repeat("x", 20000)},
		"WAR_HANDOFF_NAMESPACE":         {"bad/name", "Upper", strings.Repeat("a", 64)},
		"WAR_HANDOFF_FLEET":             {"bad/name", strings.Repeat("a", 64)},
		"WAR_HANDOFF_TLS_PORT_NAME":     {"bad/name", "Upper"},
		"WAR_HANDOFF_ZONE_DOMAIN":       {"https://zones.example", "bad/domain", "localhost", "127.0.0.1", "Upper.example"},
		"WAR_HANDOFF_LEASE_TTL":         {"0", "-1s", "999ms", "1s", "11m", "private-value"},
		"WAR_HANDOFF_RPC_TIMEOUT":       {"0s", "-1s", "61s", "private-value"},
	} {
		for _, value := range values {
			t.Run(key+"/"+value[:min(30, len(value))], func(t *testing.T) {
				env := maps.Clone(validEnvironment())
				env[key] = value
				_, err := readConfig(env)
				if err == nil {
					t.Fatal("accepted malformed configuration")
				}
				if strings.Contains(err.Error(), "private-value") {
					t.Fatal("configuration value escaped in error")
				}
			})
		}
	}
}
