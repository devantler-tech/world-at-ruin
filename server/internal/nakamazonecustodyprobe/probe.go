//go:build war_native_trial

// Package nakamazonecustodyprobe exercises diagnostic custody persistence only
// in the explicitly built native trial. It establishes no claim/launch authority.
package nakamazonecustodyprobe

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/internal/zonecustody"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

type Storage interface {
	zonecustody.Writer
	zonecustody.Reader
}
type Report struct {
	Scenario string
	Writes   int32
	Pins     bool
}

type input struct {
	Binding                   agones.ClaimBinding
	Receipt                   zoneclaim.Receipt
	OwnerID, ChildIncarnation string
}
type boundary struct {
	Storage
	control, owner, scenario string
	cancel                   context.CancelFunc
	writes                   atomic.Int32
}

// Every accepted ACK comes from the actual storage dependency; fault seams only
// withhold/cancel that reply after commit, never replace persistence or success.
func (b *boundary) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	if len(writes) != 1 || writes[0] == nil {
		return nil, errors.New("zone custody probe: unexpected write")
	}
	phase := "enrollment"
	if writes[0].Collection == zonecustody.CustodyCollection {
		phase = "custody"
	} else if writes[0].Collection != zonecustody.EnrollmentCollection {
		return nil, errors.New("zone custody probe: unexpected collection")
	}
	b.writes.Add(1)
	if err := controlRequest(ctx, b.control, "/"+b.owner+"-before-"+phase, nil); err != nil {
		return nil, err
	}
	acks, err := b.Storage.StorageWrite(ctx, writes)
	if err != nil {
		return acks, err
	}
	if err = controlRequest(ctx, b.control, "/"+b.owner+"-"+phase+"-written", nil); err != nil {
		return nil, err
	}
	switch b.scenario {
	case "lost-" + phase + "-ack":
		return nil, errors.New("zone custody probe: reply lost after actual commit")
	case "cancel-" + phase + "-ack":
		b.cancel()
	}
	return acks, nil
}

