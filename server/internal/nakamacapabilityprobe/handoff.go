//go:build war_native_trial

package nakamacapabilityprobe

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/internal/gameservercommit"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"k8s.io/client-go/rest"
)

type handoffStorage interface {
	allocatoradmission.Storage
	allocatorjournal.JournalStorage
}
type handoffPins struct {
	Binding allocatorjournal.JournalBinding `json:"binding"`
	Version string                          `json:"version"`
}
type handoffBoundary struct {
	allocatoradmission.Storage
	control, scenario string
	registered        chan struct{}
	cancel            context.CancelFunc
}

func (b *handoffBoundary) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	if len(writes) != 1 {
		return nil, errors.New("handoff probe: unexpected write")
	}
	w := writes[0]
	if w.Collection == allocatoradmission.HandoffCollection && b.scenario == "crash-after-drain" {
		if err := event(ctx, b.control, "before-publish"); err != nil {
			return nil, err
		}
	}
	acks, err := b.Storage.StorageWrite(ctx, writes)
	if err != nil {
		return acks, err
	}
	if w.Collection == allocatoradmission.HandoffCollection {
		if err = event(ctx, b.control, "published"); err != nil {
			return nil, err
		}
		if b.scenario == "lost-handoff-ack" {
			return nil, errors.New("trial handoff reply lost")
		}
		if b.scenario == "cancel-handoff-ack" {
			b.cancel()
		}
	} else if w.Version != "*" {
		var doc struct{ Phase string }
		if json.Unmarshal([]byte(w.Value), &doc) != nil {
			return nil, errors.New("handoff probe: malformed admission")
		}
		switch doc.Phase {
		case "open":
			close(b.registered)
			if err = event(ctx, b.control, "registered"); err != nil {
				return nil, err
			}
		case "draining":
			if err = event(ctx, b.control, "drained"); err != nil {
				return nil, err
			}
			if b.scenario == "lost-drain-ack" {
				return nil, errors.New("trial drain reply lost")
			}
		}
	}
	return acks, nil
}
func deliverPins(ctx context.Context, control string, pins handoffPins) error {
	raw, err := json.Marshal(pins)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, control+"/pins", bytes.NewReader(raw))
	if err != nil {
		return err
	}
	response, err := (&http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}).Do(req)
	if err != nil {
		return errors.New("handoff probe: independent pin delivery unknown")
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode != http.StatusNoContent {
		return errors.New("handoff probe: pin delivery refused")
	}
	return nil
}

