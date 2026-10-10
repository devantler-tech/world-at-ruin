//go:build war_native_trial

// Package nakamacapabilityprobe joins disposable native storage and API writes.
// It is absent from ordinary builds and never exports a grant or receipt.
package nakamacapabilityprobe

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/gameservercommit"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"k8s.io/client-go/rest"
)

type material struct {
	Host          string
	CA, Cert, Key []byte
}
type boundary struct {
	allocatoradmission.Storage
	control           string
	scenario          string
	registered        chan struct{}
	registerCalls     atomic.Int32
	cancelPreparation context.CancelFunc
}

func event(ctx context.Context, control, stage string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, control+"/"+stage, nil)
	if err != nil {
		return errors.New("capability probe: invalid control")
	}
	response, err := (&http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}).Do(req)
	if err != nil {
		return errors.New("capability probe: control unknown")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return errors.New("capability probe: control refused")
	}
	return nil
}
func (b *boundary) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	acks, err := b.Storage.StorageWrite(ctx, writes)
	if err != nil || len(writes) != 1 || writes[0].Version == "*" {
		return acks, err
	}
	var row struct{ Phase string }
	if json.Unmarshal([]byte(writes[0].Value), &row) != nil || row.Phase != "open" {
		return acks, err
	}
	if b.registerCalls.Add(1) != 1 {
		return acks, err
	}
	close(b.registered)
	if err = event(ctx, b.control, "registered"); err != nil {
		return nil, err
	}
	if b.scenario == "lost-ack" {
		return nil, errors.New("trial registration acknowledgment lost after commit")
	}
	if b.scenario == "cancel-after-write" {
		b.cancelPreparation()
	}
	return acks, nil
}

func localEndpoint(value string) bool {
	u, err := url.Parse(value)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Hostname() == "127.0.0.1" && u.Port() != "" && u.User == nil && u.Path == "" && u.RawQuery == "" && u.Fragment == ""
}

