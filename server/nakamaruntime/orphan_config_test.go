package nakamaruntime

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/orphanreaper"
)

// Refusing enabled malformed settings before connect avoids acquiring credentials
// or starting any mutation-capable component for an invalid cleanup contract.
func TestOrphanConfigurationRefusesBeforeConnecting(t *testing.T) {
	for name, values := range map[string][]string{
		"WAR_HANDOFF_ORPHANS_ENABLED":   {"TRUE", "1", "private-value"},
		"WAR_HANDOFF_ORPHANS_GRACE":     {"0s", "29s", "61m", "private-value"},
		"WAR_HANDOFF_ORPHANS_INTERVAL":  {"0s", "999ms", "61m", "private-value"},
		"WAR_HANDOFF_ORPHANS_TIMEOUT":   {"0s", "999us", "61s", "private-value"},
		"WAR_HANDOFF_ORPHANS_MAX_PAGES": {"0", "1001", "-1", "+2", "02", " 2", "private-value"},
	} {
		for _, value := range values {
			t.Run(name+"/"+value, func(t *testing.T) {
				env := validEnvironment()
				env["WAR_HANDOFF_ORPHANS_ENABLED"] = "true"
				env[name] = value
				connects := 0
				err := initialize(environmentContext(env), nil, nil, func(config) (dependencies, error) {
					connects++
					return dependencies{}, errors.New("connection must not be reached")
				})
				// readConfig must classify the error before the existing dependency check.
				if err == nil || !strings.Contains(err.Error(), "invalid "+name) || connects != 0 {
					t.Fatalf("malformed cleanup contract was not refused first: err=%v connects=%d", err, connects)
				}
				if strings.Contains(err.Error(), "private-value") {
					t.Fatal("configuration content leaked")
				}
			})
		}
	}
}

func TestOrphanConfigurationDefaultsAndSupportedBudgetEdges(t *testing.T) {
	for _, test := range []struct {
		name   string
		values map[string]string
		want   orphanreaper.Config
	}{
		{"defaults", nil, orphanreaper.Config{Grace: 2 * time.Minute, Interval: 30 * time.Second, SweepTimeout: 30 * time.Second, MaxPages: 100}},
		{"minimum", map[string]string{"WAR_HANDOFF_ORPHANS_GRACE": "30s", "WAR_HANDOFF_ORPHANS_INTERVAL": "1s", "WAR_HANDOFF_ORPHANS_TIMEOUT": "1ms", "WAR_HANDOFF_ORPHANS_MAX_PAGES": "1"}, orphanreaper.Config{Grace: 30 * time.Second, Interval: time.Second, SweepTimeout: time.Millisecond, MaxPages: 1}},
		{"maximum", map[string]string{"WAR_HANDOFF_ORPHANS_GRACE": "1h", "WAR_HANDOFF_ORPHANS_INTERVAL": "1h", "WAR_HANDOFF_ORPHANS_TIMEOUT": "1m", "WAR_HANDOFF_ORPHANS_MAX_PAGES": "1000"}, orphanreaper.Config{Grace: time.Hour, Interval: time.Hour, SweepTimeout: time.Minute, MaxPages: 1000}},
	} {
		t.Run(test.name, func(t *testing.T) {
			env := validEnvironment()
			env["WAR_HANDOFF_ORPHANS_ENABLED"] = "true"
			for name, value := range test.values {
				env[name] = value
			}
			cfg, err := readConfig(env)
			if err != nil || !cfg.orphans.enabled || cfg.orphans.settings != test.want {
				t.Fatalf("supported cleanup budget changed: settings=%+v err=%v", cfg.orphans.settings, err)
			}
		})
	}
}

func TestDisabledOrphanConfigurationIsInert(t *testing.T) {
	for _, enabled := range []string{"", "false"} {
		env := validEnvironment()
		env["WAR_HANDOFF_ORPHANS_ENABLED"] = enabled
		env["WAR_HANDOFF_ORPHANS_GRACE"] = "private-value"
		if _, err := readConfig(env); err != nil {
			t.Fatal("disabled cleanup consumed deployment settings")
		}
	}
	if err := Initialize(environmentContext(map[string]string{"WAR_HANDOFF_ORPHANS_ENABLED": "true"}), nil, nil); err != nil {
		t.Fatal("orphan opt-in enabled the disabled handoff module")
	}
}
