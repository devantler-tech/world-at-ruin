package gameservercommit

import (
	"context"
	"errors"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
)

// JournalCollection retains the shipped private collection identity.
const JournalCollection = allocatorjournal.JournalCollection

// These aliases preserve the inactive commit experiment's source API.
type JournalStorage = allocatorjournal.JournalStorage
type JournalGrant = allocatorjournal.JournalGrant
type JournalBinding = allocatorjournal.JournalBinding
type JournalObservation = allocatorjournal.JournalObservation
type JournalReaderConfig = allocatorjournal.JournalReaderConfig

// JournalReader preserves error compatibility while sharing the read-only implementation.
type JournalReader struct {
	reader *allocatorjournal.JournalReader
}

// NewJournalReader delegates bounded construction without exporting commit authority.
func NewJournalReader(cfg JournalReaderConfig) (*JournalReader, error) {
	reader, err := allocatorjournal.NewJournalReader(cfg)
	if err != nil {
		return nil, journalError(err)
	}
	return &JournalReader{reader: reader}, nil
}

// Load returns detached inventory and retains the original error identities.
func (r *JournalReader) Load(ctx context.Context) (JournalObservation, error) {
	if r == nil || r.reader == nil {
		return JournalObservation{}, ErrInvalid
	}
	got, err := r.reader.Load(ctx)
	return got, journalError(err)
}

// decodeJournal keeps the historical fixture contract bound to the shared decoder.
func decodeJournal(value string) (JournalObservation, error) {
	got, err := allocatorjournal.DecodeJournal(value)
	return got, journalError(err)
}

// journalError exposes only existing classifications and caller cancellation.
func journalError(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, allocatorjournal.ErrDisabled):
		return ErrDisabled
	case errors.Is(err, allocatorjournal.ErrInvalid):
		return ErrInvalid
	case errors.Is(err, context.Canceled):
		return errors.Join(ErrUnknown, context.Canceled)
	case errors.Is(err, context.DeadlineExceeded):
		return errors.Join(ErrUnknown, context.DeadlineExceeded)
	default:
		return ErrUnknown
	}
}
