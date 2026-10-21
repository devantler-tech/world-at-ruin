package custodywitness

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"
)

// generationChain holds one record per stage of a generation that issued two
// grants, in stage order.
func generationChain() []GenerationRecord {
	pins := []string{strings.Repeat("3", 64), strings.Repeat("4", 64), strings.Repeat("5", 64), strings.Repeat("6", 64), strings.Repeat("7", 64)}
	stages := []GenerationStage{GenerationRegistered, GenerationDrained, GenerationHandoff, GenerationOwner, GenerationRecovered, GenerationPublished}
	chain := make([]GenerationRecord, len(stages))
	for index, stage := range stages {
		record := GenerationRecord{
			GenerationKey: key, Stage: stage, GrantCount: 2,
			IssuedDigest: strings.Repeat("1", 64), RegistrationPin: strings.Repeat("2", 64),
		}
		for pin, value := range pins[:index] {
			setLaterPin(&record, pin, value)
		}
		chain[index] = record
	}
	return chain
}

// readGenerationGolden returns each shipped document exactly as its bytes appear.
func readGenerationGolden(t *testing.T) []json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile("testdata/golden_generation_witness_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var documents []json.RawMessage
	if err = json.Unmarshal(raw, &documents); err != nil || len(documents) != 6 {
		t.Fatal("golden fixture must hold one document per stage", len(documents), err)
	}
	return documents
}

// Returning zero values, skipping a document or accepting a lossy read would
// lose a generation stage the witness already acknowledged.
func TestEveryShippedGenerationWitnessRecordRemainsReadable(t *testing.T) {
	documents := readGenerationGolden(t)
	for i, want := range generationChain() {
		got, err := DecodeGenerationRecord(string(documents[i]))
		if err != nil || got != want {
			t.Fatal("historical generation witness record lost", i, got, err)
		}
	}
}

func TestGenerationEncodeIsTheCanonicalShippedDocument(t *testing.T) {
	documents := readGenerationGolden(t)
	for i, record := range generationChain() {
		got, err := EncodeGenerationRecord(record)
		if err != nil || got != string(documents[i]) {
			t.Fatal("encoding drifted from the shipped document", i, got, err)
		}
		if len(got) >= maximumDocumentBytes {
			t.Fatal("a valid document must fit inside the read bound", i, len(got))
		}
		back, err := DecodeGenerationRecord(got)
		if err != nil || back != record {
			t.Fatal("round trip lost the record", i, back, err)
		}
	}
	opening := GenerationRecord{GenerationKey: key, Stage: GenerationRegistered, IssuedDigest: strings.Repeat("1", 64), RegistrationPin: strings.Repeat("2", 64)}
	got, err := EncodeGenerationRecord(opening)
	if err != nil || !strings.Contains(got, `"grant_count":0,`) {
		t.Fatal("an opening record must keep its zero grant count", got, err)
	}
	if back, err := DecodeGenerationRecord(got); err != nil || back != opening {
		t.Fatal("an opening record did not round trip", back, err)
	}
}

func TestGenerationStrictReaderRefusesIncompleteAndConflictingDocuments(t *testing.T) {
	stages := []string{"registered", "drained", "handoff", "owner", "recovered", "published"}
	laterPins := []string{"drain_pin", "handoff_pin", "owner_pin", "recovered_pin", "published_pin"}
	for i, document := range readGenerationGolden(t) {
		original := string(document)
		bad := []string{"", "null", "[]", "7", "{}", original + "{}", original + " x", strings.Repeat(" ", maximumDocumentBytes) + original, strings.Replace(original, `"stage":"`, `"stage":"\ud800`, 1)}
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(document, &fields); err != nil {
			t.Fatal(err)
		}
		if len(fields) != registeredMemberCount+i {
			t.Fatal("fixture does not hold exactly its stage's members", i, len(fields))
		}
		// Each member is corrupted on its own: dropped, nulled, repeated,
		// followed by a foreign member, emptied or retyped.
		for name, value := range fields {
			member := strconv.Quote(name) + ":" + string(value)
			if strings.Count(original, member) != 1 {
				t.Fatal("fixture member not exercised", name)
			}
			before, after, _ := strings.Cut(original, member)
			dropped := before + strings.TrimPrefix(after, ",")
			if trimmed, ok := strings.CutSuffix(before, ","); ok {
				dropped = trimmed + after
			}
			if _, err := DecodeGenerationRecord(dropped); err == nil || !json.Valid([]byte(dropped)) {
				t.Fatal("dropping a member must leave valid JSON that is refused", name, dropped)
			}
			for _, replacement := range []string{strconv.Quote(name) + ":null", member + "," + member, member + `,"foreign":7`, strconv.Quote(name) + `:""`, strconv.Quote(name) + `:"7"`, strconv.Quote(name) + ":[]"} {
				bad = append(bad, before+replacement+after)
			}
		}
		// A schema from the future, a wrong-length or uppercase pin, a count out
		// of bounds or fractional, every stage that disagrees with the members
		// and a pin for every stage not yet reached.
		bad = append(bad,
			strings.Replace(original, `"schema":1`, `"schema":2`, 1),
			strings.Replace(original, `"registration_pin":"2`, `"registration_pin":"A`, 1),
			strings.Replace(original, `"registration_pin":"2`, `"registration_pin":"`, 1),
			strings.Replace(original, `"issued_digest":"1`, `"issued_digest":"11`, 1),
			strings.Replace(original, `"grant_count":2`, `"grant_count":-1`, 1),
			strings.Replace(original, `"grant_count":2`, `"grant_count":257`, 1),
			strings.Replace(original, `"grant_count":2`, `"grant_count":2.5`, 1),
			strings.Replace(original, `"stage":"`, `"stage":"x`, 1))
		for _, stage := range stages {
			if stage != stages[i] {
				bad = append(bad, strings.Replace(original, `"stage":"`+stages[i]+`"`, `"stage":"`+stage+`"`, 1))
			}
		}
		for index, pin := range laterPins {
			if index >= i {
				bad = append(bad, strings.TrimSuffix(original, "}")+`,"`+pin+`":"`+strings.Repeat("9", 64)+`"}`)
			}
		}
		for _, value := range bad {
			if value == original {
				continue
			}
			if got, err := DecodeGenerationRecord(value); err == nil {
				t.Fatal("ambiguous generation witness record accepted", i, value, got)
			}
		}
	}
}

