// Package nakamajournalprobe provides an explicitly enabled, read-only startup
// observation. It cannot seed journals, mutate allocation state or restore authority.
package nakamajournalprobe

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/heroiclabs/nakama-common/runtime"
)

// Report contains only an aggregate fingerprint of a complete observation.
type Report struct {
	ObservationSHA256 string
	GrantCount        int
}

// Run reads fixed operator expectations from runtime.env, never from the object.
// Absent/false enablement returns before examining dependencies or subsettings.
func Run(ctx context.Context, storage allocatorjournal.JournalStorage, report func(Report)) error {
	env, _ := ctx.Value(runtime.RUNTIME_CTX_ENV).(map[string]string)
	flag := env["WAR_ALLOCATOR_JOURNAL_PROBE_ENABLED"]
	if flag == "" || flag == "false" {
		return nil
	}
	if flag != "true" {
		return errors.New("journal probe: invalid enablement")
	}
	value := env["WAR_ALLOCATOR_JOURNAL_PROBE_BINDING"]
	if len(value) == 0 || len(value) > 16384 || report == nil {
		return errors.New("journal probe: invalid expectations")
	}
	var binding allocatorjournal.JournalBinding
	d := json.NewDecoder(strings.NewReader(value))
	d.DisallowUnknownFields()
	if d.Decode(&binding) != nil || d.Decode(&struct{}{}) != io.EOF {
		return errors.New("journal probe: invalid expectations")
	}
	reader, err := allocatorjournal.NewJournalReader(allocatorjournal.JournalReaderConfig{Enabled: true, Storage: storage, Binding: binding})
	if err != nil {
		return errors.New("journal probe: invalid expectations")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// This explicit control belongs only to the read experiment. It cannot cancel
	// handoff initialization or alter Nakama's parent initialization context.
	switch env["WAR_ALLOCATOR_JOURNAL_PROBE_CANCEL_READ"] {
	case "", "false":
	case "true":
		cancel()
	default:
		return errors.New("journal probe: invalid read control")
	}
	got, err := reader.Load(ctx)
	if err != nil {
		return errors.New("journal probe: observation remains unknown")
	}
	encoded, err := json.Marshal(got)
	if err != nil || ctx.Err() != nil {
		return errors.New("journal probe: observation remains unknown")
	}
	digest := sha256.Sum256(encoded)
	report(Report{ObservationSHA256: hex.EncodeToString(digest[:]), GrantCount: len(got.Grants)})
	return nil
}
