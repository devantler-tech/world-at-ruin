package zoneclaim

import "context"

// ReceiptCustodian retains the actual originating receipt under independently
// established launch enrollment. A nil error must acknowledge protected custody,
// not merely a visible row. Implementations must honor the request context.
// This source boundary supplies no production authentication or storage adapter.
type ReceiptCustodian interface {
	RetainOriginal(context.Context, Receipt) error
}

// CustodyConfig requires explicit opt-in; its zero value permits no construction.
type CustodyConfig struct {
	Enabled   bool
	Custodian ReceiptCustodian
}

// NewCustodiedReceiptGate constructs an inert opt-in admission boundary.
func NewCustodiedReceiptGate(source BindingSource, backend ReceiptClaimer, cfg CustodyConfig) (*ReceiptGate, error) {
	if !cfg.Enabled || cfg.Custodian == nil {
		return nil, ErrRefused
	}
	gate, err := NewReceiptGate(source, backend)
	if err != nil {
		return nil, err
	}
	gate.custodian = cfg.Custodian
	return gate, nil
}