// RunHandoff is a native-only diagnostic. The supervisor retains acknowledged
// pins through its owned loopback channel before killing the source and starting
// a fresh read-only process. Readback never constructs grants or receipts.
func RunHandoff(ctx context.Context, storage handoffStorage, report func(string)) error {
	env, _ := ctx.Value(runtime.RUNTIME_CTX_ENV).(map[string]string)
	flag := env["WAR_DURABLE_RECOVERY_HANDOFF_PROBE_ENABLED"]
	if flag == "" || flag == "false" {
		return nil
	}
	scenario := env["WAR_DURABLE_RECOVERY_HANDOFF_PROBE_SCENARIO"]
	if flag != "true" || report == nil {
		return errors.New("handoff probe: invalid enablement")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if scenario == "read" {
		var pins handoffPins
		decoder := json.NewDecoder(bytes.NewBufferString(env["WAR_DURABLE_RECOVERY_HANDOFF_PROBE_PINS"]))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&pins) != nil || decoder.Decode(&struct{}{}) != io.EOF {
			return errors.New("handoff probe: independent pins unavailable")
		}
		got, err := allocatoradmission.ReadHandoff(ctx, allocatoradmission.HandoffReadConfig{Enabled: true, Storage: storage, Binding: pins.Binding, Version: pins.Version})
		if err != nil {
			return errors.New("handoff probe: pinned readback unknown")
		}
		raw, err := json.Marshal(got)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(raw)
		report("read observation_sha256=" + hex.EncodeToString(digest[:]))
		return nil
	}
	if scenario != "held-put" && scenario != "late-ack" && scenario != "lost-drain-ack" && scenario != "lost-handoff-ack" && scenario != "cancel-handoff-ack" && scenario != "crash-after-drain" && scenario != "competing-handoff" {
		return errors.New("handoff probe: invalid scenario")
	}
	control := env["WAR_DURABLE_RECOVERY_HANDOFF_PROBE_CONTROL"]
	path := env["WAR_DURABLE_RECOVERY_HANDOFF_PROBE_MATERIAL"]
	if !localEndpoint(control) || !filepath.IsAbs(path) {
		return errors.New("handoff probe: private fixture inputs required")
	}
	root, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		return errors.New("handoff probe: material directory unavailable")
	}
	defer func() { _ = root.Close() }()
	file, err := root.Open(filepath.Base(path))
	if err != nil {
		return errors.New("handoff probe: material unavailable")
	}
	defer func() { _ = file.Close() }()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || info.Size() > 64<<10 {
		return errors.New("handoff probe: private bounded material required")
	}
	var m material
	decoder := json.NewDecoder(io.LimitReader(file, 64<<10))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&m) != nil || decoder.Decode(&struct{}{}) != io.EOF || !localEndpoint(m.Host) {
		return errors.New("handoff probe: invalid material")
	}
	b := &handoffBoundary{Storage: storage, control: control, scenario: scenario, registered: make(chan struct{}), cancel: cancel}
	g, err := gameservercommit.NewDurableGeneration(ctx, gameservercommit.DurableGenerationConfig{Enabled: true, Storage: b, IncarnationID: "native-incarnation",
		Record: nakamageneration.Record{GenerationID: "generation-1", Version: "source-version-1", State: "open", MemberPodUIDs: []string{"pod-a", "pod-b"}, MemberSetDigest: "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d"},
		Commit: gameservercommit.Config{Namespace: "trial", Fleet: "fleet", REST: &rest.Config{Host: m.Host, TLSClientConfig: rest.TLSClientConfig{CAData: m.CA, CertData: m.Cert, KeyData: m.Key}, Timeout: 10 * time.Second}}})
	if err != nil {
		return errors.New("handoff probe: creation unknown")
	}
	type prepared struct {
		grant gameservercommit.GenerationGrant
		err   error
	}
	prep := make(chan prepared, 1)
	go func() { grant, e := g.Prepare(ctx, "pod-a", "zone-a", "attempt-original"); prep <- prepared{grant, e} }()
	select {
	case <-b.registered:
	case <-ctx.Done():
		return errors.New("handoff probe: registration delayed")
	}
	type closed struct {
		pins handoffPins
		err  error
	}
	done := make(chan closed, 1)
	var commits chan error
	closeOwner := func() {
		binding, version, e := g.CloseForRecovery(ctx)
		done <- closed{handoffPins{binding, version}, e}
	}
	if scenario == "late-ack" {
		go closeOwner()
		ticker := time.NewTicker(time.Millisecond)
		defer ticker.Stop()
		for {
			_, e := g.Prepare(ctx, "non-member", "unused", "attempt-unused")
			if errors.Is(e, gameservercommit.ErrClosed) {
				break
			}
			if !errors.Is(e, gameservercommit.ErrInvalid) {
				return errors.New("handoff probe: closure unknown")
			}
			select {
			case <-ticker.C:
			case <-ctx.Done():
				return errors.New("handoff probe: closure delayed")
			}
		}
		if err = event(ctx, control, "closing"); err != nil {
			return err
		}
		if p := <-prep; !errors.Is(p.err, gameservercommit.ErrClosed) {
			return errors.New("handoff probe: late grant exposed")
		}
	} else {
		p := <-prep
		if p.err != nil {
			return errors.New("handoff probe: preparation unknown")
		}
		if scenario == "held-put" {
			if err = event(ctx, control, "exposed"); err != nil {
				return err
			}
			// The parent captures and holds this exact old write. It may survive source
			// termination in the API proxy; the handoff never attempts a storage barrier.
			commits = make(chan error, 1)
			go func() { commits <- p.grant.Commit(ctx) }()
			if err = event(ctx, control, "close"); err != nil {
				return err
			}
		}
		go closeOwner()
	}
	result := <-done
	if scenario == "lost-drain-ack" || scenario == "lost-handoff-ack" || scenario == "cancel-handoff-ack" || scenario == "competing-handoff" {
		if !errors.Is(result.err, gameservercommit.ErrUnknown) || result.pins.Version != "" || result.pins.Binding.Version != "" {
			return errors.New("handoff probe: ambiguous pins exported")
		}
		if _, version, e := g.CloseForRecovery(context.WithoutCancel(ctx)); version != "" || !errors.Is(e, gameservercommit.ErrClosed) {
			return errors.New("handoff probe: ambiguous closure retried")
		}
		if err = event(context.WithoutCancel(ctx), control, "unknown"); err != nil {
			return err
		}
		report(scenario)
		return nil
	}
	if result.err != nil {
		return errors.New("handoff probe: publication unknown")
	}
	if _, err = g.Fence(ctx); !errors.Is(err, gameservercommit.ErrClosed) {
		return errors.New("handoff probe: handoff restored barrier authority")
	}
	if _, err = g.Accept(gameservercommit.GenerationReceipt{}); err == nil {
		return errors.New("handoff probe: handoff restored receipt")
	}
	if err = deliverPins(ctx, control, result.pins); err != nil {
		return err
	}
	if err = event(ctx, control, "handoff"); err != nil {
		return err
	}
	if commits != nil {
		select {
		case err = <-commits:
			if err != nil {
				return errors.New("handoff probe: unfenced original commit unknown")
			}
		case <-ctx.Done():
			return errors.New("handoff probe: original commit did not settle")
		}
	}
	report(scenario)
	return nil
}
