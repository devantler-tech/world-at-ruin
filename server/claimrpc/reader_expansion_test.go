package claimrpc

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
)

// A fully authenticated request still cannot resolve an admission secret from
// an expanded lease, even when its allocation and token match a legacy row.
func TestPrivateClaimHoldsExpandedSchemaBeforeSecretResolution(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	object, ok := f.storage.Get(nakamalease.Collection, f.binding.LeaseObjectID, "")
	if !ok {
		t.Fatal("missing durable claim fixture")
	}
	var fields map[string]any
	if err := json.Unmarshal([]byte(object.Value), &fields); err != nil {
		t.Fatal(err)
	}
	fields["schema"] = 4
	fields["allocator_generation_id"] = "generation:1"
	fields["allocator_member_set_digest"] = strings.Repeat("a", 64)
	fields["allocator_pod_uid"] = "pod-allocator-1"
	value, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	object.Value = string(value)
	f.storage.Seed(object)
	before := f.storage.Objects()
	writes := len(f.storage.WrittenValues())
	resolutions := 0
	client, _ := f.serve(t, func(context.Context, nakamalease.Lease) (handoff.Allocation, error) {
		resolutions++
		return f.allocation, nil
	})
	if err := client.Claim(t.Context(), f.binding, f.token, 1); err == nil {
		t.Fatal("expanded schema admitted a player")
	}
	if resolutions != 0 {
		t.Fatalf("secret resolution calls = %d, want 0", resolutions)
	}
	if writes != len(f.storage.WrittenValues()) || !reflect.DeepEqual(before, f.storage.Objects()) {
		t.Fatal("private claim changed expanded durable ownership")
	}
}
