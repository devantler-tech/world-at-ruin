//go:build war_native_trial

package nakamacapabilityprobe

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"sync/atomic"

	"github.com/devantler-tech/world-at-ruin/server/internal/gameservercommit"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// publicationBoundary places fault seams around actual native storage calls.
// It never manufactures ACKs or substitutes a fake persistence implementation.
type publicationBoundary struct {
	handoffStorage
	control, id, scenario string
	cancel                context.CancelFunc
	writes                atomic.Int32
}

// StorageWrite holds the consume-before-submit and committed-before-ACK seams.
func (b *publicationBoundary) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	if len(writes) != 1 || writes[0].Collection != gameservercommit.RecoveryProofCollection {
		return nil, errors.New("recovery publication probe: unexpected write")
	}
	b.writes.Add(1)
	if err := event(ctx, b.control, b.id+"-before-proof-submit"); err != nil {
		return nil, err
	}
	acks, err := b.handoffStorage.StorageWrite(ctx, writes)
	if err != nil {
		return acks, err
	}
	if err = event(ctx, b.control, b.id+"-proof-written"); err != nil {
		return nil, err
	}
	switch b.scenario {
	case "lost-proof-ack":
		return nil, errors.New("trial proof ACK lost after actual commit")
	case "cancel-proof-ack":
		b.cancel()
	}
	return acks, nil
}

// StorageRead holds after ACK but before proof readback, then cuts real replies.
func (b *publicationBoundary) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	proof := len(reads) == 1 && reads[0].Collection == gameservercommit.RecoveryProofCollection
	if proof {
		if err := event(ctx, b.control, b.id+"-before-proof-readback"); err != nil {
			return nil, err
		}
	}
	rows, err := b.handoffStorage.StorageRead(ctx, reads)
	if err != nil || !proof {
		return rows, err
	}
	switch b.scenario {
	case "lost-proof-readback":
		return nil, errors.New("trial proof readback lost after actual read")
	case "cancel-proof-readback":
		b.cancel()
	}
	return rows, nil
}

// RunRecoveryPublication composes only a live originating complete recovery
// result. The supervisor's retained pins are disposable test inputs, with no
// production custody, restart authority or quarantine release.
func RunRecoveryPublication(ctx context.Context, storage handoffStorage, report func(string)) error {
	env, _ := ctx.Value(runtime.RUNTIME_CTX_ENV).(map[string]string)
	flag := env["WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_ENABLED"]
	if flag == "" || flag == "false" {
		return nil
	}
	id, scenario, control := env["WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_ID"], env["WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_SCENARIO"], env["WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_CONTROL"]
	if flag != "true" || report == nil || !handoffidentity.CorrelationID(id) || !localEndpoint(control) {
		return errors.New("recovery publication probe: invalid enablement")
	}
	if scenario == "read" {
		raw := env["WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_PUBLICATION_PINS"]
		var pins gameservercommit.PublicationPins
		decoder := json.NewDecoder(bytes.NewBufferString(raw))
		decoder.DisallowUnknownFields()
		if len(raw) > 1<<20 || decoder.Decode(&pins) != nil || decoder.Decode(&struct{}{}) != io.EOF || pins.Recovery.Owner.OwnerID != id {
			return errors.New("recovery publication probe: independent publication pins unknown")
		}
		if _, err := gameservercommit.ReadRecoveryPublication(ctx, gameservercommit.PublicationReadConfig{Enabled: true, Storage: storage, Pins: pins}); err != nil {
			return errors.New("recovery publication probe: pinned readback unknown")
		}
		report(id)
		return nil
	}
	switch scenario {
	case "complete", "competing-publishers", "lost-proof-ack", "cancel-proof-ack", "lost-proof-readback", "cancel-proof-readback":
	default:
		return errors.New("recovery publication probe: invalid scenario")
	}
	fenceEnv := map[string]string{"WAR_DURABLE_RECOVERY_FENCE_PROBE_ENABLED": "true", "WAR_DURABLE_RECOVERY_FENCE_PROBE_ID": id, "WAR_DURABLE_RECOVERY_FENCE_PROBE_SCENARIO": "complete", "WAR_DURABLE_RECOVERY_FENCE_PROBE_CONTROL": control, "WAR_DURABLE_RECOVERY_FENCE_PROBE_PINS": env["WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_PINS"], "WAR_DURABLE_RECOVERY_FENCE_PROBE_MATERIAL": env["WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_MATERIAL"], "WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_SCENARIO": scenario}
	return runRecoveryFence(ctx, storage, report, fenceEnv, true)
}

// publishRecoveryResult consumes opaque origin state, accepts exact ACK/readback,
// then delivers pins independently before reporting the experiment's success.
func publishRecoveryResult(ctx context.Context, storage handoffStorage, report func(string), env map[string]string, complete gameservercommit.RecoveryResult) error {
	id, control, scenario := env["WAR_DURABLE_RECOVERY_FENCE_PROBE_ID"], env["WAR_DURABLE_RECOVERY_FENCE_PROBE_CONTROL"], env["WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_SCENARIO"]
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	b := &publicationBoundary{handoffStorage: storage, control: control, id: id, scenario: scenario, cancel: cancel}
	cfg := gameservercommit.PublicationConfig{Enabled: true, Storage: b}
	publisher, err := gameservercommit.NewRecoveryPublisher(cfg, complete)
	if err != nil {
		return errors.New("recovery publication probe: publication unknown")
	}
	var result gameservercommit.PublicationResult
	if scenario == "competing-publishers" {
		peer, e := gameservercommit.NewRecoveryPublisher(cfg, complete)
		if e != nil {
			return errors.New("recovery publication probe: publication unknown")
		}
		copy := *publisher
		var wg sync.WaitGroup
		type accepted struct {
			publisher *gameservercommit.RecoveryPublisher
			result    gameservercommit.PublicationResult
		}
		winners := make(chan accepted, 3)
		failures := make(chan error, 3)
		for _, p := range []*gameservercommit.RecoveryPublisher{publisher, &copy, peer} {
			wg.Go(func() {
				r, e := p.Publish(ctx)
				if e != nil {
					failures <- e
					return
				}
				winners <- accepted{p, r}
			})
		}
		wg.Wait()
		if len(winners) != 1 || len(failures) != 2 || b.writes.Load() != 1 {
			return errors.New("recovery publication probe: publication unknown")
		}
		for range 2 {
			if !errors.Is(<-failures, gameservercommit.ErrClosed) {
				return errors.New("recovery publication probe: publication unknown")
			}
		}
		winner := <-winners
		publisher, result = winner.publisher, winner.result
	} else {
		result, err = publisher.Publish(ctx)
		if err != nil {
			return errors.New("recovery publication probe: publication unknown")
		}
	}
	pins, err := publisher.Accept(result)
	if err != nil || b.writes.Load() != 1 {
		return errors.New("recovery publication probe: publication unknown")
	}
	if err = event(ctx, control, id+"-proof-complete"); err != nil {
		return err
	}
	if err = deliverControl(ctx, control, "/publication-pins", pins); err != nil {
		return err
	}
	report(id)
	return nil
}