// Run requires the experimental build and explicit enablement, before examining
// credentials. Every target and generation identity is fixed fixture data.
func Run(ctx context.Context, storage allocatoradmission.Storage, report func(string)) error {
	env, _ := ctx.Value(runtime.RUNTIME_CTX_ENV).(map[string]string)
	flag := env["WAR_DURABLE_GENERATION_PROBE_ENABLED"]
	if flag == "" || flag == "false" {
		return nil
	}
	scenario := env["WAR_DURABLE_GENERATION_PROBE_SCENARIO"]
	if flag != "true" || report == nil || (scenario != "held-put" && scenario != "unfenced" && scenario != "late-ack" && scenario != "lost-ack" && scenario != "cancel-after-write" && scenario != "crash-before-exposure" && scenario != "restart") || !localEndpoint(env["WAR_DURABLE_GENERATION_PROBE_CONTROL"]) {
		return errors.New("capability probe: invalid enablement")
	}
	path := env["WAR_DURABLE_GENERATION_PROBE_MATERIAL"]
	if !filepath.IsAbs(path) {
		return errors.New("capability probe: private fixture material required")
	}
	file, err := os.Open(path)
	if err != nil {
		return errors.New("capability probe: private fixture material unavailable")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		return errors.New("capability probe: fixture material is not private")
	}
	var m material
	decoder := json.NewDecoder(io.LimitReader(file, 64<<10))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&m) != nil || decoder.Decode(&struct{}{}) != io.EOF || !localEndpoint(m.Host) {
		return errors.New("capability probe: invalid private fixture material")
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	b := &boundary{Storage: storage, control: env["WAR_DURABLE_GENERATION_PROBE_CONTROL"], scenario: scenario, registered: make(chan struct{})}
	config := gameservercommit.DurableGenerationConfig{Enabled: true, Storage: b, IncarnationID: "native-incarnation",
		Record: nakamageneration.Record{GenerationID: "generation-1", Version: "source-version-1", State: "open", MemberPodUIDs: []string{"pod-a", "pod-b"}, MemberSetDigest: "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d"},
		Commit: gameservercommit.Config{Namespace: "trial", Fleet: "fleet", REST: &rest.Config{Host: m.Host, TLSClientConfig: rest.TLSClientConfig{CAData: m.CA, CertData: m.Cert, KeyData: m.Key}, Timeout: 10 * time.Second}}}
	if scenario == "restart" {
		config.IncarnationID = "restarted-incarnation"
	}
	g, err := gameservercommit.NewDurableGeneration(ctx, config)
	if scenario == "restart" {
		if g != nil || !errors.Is(err, gameservercommit.ErrUnknown) {
			return errors.New("capability probe: crashed root restored authority")
		}
		if err = event(ctx, b.control, "fenced"); err != nil {
			return err
		}
		report(scenario)
		return nil
	}
	if err != nil {
		return errors.New("capability probe: root creation unknown")
	}
	type prepared struct {
		grant gameservercommit.GenerationGrant
		err   error
	}
	preparations := make(chan prepared, 1)
	prepareCtx, cancelPreparation := context.WithCancel(ctx)
	defer cancelPreparation()
	b.cancelPreparation = cancelPreparation
	go func() {
		grant, e := g.Prepare(prepareCtx, "pod-a", "zone-a", "attempt-original")
		preparations <- prepared{grant, e}
	}()
	select {
	case <-b.registered:
	case <-ctx.Done():
		return errors.New("capability probe: registration not reached")
	}
	if scenario == "late-ack" {
		type fenced struct {
			receipt gameservercommit.GenerationReceipt
			err     error
		}
		fences := make(chan fenced, 1)
		go func() { receipt, e := g.Fence(ctx); fences <- fenced{receipt, e} }()
		ticker := time.NewTicker(time.Millisecond)
		defer ticker.Stop()
		for {
			_, e := g.Prepare(ctx, "non-member", "unused", "attempt-unused")
			if errors.Is(e, gameservercommit.ErrClosed) {
				break
			}
			if !errors.Is(e, gameservercommit.ErrInvalid) {
				return errors.New("capability probe: closure unknown")
			}
			select {
			case <-ticker.C:
			case <-ctx.Done():
				return errors.New("capability probe: local closure delayed")
			}
		}
		if err = event(ctx, b.control, "closing"); err != nil {
			return err
		}
		p := <-preparations
		if !errors.Is(p.err, gameservercommit.ErrClosed) {
			return errors.New("capability probe: late grant exposed")
		}
		f := <-fences
		got, e := g.Accept(f.receipt)
		if f.err != nil || e != nil || len(got.Grants) != 1 || got.Grants[0].Outcome != gameservercommit.Uncommitted {
			return errors.New("capability probe: late registered grant omitted")
		}
	} else {
		p := <-preparations
		if scenario == "lost-ack" || scenario == "cancel-after-write" {
			if !errors.Is(p.err, gameservercommit.ErrUnknown) {
				return errors.New("capability probe: lost reply exposed grant")
			}
			if scenario == "cancel-after-write" && !errors.Is(p.err, context.Canceled) {
				return errors.New("capability probe: post-write cancellation lost")
			}
			if _, e := g.Fence(ctx); !errors.Is(e, gameservercommit.ErrClosed) {
				return errors.New("capability probe: unknown owner restored")
			}
			if _, e := gameservercommit.NewDurableGeneration(ctx, config); !errors.Is(e, gameservercommit.ErrUnknown) {
				return errors.New("capability probe: restart restored root")
			}
			if err = event(ctx, b.control, "fenced"); err != nil {
				return err
			}
			report(scenario)
			return nil
		}
		if p.err != nil {
			return errors.New("capability probe: preparation failed")
		}
		if err = event(ctx, b.control, "exposed"); err != nil {
			return err
		}
		commits := make(chan error, 1)
		go func() { commits <- p.grant.Commit(ctx) }()
		if err = event(ctx, b.control, "drain"); err != nil {
			return err
		}
		if scenario == "unfenced" {
			if e := <-commits; e != nil {
				return errors.New("capability probe: unfenced positive write failed")
			}
			if err = event(ctx, b.control, "fenced"); err != nil {
				return err
			}
			report(scenario)
			return nil
		}
		r, e := g.Fence(ctx)
		got, accepted := g.Accept(r)
		if e != nil || accepted != nil || len(got.Grants) != 1 || got.Grants[0].Outcome != gameservercommit.Uncommitted {
			return errors.New("capability probe: complete barrier missing")
		}
		if err = event(ctx, b.control, "fenced"); err != nil {
			return err
		}
		if e = <-commits; !errors.Is(e, gameservercommit.ErrConflict) {
			return errors.New("capability probe: held write committed after barrier")
		}
		report(scenario)
		return nil
	}
	if err = event(ctx, b.control, "fenced"); err != nil {
		return err
	}
	report(scenario)
	return nil
}
