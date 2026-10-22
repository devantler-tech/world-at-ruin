package custodywitness

import (
	"context"
	"errors"
	"maps"
	"strings"
	"testing"
)

// generationHistory holds every record a generation that issued two grants
// writes, in write order: the root registration, two grant registrations and
// then one record per later stage.
func generationHistory() []GenerationRecord {
	root := GenerationRecord{
		GenerationKey: key, Stage: GenerationRegistered,
		IssuedDigest: strings.Repeat("8", 64), RegistrationPin: strings.Repeat("9", 64),
	}
	first := root
	first.GrantCount, first.IssuedDigest, first.RegistrationPin = 1, strings.Repeat("e", 64), strings.Repeat("f", 64)
	return append([]GenerationRecord{root, first}, generationChain()...)
}

// writeGenerations stores records in order through the client and returns the
// table holding them.
func writeGenerations(t *testing.T, records ...GenerationRecord) *fakeTable {
	t.Helper()
	table := newFake()
	client := newClient(t, table)
	previous := GenerationRecord{}
	for _, record := range records {
		if _, err := client.WriteGeneration(context.Background(), previous, record); err != nil {
			t.Fatal("setup write refused", record.Stage, record.GrantCount, err)
		}
		previous = record
	}
	return table
}

func TestGenerationAdvancesOnlyFromTheExactPreviousRecord(t *testing.T) {
	table := newFake()
	client := newClient(t, table)
	ctx := context.Background()
	previous := GenerationRecord{}
	for _, next := range generationHistory() {
		got, err := client.WriteGeneration(ctx, previous, next)
		if err != nil || got != next {
			t.Fatal("forward step refused", next.Stage, next.GrantCount, err)
		}
		if verdict := client.CompareGeneration(ctx, next); verdict != Verified {
			t.Fatal("acknowledged record not verified", next.Stage, next.GrantCount, verdict)
		}
		previous = next
	}
	if table.puts != len(generationHistory()) {
		t.Fatal("each acknowledged step must be exactly one write", table.puts)
	}
}

// Every refusal leaves the stored record exactly as it was.
func TestGenerationRefusalsLeaveTheWitnessUnchanged(t *testing.T) {
	ctx := context.Background()
	history := generationHistory()
	root, first, second, drained, handoff, published := history[0], history[1], history[2], history[3], history[4], history[7]
	otherRoot := root
	otherRoot.RegistrationPin = strings.Repeat("0", 64)
	skippedCount := second
	skippedCount.GrantCount = 3
	rewrittenPrevious := first
	rewrittenPrevious.RegistrationPin = strings.Repeat("0", 64)
	for name, attempt := range map[string]struct {
		stored         []GenerationRecord
		previous, next GenerationRecord
	}{
		"second root with another pin":        {history[:1], GenerationRecord{}, otherRoot},
		"repeated root":                       {history[:1], GenerationRecord{}, root},
		"grant registration opening a record": {nil, GenerationRecord{}, first},
		"later stage opening a record":        {nil, GenerationRecord{}, drained},
		"repeated registration":               {history[:2], root, first},
		"registration skipping a grant":       {history[:2], first, skippedCount},
		"rewritten previous pin":              {history[:2], rewrittenPrevious, second},
		"skipped drain":                       {history[:3], second, handoff},
		"registration after drain":            {history[:4], drained, second},
		"write after publication":             {history, published, published},
		"step without stored record":          {nil, root, first},
		"backward step":                       {history[:4], drained, second},
	} {
		table := writeGenerations(t, attempt.stored...)
		before := table.snapshot()
		got, err := newClient(t, table).WriteGeneration(ctx, attempt.previous, attempt.next)
		if !errors.Is(err, ErrUnknown) || got != (GenerationRecord{}) {
			t.Fatal(name, "refused step acknowledged", got)
		}
		if !maps.Equal(before, table.snapshot()) {
			t.Fatal(name, "refused step changed the witness")
		}
	}
}

