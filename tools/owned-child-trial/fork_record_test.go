package ownedchild

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// TestForkRecordCompleteness requires all bytes and the child's actual EOF result.
func TestForkRecordCompleteness(t *testing.T) {
	r := forkRecord{StatusN: 8, PID: 123, Send: 8}
	copy(r.Status[:], "Name:\tx\n")
	for _, fault := range []string{"none", "short", "excess", "read error", "not EOF", "full", "no PID"} {
		t.Run(fault, func(t *testing.T) {
			value := r
			switch fault {
			case "read error":
				value.StatusN = -1
			case "not EOF":
				value.EOF = 1
			case "full":
				value.StatusN = forkStatusSize
			case "no PID":
				value.PID = 0
			}
			var data bytes.Buffer
			if err := binary.Write(&data, binary.LittleEndian, value); err != nil {
				t.Fatal(err)
			}
			b := data.Bytes()
			if fault == "short" {
				b = b[:len(b)-1]
			}
			if fault == "excess" {
				b = append(b, 0)
			}
			_, status, err := decodeFork(b)
			if fault == "none" {
				if err != nil || status["Name"] != "x" {
					t.Fatalf("positive: %v", err)
				}
			} else if err == nil {
				t.Fatal("incomplete evidence accepted")
			}
		})
	}
}