// Run remains inert until the native experiment is explicitly enabled.
func Run(ctx context.Context, storage Storage, report func(Report)) error {
	env, _ := ctx.Value(runtime.RUNTIME_CTX_ENV).(map[string]string)
	flag := env["WAR_ZONE_CUSTODY_PROBE_ENABLED"]
	if flag == "" || flag == "false" {
		return nil
	}
	scenario := env["WAR_ZONE_CUSTODY_PROBE_SCENARIO"]
	if flag != "true" || report == nil {
		return errors.New("zone custody probe: invalid enablement")
	}
	if scenario == "read" {
		var pins zonecustody.Pins
		if decode(env["WAR_ZONE_CUSTODY_PROBE_PINS"], &pins) != nil {
			return errors.New("zone custody probe: independent pins unknown")
		}
		if _, err := zonecustody.Read(ctx, zonecustody.ReadConfig{Enabled: true, Storage: storage, Pins: pins}); err != nil {
			return errors.New("zone custody probe: pinned readback unknown")
		}
		report(Report{Scenario: scenario, Pins: true})
		return nil
	}
	switch scenario {
	case "complete", "copied", "lost-enrollment-ack", "cancel-enrollment-ack", "lost-custody-ack", "cancel-custody-ack":
	default:
		return errors.New("zone custody probe: invalid scenario")
	}
	var in input
	control := env["WAR_ZONE_CUSTODY_PROBE_CONTROL"]
	if decode(env["WAR_ZONE_CUSTODY_PROBE_INPUT"], &in) != nil || !localEndpoint(control) || !handoffidentity.CorrelationID(in.OwnerID) || !in.Receipt.Matches(in.Binding, in.Receipt.Observer) {
		return errors.New("zone custody probe: invalid input")
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	b := &boundary{Storage: storage, control: control, owner: in.OwnerID, scenario: scenario, cancel: cancel}
	_, err := zonecustody.NewOwner(zonecustody.Config{Enabled: true, Storage: storage, Binding: in.Binding, OwnerID: in.OwnerID, ChildIncarnation: in.ChildIncarnation})
	if err != nil {
		return errors.New("zone custody probe: invalid storage or binding")
	}
	// Bind the writer only after constructor validation, including typed nils.
	owner, err := zonecustody.NewOwner(zonecustody.Config{Enabled: true, Storage: b, Binding: in.Binding, OwnerID: in.OwnerID, ChildIncarnation: in.ChildIncarnation})
	if err != nil {
		return err
	}
	enrolled, err := owner.Reserve(ctx)
	if err != nil {
		if scenario != "lost-enrollment-ack" && scenario != "cancel-enrollment-ack" {
			return errors.New("zone custody probe: enrollment unknown")
		}
		copy := *owner
		if _, e := copy.Reserve(ctx); e == nil || enrolled.RetainOriginal(ctx, in.Receipt) == nil || b.writes.Load() != 1 {
			return errors.New("zone custody probe: uncertain enrollment retried")
		}
		report(Report{Scenario: scenario, Writes: b.writes.Load()})
		return nil
	}
	if scenario == "copied" {
		copy := *owner
		if _, e := copy.Reserve(ctx); e == nil {
			return errors.New("zone custody probe: copied owner retried")
		}
	}
	if err = controlRequest(ctx, control, "/"+in.OwnerID+"-enrolled", nil); err != nil {
		return err
	}
	err = enrolled.RetainOriginal(ctx, in.Receipt)
	if err != nil {
		if scenario != "lost-custody-ack" && scenario != "cancel-custody-ack" {
			return errors.New("zone custody probe: custody unknown")
		}
		copy := enrolled
		_, ok := copy.Pins()
		if ok || copy.RetainOriginal(ctx, in.Receipt) == nil || b.writes.Load() != 2 {
			return errors.New("zone custody probe: uncertain custody restored")
		}
		report(Report{Scenario: scenario, Writes: b.writes.Load()})
		return nil
	}
	if scenario == "copied" {
		copy := enrolled
		if copy.RetainOriginal(ctx, in.Receipt) == nil {
			return errors.New("zone custody probe: copied custody retried")
		}
	}
	pins, ok := enrolled.Pins()
	if !ok || b.writes.Load() != 2 {
		return errors.New("zone custody probe: complete storage ACKs unknown")
	}
	if err = controlRequest(ctx, control, "/"+in.OwnerID+"-custodied", nil); err != nil {
		return err
	}
	if err = controlRequest(ctx, control, "/pins", &pins); err != nil {
		return err
	}
	report(Report{Scenario: scenario, Writes: b.writes.Load(), Pins: true})
	return nil
}

func decode(raw string, target any) error {
	if len(raw) > 16384 {
		return errors.New("zone custody probe: input too large")
	}
	d := json.NewDecoder(strings.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(target) != nil || d.Decode(&struct{}{}) != io.EOF {
		return errors.New("zone custody probe: invalid JSON")
	}
	return nil
}

// Control transport is confined to the disposable supervisor's literal
// loopback endpoint; redirects, proxy configuration and remote hosts are inert.
func localEndpoint(value string) bool {
	u, err := url.Parse(value)
	return err == nil && u.Scheme == "http" && u.Hostname() == "127.0.0.1" && u.Port() != "" && u.User == nil && u.Path == "" && u.RawQuery == "" && u.Fragment == ""
}
func controlRequest(ctx context.Context, control, path string, pins *zonecustody.Pins) error {
	if !localEndpoint(control) {
		return errors.New("zone custody probe: control refused")
	}
	method := http.MethodGet
	var body io.Reader
	if pins != nil {
		raw, err := json.Marshal(pins)
		if err != nil {
			return err
		}
		body = bytes.NewReader(raw)
		method = http.MethodPost
	}
	req, err := http.NewRequestWithContext(ctx, method, control+path, body)
	if err != nil {
		return err
	}
	transport := &http.Transport{DialContext: (&net.Dialer{Timeout: 10 * time.Second}).DialContext}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	res, err := client.Do(req)
	if err != nil {
		return errors.New("zone custody probe: control unknown")
	}
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode != http.StatusNoContent {
		return errors.New("zone custody probe: control refused")
	}
	return nil
}
