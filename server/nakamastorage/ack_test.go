package nakamastorage

import (
	"testing"

	"github.com/heroiclabs/nakama-common/api"
)

func TestAcknowledgementRequiresEachReportedIdentityField(t *testing.T) {
	valid := func() *api.StorageObjectAck {
		return &api.StorageObjectAck{Collection: "records", Key: "key", UserId: "owner", Version: "observed"}
	}
	if !ValidAcknowledgement(valid(), "records", "key", "owner") {
		t.Fatal("valid acknowledgement refused")
	}
	if ValidAcknowledgement(nil, "records", "key", "owner") {
		t.Fatal("nil acknowledgement accepted")
	}
	for _, mutate := range []func(*api.StorageObjectAck){
		func(a *api.StorageObjectAck) { a.Collection = "other" },
		func(a *api.StorageObjectAck) { a.Key = "other" },
		func(a *api.StorageObjectAck) { a.UserId = "other" },
		func(a *api.StorageObjectAck) { a.Version = "" },
	} {
		ack := valid()
		mutate(ack)
		if ValidAcknowledgement(ack, "records", "key", "owner") {
			t.Fatalf("malformed acknowledgement accepted: %+v", ack)
		}
	}
	// Syntax and stronger version policy belong to callers, not this predicate.
	ack := valid()
	ack.Version = "*"
	if !ValidAcknowledgement(ack, "records", "key", "owner") {
		t.Fatal("caller-owned version grammar was narrowed")
	}
}
