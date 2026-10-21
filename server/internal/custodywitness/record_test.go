package custodywitness

import (
	"encoding/json"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

var (
	key       = strings.Repeat("a", 64)
	enrolled  = Record{LifetimeKey: key, Stage: StageEnrolled, EnrollmentPin: strings.Repeat("b", 64)}
	custody   = Record{LifetimeKey: key, Stage: StageCustody, EnrollmentPin: strings.Repeat("b", 64), CustodyPin: strings.Repeat("c", 64)}
	tombstone = Record{LifetimeKey: key, Stage: StageTombstone, EnrollmentPin: strings.Repeat("b", 64), CustodyPin: strings.Repeat("c", 64), TombstonePin: strings.Repeat("d", 64)}
)

// readGolden returns each shipped document exactly as its bytes appear.
func readGolden(t *testing.T) []json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile("testdata/golden_custody_witness_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var documents []json.RawMessage
	if err = json.Unmarshal(raw, &documents); err != nil || len(documents) != 3 {
		t.Fatal("golden fixture must hold one document per stage", len(documents), err)
	}
	return documents
}

// Returning zero values, skipping a document or accepting a lossy read would
// lose a stage the witness already acknowledged.
func TestEveryShippedWitnessRecordRemainsReadable(t *testing.T) {
	for i, want := range []Record{enrolled, custody, tombstone} {
		got, err := DecodeRecord(string(readGolden(t)[i]))
		if err != nil || got != want {
			t.Fatal("historical witness record lost", i, got, err)
		}
	}
}

func TestEncodeIsTheCanonicalShippedDocument(t *testing.T) {
	for i, record := range []Record{enrolled, custody, tombstone} {
		got, err := EncodeRecord(record)
		if err != nil || got != string(readGolden(t)[i]) {
			t.Fatal("encoding drifted from the shipped document", i, got, err)
		}
		back, err := DecodeRecord(got)
		if err != nil || back != record {
			t.Fatal("round trip lost the record", i, back, err)
		}
	}
}

func TestStrictReaderRefusesIncompleteAndConflictingDocuments(t *testing.T) {
	for i, document := range readGolden(t) {
		original := string(document)
		// Each member is corrupted on its own: dropped, nulled, repeated,
		// followed by a foreign member, emptied or retyped.
		bad, _ := strictReaderCorruptions(t, document, func(value string) error { _, err := DecodeRecord(value); return err }, "7")
		// A schema from the future, a wrong-length or uppercase pin, a stage that
		// disagrees with its fields and a pin for a stage not yet reached.
		bad = append(bad,
			strings.Replace(original, `"schema":1`, `"schema":2`, 1),
			strings.Replace(original, `"enrollment_pin":"b`, `"enrollment_pin":"B`, 1),
			strings.Replace(original, `"enrollment_pin":"b`, `"enrollment_pin":"`, 1),
			strings.Replace(original, `"stage":"enrolled"`, `"stage":"custody"`, 1),
			strings.Replace(original, `"stage":"custody"`, `"stage":"tombstone"`, 1),
			strings.Replace(original, `"stage":"tombstone"`, `"stage":"custody"`, 1),
			strings.Replace(original, `"stage":"custody"`, `"stage":"enrolled"`, 1),
			strings.Replace(original, `"stage":"`, `"stage":"x`, 1),
			strings.TrimSuffix(original, "}")+`,"tombstone_pin":"`+strings.Repeat("d", 64)+`"}`)
		if i == 0 {
			bad = append(bad, strings.TrimSuffix(original, "}")+`,"custody_pin":"`+strings.Repeat("c", 64)+`"}`)
		}
		for _, value := range bad {
			if value == original {
				continue
			}
			if got, err := DecodeRecord(value); err == nil {
				t.Fatal("ambiguous witness record accepted", i, value, got)
			}
		}
	}
}

func TestOnlyCompleteValidRecordsEncode(t *testing.T) {
	for _, record := range []Record{
		{},
		{LifetimeKey: key, Stage: "x", EnrollmentPin: enrolled.EnrollmentPin},
		{LifetimeKey: "", Stage: StageEnrolled, EnrollmentPin: enrolled.EnrollmentPin},
		{LifetimeKey: key, Stage: StageEnrolled},
		{LifetimeKey: key, Stage: StageEnrolled, EnrollmentPin: enrolled.EnrollmentPin, CustodyPin: custody.CustodyPin},
		{LifetimeKey: key, Stage: StageCustody, EnrollmentPin: enrolled.EnrollmentPin},
		{LifetimeKey: key, Stage: StageCustody, EnrollmentPin: enrolled.EnrollmentPin, CustodyPin: custody.CustodyPin, TombstonePin: tombstone.TombstonePin},
		{LifetimeKey: key, Stage: StageTombstone, EnrollmentPin: enrolled.EnrollmentPin, CustodyPin: custody.CustodyPin},
		{LifetimeKey: strings.ToUpper(key), Stage: StageEnrolled, EnrollmentPin: enrolled.EnrollmentPin},
	} {
		if value, err := EncodeRecord(record); err == nil {
			t.Fatal("invalid record encoded", record, value)
		}
	}
}

// Only the single next stage with every earlier pin unchanged follows.
func TestRecordsOnlyMoveForwardOneStage(t *testing.T) {
	if !custody.Follows(enrolled) || !tombstone.Follows(custody) {
		t.Fatal("the forward chain was refused")
	}
	otherKey := custody
	otherKey.LifetimeKey = strings.Repeat("e", 64)
	otherEnrollment := custody
	otherEnrollment.EnrollmentPin = strings.Repeat("e", 64)
	otherCustody := tombstone
	otherCustody.CustodyPin = strings.Repeat("e", 64)
	for _, pair := range []struct{ next, previous Record }{
		{enrolled, Record{}},
		{enrolled, enrolled},
		{custody, custody},
		{tombstone, tombstone},
		{tombstone, enrolled},
		{enrolled, custody},
		{custody, tombstone},
		{enrolled, tombstone},
		{otherKey, enrolled},
		{otherEnrollment, enrolled},
		{otherCustody, custody},
		{Record{LifetimeKey: key, Stage: StageCustody, EnrollmentPin: enrolled.EnrollmentPin}, enrolled},
	} {
		if pair.next.Follows(pair.previous) {
			t.Fatal("a non-forward step was accepted", pair.previous.Stage, pair.next.Stage)
		}
	}
}

// The record contract is inert: it reaches no network, cloud SDK or storage
// client, so importing it cannot start or configure a witness.
func TestRecordContractImportsNoClient(t *testing.T) {
	allowed := map[string]bool{
		"context": true, "encoding/json": true, "errors": true, "reflect": true, "time": true, "unicode/utf8": true,
		"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity": true,
		"github.com/devantler-tech/world-at-ruin/server/nakamastorage":            true,
	}
	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatal("no package sources found", err)
	}
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		parsed, err := parser.ParseFile(token.NewFileSet(), file, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatal(err)
		}
		for _, spec := range parsed.Imports {
			path, _ := strconv.Unquote(spec.Path.Value)
			if !allowed[path] {
				t.Fatal("the record contract imports an unreviewed package", file, path)
			}
		}
	}
}