// A zone lifetime key and a generation key are both 64-character digests, so
// the families must never share a stored key or be read as each other.
func TestZoneAndGenerationRecordsWithTheSameDigestNeverReadAsEachOther(t *testing.T) {
	ctx := context.Background()
	root := generationHistory()[0]
	if root.GenerationKey != enrolled.LifetimeKey {
		t.Fatal("fixture must use one digest for both families")
	}

	table := newFake()
	client := newClient(t, table)
	if _, err := client.Write(ctx, Record{}, enrolled); err != nil {
		t.Fatal("zone enrollment refused", err)
	}
	if _, err := client.WriteGeneration(ctx, GenerationRecord{}, root); err != nil {
		t.Fatal("generation root refused beside a zone record with the same digest", err)
	}
	stored := table.snapshot()
	if len(stored) != 2 {
		t.Fatal("families shared a stored key", stored)
	}
	zone, _ := EncodeRecord(enrolled)
	generation, _ := EncodeGenerationRecord(root)
	if stored[key] != zone || stored[generationStorageKey(key)] != generation {
		t.Fatal("zone records must keep their shipped bare key and generations their own namespace", stored)
	}
	if client.Compare(ctx, enrolled) != Verified || client.CompareGeneration(ctx, root) != Verified {
		t.Fatal("a family read the other family's record")
	}

	// Each family's record planted where the other family's is expected is
	// conflicting, never absent and never verified.
	swapped := newFake()
	swapped.items[key] = generation
	swapped.items[generationStorageKey(key)] = zone
	swappedClient := newClient(t, swapped)
	if got := swappedClient.Compare(ctx, enrolled); got != Conflicting {
		t.Fatal("generation record read as a zone record", got)
	}
	if got := swappedClient.CompareGeneration(ctx, root); got != Conflicting {
		t.Fatal("zone record read as a generation record", got)
	}
	// Neither family's record satisfies the other family's write condition.
	if _, err := swappedClient.Write(ctx, Record{}, enrolled); !errors.Is(err, ErrUnknown) {
		t.Fatal("zone enrollment acknowledged over a generation record under its key")
	}
	if _, err := swappedClient.WriteGeneration(ctx, GenerationRecord{}, root); !errors.Is(err, ErrUnknown) {
		t.Fatal("generation root acknowledged over a zone record in its namespace")
	}
	if swapped.items[key] != generation || swapped.items[generationStorageKey(key)] != zone {
		t.Fatal("a refused cross-family write changed the witness")
	}
}

func TestGenerationCompareClassifiesEveryOutcome(t *testing.T) {
	ctx := context.Background()
	history := generationHistory()
	first, second, drained, handoff, owner, published := history[1], history[2], history[3], history[4], history[5], history[7]
	rewrittenHandoff := handoff
	rewrittenHandoff.HandoffPin = strings.Repeat("0", 64)
	rewrittenDrainBehind := owner
	rewrittenDrainBehind.DrainPin = strings.Repeat("0", 64)
	otherSet := second
	otherSet.IssuedDigest = strings.Repeat("0", 64)
	otherRegistration := second
	otherRegistration.RegistrationPin = strings.Repeat("0", 64)
	for name, c := range map[string]struct {
		stored   []GenerationRecord
		expected GenerationRecord
		want     Verdict
	}{
		"verified registration":            {history[:3], second, Verified},
		"verified publication":             {history, published, Verified},
		"rolled back to drained":           {history, drained, WitnessAhead},
		"rolled back to last registration": {history[:6], second, WitnessAhead},
		"never witnessed drain":            {history[:3], drained, WitnessBehind},
		"never witnessed handoff":          {history[:4], handoff, WitnessBehind},
		"never witnessed publication":      {history[:6], published, WitnessBehind},
		// Neither record retains the other's earlier registration pins or
		// issued-grant set digests, so no differing grant count proves that
		// one chain extends the other.
		"higher stored grant count":              {history[:3], first, Conflicting},
		"higher stored grant count, later stage": {history[:5], first, Conflicting},
		"lower stored grant count":               {history[:2], second, Conflicting},
		"lower stored grant count, later stage":  {history[:2], drained, Conflicting},
		"rewritten pin at the same stage":        {history[:5], rewrittenHandoff, Conflicting},
		"rewritten earlier pin, ahead":           {history[:6], rewrittenHandoff, Conflicting},
		"rewritten earlier pin, behind":          {history[:5], rewrittenDrainBehind, Conflicting},
		"other issued-grant set":                 {history[:3], otherSet, Conflicting},
		"other registration pin":                 {history[:3], otherRegistration, Conflicting},
		"absent":                                 {nil, second, Absent},
		"invalid expected":                       {history[:3], GenerationRecord{}, Unavailable},
	} {
		if got := newClient(t, writeGenerations(t, c.stored...)).CompareGeneration(ctx, c.expected); got != c.want {
			t.Fatal(name, got, "want", c.want)
		}
	}

	storageKey := generationStorageKey(key)
	corrupt := newFake()
	corrupt.items[storageKey] = `{"schema":2}`
	if got := newClient(t, corrupt).CompareGeneration(ctx, second); got != Conflicting {
		t.Fatal("unreadable record not conflicting", got)
	}
	foreign := newFake()
	other := second
	other.GenerationKey = strings.Repeat("e", 64)
	value, _ := EncodeGenerationRecord(other)
	foreign.items[storageKey] = value
	if got := newClient(t, foreign).CompareGeneration(ctx, second); got != Conflicting {
		t.Fatal("record for another generation not conflicting", got)
	}

	replaced := writeGenerations(t, history[:3]...)
	replaced.identity = replacementTable
	if got := newClient(t, replaced).CompareGeneration(ctx, second); got != TableReplaced {
		t.Fatal("replaced table not detected", got)
	}
	during := writeGenerations(t, history[:3]...)
	during.onGet = func() { during.identity = replacementTable }
	if got := newClient(t, during).CompareGeneration(ctx, second); got != TableReplaced {
		t.Fatal("read from a replacement table not reported replaced", got)
	}
	for name, fault := range map[string]func(*fakeTable){
		"identity": func(f *fakeTable) { f.identityErr = errors.New("auth refused") },
		"read":     func(f *fakeTable) { f.getErr = errors.New("throttled") },
	} {
		table := writeGenerations(t, history[:3]...)
		fault(table)
		if got := newClient(t, table).CompareGeneration(ctx, second); got != Unavailable {
			t.Fatal(name, "failure not unavailable", got)
		}
	}
}

