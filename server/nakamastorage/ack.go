package nakamastorage

import "github.com/heroiclabs/nakama-common/api"

// ValidAcknowledgement checks only one acknowledgement's reported identity and
// nonempty version. Batch order, cardinality and stronger version rules belong
// to callers, as does recovery when a write cannot be confirmed by its reply.
func ValidAcknowledgement(ack *api.StorageObjectAck, collection, key, owner string) bool {
	return ack != nil && ack.GetCollection() == collection && ack.GetKey() == key &&
		ack.GetUserId() == owner && ack.GetVersion() != ""
}
