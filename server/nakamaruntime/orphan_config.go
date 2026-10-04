package nakamaruntime

import (
	"strconv"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/orphanreaper"
)

// orphanConfig is an independent opt-in under the handoff module. Its scope is
// inherited from the module, never supplied through separate cleanup settings.
type orphanConfig struct {
	enabled  bool
	settings orphanreaper.Config
}

func readOrphanConfig(env map[string]string) (orphanConfig, error) {
	var cfg orphanConfig
	switch env["WAR_HANDOFF_ORPHANS_ENABLED"] {
	case "", "false":
		return cfg, nil
	case "true":
		cfg.enabled = true
	default:
		return orphanConfig{}, invalidConfig("WAR_HANDOFF_ORPHANS_ENABLED")
	}
	cfg.settings = orphanreaper.Config{Grace: 2 * time.Minute, Interval: 30 * time.Second, SweepTimeout: 30 * time.Second, MaxPages: 100}
	for _, setting := range []struct {
		name             string
		target           *time.Duration
		minimum, maximum time.Duration
	}{
		{"WAR_HANDOFF_ORPHANS_GRACE", &cfg.settings.Grace, 30 * time.Second, time.Hour},
		{"WAR_HANDOFF_ORPHANS_INTERVAL", &cfg.settings.Interval, time.Second, time.Hour},
		{"WAR_HANDOFF_ORPHANS_TIMEOUT", &cfg.settings.SweepTimeout, time.Millisecond, time.Minute},
	} {
		if value, supplied := env[setting.name]; supplied {
			parsed, err := time.ParseDuration(value)
			if err != nil || parsed < setting.minimum || parsed > setting.maximum {
				return orphanConfig{}, invalidConfig(setting.name)
			}
			*setting.target = parsed
		}
	}
	if value, supplied := env["WAR_HANDOFF_ORPHANS_MAX_PAGES"]; supplied {
		pages, err := strconv.Atoi(value)
		if err != nil || pages < 1 || pages > 1000 || strconv.Itoa(pages) != value {
			return orphanConfig{}, invalidConfig("WAR_HANDOFF_ORPHANS_MAX_PAGES")
		}
		cfg.settings.MaxPages = pages
	}
	return cfg, nil
}
