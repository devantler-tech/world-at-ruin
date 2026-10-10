//go:build war_native_trial

package nakamacapabilityprobe

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"sync"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/gameservercommit"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/heroiclabs/nakama-common/runtime"
	"k8s.io/client-go/rest"
)

type fenceProbeTransport struct {
	base                  http.RoundTripper
	control, id, scenario string
	first                 string
	cancel                context.CancelFunc
	mu                    sync.Mutex
	reads                 map[string]int
}

// RoundTrip places loss/cancellation after actual target responses and exposes
// the seam between the decoded mutation ACK and its second GET readback.
func (p *fenceProbeTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	name := path.Base(req.URL.Path)
	p.mu.Lock()
	if req.Method == http.MethodGet {
		p.reads[name]++
	}
	read := p.reads[name]
	p.mu.Unlock()
	if req.Method == http.MethodGet && read == 2 {
		if err := event(req.Context(), p.control, p.id+"-before-readback-"+name); err != nil {
			return nil, err
		}
	}
	response, err := p.base.RoundTrip(req)
	if err != nil {
		return nil, err
	}
	if name == p.first && (req.Method == http.MethodPut || read == 2) {
		cut := "barrier-ack"
		if req.Method == http.MethodGet {
			cut = "readback"
		}
		if p.scenario == "lost-"+cut {
			_ = response.Body.Close()
			return nil, errors.New("trial committed barrier reply lost")
		}
		if p.scenario == "cancel-"+cut {
			p.cancel()
		}
	}
	return response, nil
}

// RunRecoveryFence composes only the live originating reservation. The local
// supervisor and its material/pin channel are disposable native-test inputs.
// No durable complete proof or production pin authentication is implemented.
func RunRecoveryFence(ctx context.Context, storage handoffStorage, report func(string)) error {
	env, _ := ctx.Value(runtime.RUNTIME_CTX_ENV).(map[string]string)
	flag := env["WAR_DURABLE_RECOVERY_FENCE_PROBE_ENABLED"]
	if flag == "" || flag == "false" {
		return nil
	}
	id, scenario, control := env["WAR_DURABLE_RECOVERY_FENCE_PROBE_ID"], env["WAR_DURABLE_RECOVERY_FENCE_PROBE_SCENARIO"], env["WAR_DURABLE_RECOVERY_FENCE_PROBE_CONTROL"]
	if flag != "true" || report == nil || !handoffidentity.CorrelationID(id) || !localEndpoint(control) {
		return errors.New("recovery fence probe: invalid enablement")
	}
	switch scenario {
	case "complete", "lost-barrier-ack", "cancel-barrier-ack", "lost-readback", "cancel-readback":
	default:
		return errors.New("recovery fence probe: invalid scenario")
	}
	var pins handoffPins
	raw := env["WAR_DURABLE_RECOVERY_FENCE_PROBE_PINS"]
	decoder := json.NewDecoder(bytes.NewBufferString(raw))
	decoder.DisallowUnknownFields()
	if len(raw) > 64<<10 || decoder.Decode(&pins) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return errors.New("recovery fence probe: independent pins unavailable")
	}
	m, err := recoveryMaterial(env["WAR_DURABLE_RECOVERY_FENCE_PROBE_MATERIAL"])
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	boundary := &recoveryBoundary{handoffStorage: storage, control: control, ownerID: id, scenario: "reserve", cancel: cancel}
	owner, err := allocatoradmission.NewRecoveryOwner(allocatoradmission.RecoveryOwnerConfig{Enabled: true, Storage: boundary, Binding: pins.Binding, HandoffVersion: pins.Version, OwnerID: id})
	if err != nil {
		return errors.New("recovery fence probe: reservation unknown")
	}
	reservation, err := owner.Reserve(ctx)
	if err != nil {
		return errors.New("recovery fence probe: reservation unknown")
	}
	if err = event(ctx, control, id+"-owner"); err != nil {
		return err
	}
	diagnostic, err := owner.Accept(reservation)
	if err != nil || len(diagnostic.Handoff.Journal.Grants) != 2 {
		return errors.New("recovery fence probe: pair inventory unknown")
	}
	cfg := gameservercommit.Config{Enabled: true, Namespace: pins.Binding.Namespace, Fleet: pins.Binding.Fleet, REST: &rest.Config{Host: m.Host, TLSClientConfig: rest.TLSClientConfig{CAData: m.CA, CertData: m.Cert, KeyData: m.Key}, Timeout: 10 * time.Second}}
	cfg.REST.WrapTransport = func(base http.RoundTripper) http.RoundTripper {
		return &fenceProbeTransport{base: base, control: control, id: id, scenario: scenario, first: diagnostic.Handoff.Journal.Grants[0].Name, cancel: cancel, reads: make(map[string]int)}
	}
	recovery, err := gameservercommit.NewRecovery(cfg, reservation)
	if err != nil {
		return errors.New("recovery fence probe: construction unknown")
	}
	result, err := recovery.Fence(ctx)
	if err != nil {
		return errors.New("recovery fence probe: barrier outcome unknown")
	}
	complete, err := recovery.Accept(result)
	if err != nil {
		return errors.New("recovery fence probe: complete acknowledgment unknown")
	}
	// This is after all accepted target readbacks, before any complete export.
	if err = event(ctx, control, id+"-complete"); err != nil {
		return err
	}
	if err = deliverControl(ctx, control, "/recovery-result", complete); err != nil {
		return err
	}
	report(id)
	return nil
}

// recoveryMaterial confines bounded, private fixture credentials to their root
// and accepts only the disposable supervisor's local API endpoint.
func recoveryMaterial(filename string) (material, error) {
	if !filepath.IsAbs(filename) {
		return material{}, errors.New("recovery fence probe: private material required")
	}
	root, err := os.OpenRoot(filepath.Dir(filename))
	if err != nil {
		return material{}, err
	}
	defer func() { _ = root.Close() }()
	file, err := root.Open(filepath.Base(filename))
	if err != nil {
		return material{}, err
	}
	defer func() { _ = file.Close() }()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || info.Size() > 64<<10 {
		return material{}, errors.New("recovery fence probe: private bounded material required")
	}
	var m material
	decoder := json.NewDecoder(io.LimitReader(file, 64<<10))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&m) != nil || decoder.Decode(&struct{}{}) != io.EOF || !localEndpoint(m.Host) {
		return material{}, errors.New("recovery fence probe: invalid material")
	}
	return m, nil
}
