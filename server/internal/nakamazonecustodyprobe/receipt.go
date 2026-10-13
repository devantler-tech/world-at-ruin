//go:build war_native_trial

package nakamazonecustodyprobe

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
)

// originalInput declares correlation only. There is no diagnostic receipt in
// this mode and no claim authority derived from the loopback transport.
type originalInput struct {
	Binding                   agones.ClaimBinding
	Observer                  sim.EntityID
	OwnerID, ChildIncarnation string
}

func parseInput(env map[string]string, in *input) (*originalInput, error) {
	raw := env["WAR_ZONE_CUSTODY_PROBE_INPUT"]
	switch env["WAR_ZONE_CUSTODY_PROBE_RECEIPT_SOURCE"] {
	case "":
		if decode(raw, in) != nil || !in.Receipt.Matches(in.Binding, in.Receipt.Observer) {
			return nil, errors.New("invalid diagnostic input")
		}
		return nil, nil
	case "control":
		var original originalInput
		var binding json.RawMessage
		if len(raw) > 16384 || nakamastorage.DecodeRequiredObject(raw, map[string]any{"Binding": &binding, "Observer": &original.Observer, "OwnerID": &original.OwnerID, "ChildIncarnation": &original.ChildIncarnation}) != nil || original.Observer == 0 {
			return nil, errors.New("invalid original input")
		}
		b := &original.Binding
		if nakamastorage.DecodeRequiredObject(string(binding), map[string]any{"Namespace": &b.Namespace, "LeaseObjectID": &b.LeaseObjectID, "AttemptDigest": &b.AttemptDigest, "AllocationID": &b.AllocationID, "GameServerUID": &b.GameServerUID}) != nil {
			return nil, errors.New("invalid original binding")
		}
		in.Binding, in.OwnerID, in.ChildIncarnation = original.Binding, original.OwnerID, original.ChildIncarnation
		return &original, nil
	default:
		return nil, errors.New("invalid receipt source")
	}
}

// forwardedReceipt makes one fresh connection after accepted enrollment. No
// retries, storage reads or fallback can turn an uncertain reply into custody.
func forwardedReceipt(ctx context.Context, control string, original originalInput) (zoneclaim.Receipt, error) {
	var receipt zoneclaim.Receipt
	if !localEndpoint(control) {
		return receipt, errors.New("receipt endpoint refused")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, control+"/receipt", nil)
	if err != nil {
		return receipt, err
	}
	transport := &http.Transport{DialContext: (&net.Dialer{Timeout: 10 * time.Second}).DialContext}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(req)
	if err != nil {
		return receipt, errors.New("receipt response unknown")
	}
	defer func() { _ = response.Body.Close() }()
	media, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || media != "application/json" || response.StatusCode != http.StatusOK {
		return receipt, errors.New("receipt response refused")
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, 16385))
	if err != nil || len(raw) > 16384 || ctx.Err() != nil {
		return receipt, errors.New("receipt response incomplete")
	}
	var fence json.RawMessage
	if nakamastorage.DecodeRequiredObject(string(raw), map[string]any{"Namespace": &receipt.Namespace, "Observer": &receipt.Observer, "Fence": &fence}) != nil {
		return zoneclaim.Receipt{}, errors.New("receipt document refused")
	}
	f := &receipt.Fence
	if nakamastorage.DecodeRequiredObject(string(fence), map[string]any{"LeaseObjectID": &f.LeaseObjectID, "LeaseVersion": &f.LeaseVersion, "AttemptDigest": &f.AttemptDigest, "AllocationID": &f.AllocationID, "GameServerUID": &f.GameServerUID, "Generation": &f.Generation}) != nil || !receipt.Matches(original.Binding, original.Observer) {
		return zoneclaim.Receipt{}, errors.New("receipt binding refused")
	}
	return receipt, nil
}
