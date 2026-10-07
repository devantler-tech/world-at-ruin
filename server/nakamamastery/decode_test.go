package nakamamastery

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/internal/savefixturetest"
)

const cleanDocument = `{"schema":1,"weapons":{"axe":{"banked":200,"unbanked":75},"future:weapon":{"banked":100,"unbanked":49}},"stain":{"id":"death-original","points":{"axe":7,"future:weapon":3}}}`

func retainedShapes(t *testing.T, family string, want int) (int, []json.RawMessage) {
	t.Helper()
	fixtures := savefixturetest.Read(t, family)
	if len(fixtures) != 1 {
		t.Fatal("unexpected schema count")
	}
	var shapes []json.RawMessage
	if json.Unmarshal(fixtures[0].Bytes, &shapes) != nil || len(shapes) != want {
		t.Fatal("missing retained shapes")
	}
	return fixtures[0].Version, shapes
}

func TestStrictMasteryGrammar(t *testing.T) {
	expected := State{Schema: 1, Weapons: map[string]Track{"axe": {200, 75}, "future:weapon": {100, 49}}, Stain: Stain{ID: "death-original", Points: map[string]int64{"axe": 7, "future:weapon": 3}}}
	got, err := decodeMasteryDocument(cleanDocument)
	if err != nil || !reflect.DeepEqual(got, expected) {
		t.Fatalf("read = %#v %v", got, err)
	}
	invalid := []string{
		strings.Replace(cleanDocument, `"schema":1`, `"schema":1,"schema":1`, 1),
		strings.Replace(cleanDocument, `"schema":1,`, "", 1),
		strings.Replace(cleanDocument, `"schema":1`, `"extra":0,"schema":1`, 1),
		strings.Replace(cleanDocument, `"banked":200`, `"banked":200.0`, 1),
		strings.Replace(cleanDocument, `"banked":200`, `"banked":null`, 1),
		strings.Replace(cleanDocument, `"unbanked":75`, `"unbanked":75,"unbanked":75`, 1),
		strings.Replace(cleanDocument, `"id":"death-original"`, `"id":null`, 1),
		strings.Replace(cleanDocument, `"axe":7`, `"axe":null`, 1),
		strings.Replace(cleanDocument, `"axe":7`, `"axe":7,"axe":7`, 1),
		strings.Replace(cleanDocument, `"unbanked":75`, `"unbanked":100`, 1),
		strings.Replace(cleanDocument, `"banked":200`, `"banked":201`, 1),
		cleanDocument + ` {}`,
	}
	for _, raw := range invalid {
		if _, err := decodeMasteryDocument(raw); err == nil {
			t.Fatalf("accepted invalid grammar: %s", raw)
		}
	}
}

func TestRetainedMasteryReader(t *testing.T) {
	expected := []State{
		{Schema: 1, Weapons: map[string]Track{}, Stain: Stain{Points: map[string]int64{}}},
		{Schema: 1, Weapons: map[string]Track{"axe": {300, 3}, "future:weapon": {100, 49}}, Stain: Stain{Points: map[string]int64{}}},
		{Schema: 1, Weapons: map[string]Track{"axe": {200, 75}, "future:weapon": {100, 49}}, Stain: Stain{ID: "death-original", Points: map[string]int64{"axe": 7, "future:weapon": 3}}},
	}
	version, shapes := retainedShapes(t, "mastery", len(expected))
	for i, raw := range shapes {
		got, err := decodeMasteryDocument(string(raw))
		if err != nil || !reflect.DeepEqual(got, expected[i]) {
			t.Fatalf("v%d shape %d = %#v %v", version, i, got, err)
		}
	}
}

func TestRetainedMasteryOutcomeReader(t *testing.T) {
	expected := []Outcome{
		{Schema: 1, Kind: "award", Credited: 8, Dropped: map[string]int64{}, Destroyed: map[string]int64{}, State: State{Schema: 1, Weapons: map[string]Track{"axe": {300, 3}, "future:weapon": {100, 49}}, Stain: Stain{Points: map[string]int64{}}}},
		{Schema: 1, Kind: "death", Credited: 0, Dropped: map[string]int64{"axe": 37, "future:weapon": 24}, Destroyed: map[string]int64{"axe": 7, "future:weapon": 3}, State: State{Schema: 1, Weapons: map[string]Track{"axe": {200, 38}, "future:weapon": {100, 25}}, Stain: Stain{ID: "death-event-identity", Points: map[string]int64{"axe": 37, "future:weapon": 24}}}},
		{Schema: 1, Kind: "death", Credited: 0, Dropped: map[string]int64{}, Destroyed: map[string]int64{}, State: State{Schema: 1, Weapons: map[string]Track{"axe": {200, 75}, "future:weapon": {100, 49}}, Stain: Stain{ID: "death-original", Points: map[string]int64{"axe": 7, "future:weapon": 3}}}},
		{Schema: 1, Kind: "reclaim", Credited: 10, Dropped: map[string]int64{}, Destroyed: map[string]int64{}, State: State{Schema: 1, Weapons: map[string]Track{"axe": {200, 82}, "future:weapon": {100, 52}}, Stain: Stain{Points: map[string]int64{}}}},
	}
	version, shapes := retainedShapes(t, "mastery_outcome", len(expected))
	for i, raw := range shapes {
		got, err := decodeOutcome(string(raw))
		if err != nil || !reflect.DeepEqual(got, expected[i]) {
			t.Fatalf("v%d shape %d = %#v %v", version, i, got, err)
		}
	}
}
