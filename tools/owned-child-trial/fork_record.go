package ownedchild

import (
	"bytes"
	"encoding/binary"
	"errors"
	"strings"
)

const forkStatusSize = 3072
const forkRecordSize = 32 + forkStatusSize + 8 // Less than Linux PIPE_BUF.

// forkRecord is one complete private-pipe observation, never shared COW memory.
type forkRecord struct {
	StatusN, EOF, Send, PID int64
	Status                  [forkStatusSize]byte
	Tail                    [8]byte
}

// decodeFork refuses partial or excess records and incomplete native status reads.
func decodeFork(data []byte) (forkRecord, map[string]string, error) {
	var r forkRecord
	if len(data) != forkRecordSize {
		return r, nil, errors.New("incomplete fork record")
	}
	if err := binary.Read(bytes.NewReader(data), binary.LittleEndian, &r); err != nil {
		return r, nil, err
	}
	if r.StatusN <= 0 || r.StatusN >= forkStatusSize || r.EOF != 0 || r.PID <= 0 {
		return r, nil, errors.New("incomplete fork status or identity")
	}
	status := make(map[string]string)
	for _, line := range strings.Split(string(r.Status[:r.StatusN]), "\n") {
		key, value, found := strings.Cut(line, ":")
		if found {
			if _, duplicate := status[key]; duplicate {
				return r, nil, errors.New("duplicate status field")
			}
			status[key] = strings.TrimSpace(value)
		}
	}
	return r, status, nil
}