// Lost replies, refused conditions and replaced tables end exactly as they do
// for zone records: one exact re-read decides, and nothing is retried.
func TestGenerationWriteFailuresEndAsForTheZoneFamily(t *testing.T) {
	ctx := context.Background()
	root := generationHistory()[0]

	committed := newFake()
	committed.commitThenLose = true
	if got, err := newClient(t, committed).WriteGeneration(ctx, GenerationRecord{}, root); err != nil || got != root {
		t.Fatal("committed write with a lost reply was not acknowledged", err)
	}
	if committed.puts != 1 || committed.gets != 1 {
		t.Fatal("lost reply was retried or re-read more than once", committed.puts, committed.gets)
	}

	lost := newFake()
	lost.loseWithoutCommit = true
	if got, err := newClient(t, lost).WriteGeneration(ctx, GenerationRecord{}, root); !errors.Is(err, ErrUnknown) || got != (GenerationRecord{}) {
		t.Fatal("uncommitted write acknowledged")
	}
	if lost.puts != 1 || lost.gets != 1 || len(lost.snapshot()) != 0 {
		t.Fatal("uncommitted write was retried", lost.puts, lost.gets)
	}

	raced := newFake()
	raced.loseWithoutCommit = true
	competing := root
	competing.RegistrationPin = strings.Repeat("0", 64)
	value, _ := EncodeGenerationRecord(competing)
	raced.items[generationStorageKey(key)] = value
	if _, err := newClient(t, raced).WriteGeneration(ctx, GenerationRecord{}, root); !errors.Is(err, ErrUnknown) {
		t.Fatal("another writer's record acknowledged")
	}

	refused := writeGenerations(t, root)
	if _, err := newClient(t, refused).WriteGeneration(ctx, GenerationRecord{}, root); !errors.Is(err, ErrUnknown) || refused.puts != 2 || refused.gets != 0 {
		t.Fatal("a refused condition must end the call without a re-read", refused.puts, refused.gets, err)
	}

	writer := newFake()
	writer.onPut = func() { writer.identity = replacementTable }
	if got, err := newClient(t, writer).WriteGeneration(ctx, GenerationRecord{}, root); !errors.Is(err, ErrUnknown) || got != (GenerationRecord{}) {
		t.Fatal("write that reached a replacement table acknowledged", got, err)
	}
	reread := newFake()
	reread.commitThenLose = true
	reread.onGet = func() { reread.identity = replacementTable }
	if got, err := newClient(t, reread).WriteGeneration(ctx, GenerationRecord{}, root); !errors.Is(err, ErrUnknown) || got != (GenerationRecord{}) {
		t.Fatal("re-read from a replacement table acknowledged", got, err)
	}
	for name, fault := range map[string]func(*fakeTable){
		"replaced before the write": func(f *fakeTable) { f.identity = replacementTable },
		"identity failure":          func(f *fakeTable) { f.identityErr = errors.New("throttled") },
	} {
		table := newFake()
		fault(table)
		if got, err := newClient(t, table).WriteGeneration(ctx, GenerationRecord{}, root); err == nil || got != (GenerationRecord{}) || table.puts != 0 {
			t.Fatal(name, "write reached or was acknowledged by an unpinned table", table.puts)
		}
	}

	table := newFake()
	canceled, cancel := context.WithCancel(ctx)
	defer cancel()
	table.onPut = cancel
	if got, err := newClient(t, table).WriteGeneration(canceled, GenerationRecord{}, root); err != nil || got != root || table.puts != 1 || table.gets != 1 {
		t.Fatal("a commit canceled before its reply was not resolved by one re-read", err, table.puts, table.gets)
	}
}
