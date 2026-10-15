package nakamatrial

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"
)

// Health consumes the caller's original startup window, including any prerequisite.
func awaitNativeStartupCondition(ctx context.Context, done <-chan struct{}, probe func(context.Context) bool) string {
	for ctx.Err() == nil {
		select {
		case <-done:
			return "process-exited"
		default:
		}
		if probe(ctx) {
			if ctx.Err() != nil {
				return "startup-deadline"
			}
			select {
			case <-done:
				return "process-exited"
			default:
				return "ready"
			}
		}
		select {
		case <-ctx.Done():
			return "startup-deadline"
		case <-done:
			return "process-exited"
		case <-time.After(25 * time.Millisecond):
		}
	}
	return "startup-deadline"
}

type nativeStartupObservation struct {
	Condition string
	Class     string
	Snapshot  string
}

// observeNativeStartup reduces private output to fixed observations. A single
// exact fatal record is evidence of a refusal, never proof of its root cause.
func observeNativeStartup(condition, log string) nativeStartupObservation {
	result := nativeStartupObservation{Condition: condition, Class: "unclassified", Snapshot: "none"}
	scanner := bufio.NewScanner(strings.NewReader(log))
	fatals, snapshots := 0, 0
	for scanner.Scan() {
		if strings.TrimSpace(scanner.Text()) == "" {
			continue
		}
		record, ok := startupRecord(scanner.Text())
		if !ok {
			result.Class, result.Snapshot = "unclassified", "unclassified"
			return result
		}
		if record["level"] == "info" && record["msg"] == issuedSnapshotMarker {
			snapshots++
		}
		if record["level"] != "fatal" {
			continue
		}
		fatals++
		if record["msg"] == "Error returned by InitModule function in Go module" {
			result.Class = "module-init-other"
			switch record["error"] {
			case "issued claims WorkloadAPI request refused":
				result.Class = "issued-workload-api-refused"
			case "issued claims credential selection refused":
				result.Class = "issued-selection-refused"
			case "issued claims identity refused":
				result.Class = "issued-identity-refused"
			case "issued claims trust bundle refused":
				result.Class = "issued-bundle-refused"
			case "issued claims SDK construction refused":
				result.Class = "issued-sdk-refused"
			case "issued claims SDK cleanup unknown":
				result.Class = "issued-cleanup-unknown"
			}
		} else {
			result.Class = "unclassified"
		}
	}
	if scanner.Err() != nil {
		result.Class, result.Snapshot = "unclassified", "unclassified"
		return result
	}
	if fatals != 1 {
		result.Class = "unclassified"
	}
	switch snapshots {
	case 0:
		result.Snapshot = "none"
	case 1:
		result.Snapshot = "one"
	default:
		result.Snapshot = "multiple"
	}
	return result
}

// startupRecord rejects duplicate keys and trailing data; only three string
// fields participate in classification. Other private fields are never returned.
func startupRecord(line string) (map[string]string, bool) {
	decoder := json.NewDecoder(strings.NewReader(line))
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return nil, false
	}
	seen, result := map[string]bool{}, map[string]string{}
	for decoder.More() {
		token, err := decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok || seen[key] {
			return nil, false
		}
		seen[key] = true
		var value json.RawMessage
		if decoder.Decode(&value) != nil {
			return nil, false
		}
		if key == "level" || key == "msg" || key == "error" {
			var text string
			if json.Unmarshal(value, &text) != nil {
				return nil, false
			}
			result[key] = text
		}
	}
	if token, err := decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, false
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, false
	}
	return result, true
}

// publicText revalidates values decoded from a worker before any public output.
func (o nativeStartupObservation) publicText() string {
	condition, class, snapshot := "unclassified", "unclassified", "unclassified"
	switch o.Condition {
	case "process-start-failed", "process-exited", "startup-deadline":
		condition = o.Condition
	}
	switch o.Class {
	case "module-init-other", "issued-workload-api-refused", "issued-selection-refused", "issued-identity-refused", "issued-bundle-refused", "issued-sdk-refused", "issued-cleanup-unknown":
		class = o.Class
	}
	switch o.Snapshot {
	case "none", "one", "multiple":
		snapshot = o.Snapshot
	}
	return fmt.Sprintf("condition=%s class=%s snapshot=%s", condition, class, snapshot)
}