func TestOnlyCompleteValidGenerationRecordsEncode(t *testing.T) {
	chain := generationChain()
	withCount := func(record GenerationRecord, count int) GenerationRecord { record.GrantCount = count; return record }
	withKey := func(record GenerationRecord, value string) GenerationRecord {
		record.GenerationKey = value
		return record
	}
	withIssued := func(record GenerationRecord, value string) GenerationRecord {
		record.IssuedDigest = value
		return record
	}
	withRegistration := func(record GenerationRecord, value string) GenerationRecord {
		record.RegistrationPin = value
		return record
	}
	withStage := func(record GenerationRecord, stage GenerationStage) GenerationRecord {
		record.Stage = stage
		return record
	}
	invalid := []GenerationRecord{
		{},
		withStage(chain[0], "x"),
		withKey(chain[0], ""),
		withKey(chain[0], strings.ToUpper(strings.Repeat("e", 64))),
		withIssued(chain[0], ""),
		withRegistration(chain[0], ""),
		withCount(chain[0], -1),
		withCount(chain[0], MaximumGrantCount+1),
	}
	// Each stage label on every other stage's pins is a mismatch: a missing
	// pin for a reached stage or a pin for an unreached one.
	for i := range chain {
		for j := range chain {
			if i != j {
				invalid = append(invalid, withStage(chain[j], chain[i].Stage))
			}
		}
	}
	for _, record := range invalid {
		if value, err := EncodeGenerationRecord(record); err == nil {
			t.Fatal("invalid generation record encoded", record, value)
		}
	}
	if _, err := EncodeGenerationRecord(withCount(chain[0], MaximumGrantCount)); err != nil {
		t.Fatal("the journal's largest grant count must stay encodable", err)
	}
}

// A generation opens only as a registration before any grant.
func TestOnlyTheRootRegistrationOpensAGeneration(t *testing.T) {
	chain := generationChain()
	opening := chain[0]
	opening.GrantCount = 0
	if !opening.Opens() {
		t.Fatal("the root registration was refused")
	}
	for _, record := range append([]GenerationRecord{{}}, chain...) {
		if record.Opens() {
			t.Fatal("a record after the root opened a generation", record.Stage, record.GrantCount)
		}
	}
}

// Registration advances the count by exactly one; every other step moves one
// stage forward with the count, set digest and every earlier pin unchanged.
func TestGenerationRecordsOnlyMoveForwardOneStep(t *testing.T) {
	chain := generationChain()
	first := chain[0]
	first.GrantCount, first.IssuedDigest, first.RegistrationPin = 1, strings.Repeat("8", 64), strings.Repeat("9", 64)
	if !chain[0].Follows(first) {
		t.Fatal("registering one more grant was refused")
	}
	for i := 1; i < len(chain); i++ {
		if !chain[i].Follows(chain[i-1]) {
			t.Fatal("the forward chain was refused", chain[i].Stage)
		}
	}
	type pair struct{ next, previous GenerationRecord }
	refused := []pair{{chain[0], GenerationRecord{}}}
	// Every stage pair other than a single forward step is refused, including
	// repeats of every non-registration stage.
	for i := range chain {
		for j := range chain {
			if i != j+1 && (i != 0 || j != 0) {
				refused = append(refused, pair{chain[i], chain[j]})
			}
		}
	}
	// Registration that repeats, jumps, keeps its pin or keeps its set digest.
	same := chain[0]
	jumped := first
	jumped.GrantCount = 0
	samePin := first
	samePin.RegistrationPin = chain[0].RegistrationPin
	sameDigest := first
	sameDigest.IssuedDigest = chain[0].IssuedDigest
	refused = append(refused, pair{chain[0], same}, pair{chain[0], jumped}, pair{chain[0], samePin}, pair{chain[0], sameDigest}, pair{first, chain[0]})
	// A later step that rewrites the key, the count, the set digest, the
	// registration pin or any earlier pin.
	for i := 1; i < len(chain); i++ {
		for field := 0; field < 4+i-1; field++ {
			next := chain[i]
			other := strings.Repeat("e", 64)
			switch field {
			case 0:
				next.GenerationKey = other
			case 1:
				next.GrantCount++
			case 2:
				next.IssuedDigest = other
			case 3:
				next.RegistrationPin = other
			default:
				setLaterPin(&next, field-4, other)
			}
			refused = append(refused, pair{next, chain[i-1]})
		}
	}
	for _, step := range refused {
		if step.next.Follows(step.previous) {
			t.Fatal("a non-forward generation step was accepted", step.previous.Stage, step.previous.GrantCount, step.next.Stage, step.next.GrantCount)
		}
	}
}

// setLaterPin sets the pin of the stage index places after registration.
func setLaterPin(record *GenerationRecord, index int, value string) {
	switch index {
	case 0:
		record.DrainPin = value
	case 1:
		record.HandoffPin = value
	case 2:
		record.OwnerPin = value
	case 3:
		record.RecoveredPin = value
	case 4:
		record.PublishedPin = value
	}
}
