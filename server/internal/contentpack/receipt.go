package contentpack

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

type Receipt struct {
	Schema          int        `json:"schema"`
	Kind            string     `json:"kind"`
	PackSHA256      string     `json:"pack_sha256"`
	PackSize        int64      `json:"pack_size"`
	InventorySHA256 string     `json:"inventory_sha256"`
	Resources       []Resource `json:"resources"`
}

// NewReceipt binds pack bytes and the complete ordered inventory without granting authority.
func NewReceipt(pack []byte, resources []Resource) ([]byte, error) {
	if len(pack) == 0 || len(pack) > MaxPackBytes {
		return nil, errors.New("pack is empty or exceeds build budget")
	}
	if err := ValidateInventory(resources); err != nil {
		return nil, err
	}
	inventory, err := json.Marshal(resources)
	if err != nil {
		return nil, err
	}
	return json.Marshal(Receipt{Schema: 1, Kind: "experimental-build-evidence", PackSHA256: Digest(pack), PackSize: int64(len(pack)), InventorySHA256: Digest(inventory), Resources: resources})
}

// Verify requires the independently retained resource inventory too. An unsigned
// build receipt deliberately grants no manifest, signature or installation authority.
func Verify(pack []byte, resources []Resource, raw []byte) error {
	if len(raw) > 8<<20 {
		return errors.New("receipt exceeds its budget")
	}
	var receipt Receipt
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&receipt); err != nil {
		return errors.New("receipt shape is invalid")
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return errors.New("receipt contains trailing data")
	}
	expected, err := NewReceipt(pack, resources)
	if err != nil {
		return err
	}
	normalized, err := json.Marshal(receipt)
	if err != nil {
		return err
	}
	if !bytes.Equal(expected, normalized) || !bytes.Equal(expected, raw) {
		return errors.New("pack or inventory differs from the build receipt")
	}
	return nil
}
