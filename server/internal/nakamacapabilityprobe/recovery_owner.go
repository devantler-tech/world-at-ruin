//go:build war_native_trial

package nakamacapabilityprobe

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

type recoveryBoundary struct {
	handoffStorage
	control, ownerID, scenario string
	cancel                     context.CancelFunc
}

func (b *recoveryBoundary) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	if len(writes) != 1 || writes[0].Collection != allocatoradmission.RecoveryOwnerCollection {
		return nil, errors.New("recovery owner probe: unexpected write")
	}
	if err := event(ctx, b.control, b.ownerID+"-before-write"); err != nil {
		return nil, err
	}
	acks, err := b.handoffStorage.StorageWrite(ctx, writes)
	if err != nil {
		return acks, err
	}
	if err = event(ctx, b.control, b.ownerID+"-written"); err != nil {
		return nil, err
	}
	switch b.scenario {
	case "lost-owner-ack":
		return nil, errors.New("trial owner reply lost after commit")
	case "cancel-owner-ack":
		b.cancel()
	}
	return acks, nil
}

// RunRecoveryOwner only reserves the original inventory. It never constructs a
// Kubernetes client, allocation grant, barrier or receipt. Its private supervisor
// channel is a disposable experiment, not production authenticated pin custody.
func RunRecoveryOwner(ctx context.Context, storage handoffStorage, report func(string)) error {
	env, _ := ctx.Value(runtime.RUNTIME_CTX_ENV).(map[string]string)
	flag := env["WAR_DURABLE_RECOVERY_OWNER_PROBE_ENABLED"]
	if flag == "" || flag == "false" {
		return nil
	}
	id := env["WAR_DURABLE_RECOVERY_OWNER_PROBE_ID"]
	scenario := env["WAR_DURABLE_RECOVERY_OWNER_PROBE_SCENARIO"]
	control := env["WAR_DURABLE_RECOVERY_OWNER_PROBE_CONTROL"]
	if flag != "true" || report == nil || !localEndpoint(control) || !handoffidentity.CorrelationID(id) || (scenario != "reserve" && scenario != "lost-owner-ack" && scenario != "cancel-owner-ack") {
		return errors.New("recovery owner probe: invalid enablement")
	}
	raw := env["WAR_DURABLE_RECOVERY_OWNER_PROBE_PINS"]
	var pins handoffPins
	decoder := json.NewDecoder(bytes.NewBufferString(raw))
	decoder.DisallowUnknownFields()
	if len(raw) > 64<<10 || decoder.Decode(&pins) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return errors.New("recovery owner probe: independent pins unavailable")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	b := &recoveryBoundary{handoffStorage: storage, control: control, ownerID: id, scenario: scenario, cancel: cancel}
	owner, err := allocatoradmission.NewRecoveryOwner(allocatoradmission.RecoveryOwnerConfig{Enabled: true, Storage: b, Binding: pins.Binding, HandoffVersion: pins.Version, OwnerID: id})
	if err != nil {
		return errors.New("recovery owner probe: reservation unknown")
	}
	reservation, err := owner.Reserve(ctx)
	if err != nil {
		return errors.New("recovery owner probe: reservation unknown")
	}
	observation, err := owner.Accept(reservation)
	if err != nil {
		return errors.New("recovery owner probe: acknowledgment unknown")
	}
	if err = event(ctx, control, id+"-accepted"); err != nil {
		return err
	}
	if err = deliverControl(ctx, control, "/owner-pins", observation); err != nil {
		return err
	}
	report(id)
	return nil
}
