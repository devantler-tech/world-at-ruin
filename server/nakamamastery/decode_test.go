package nakamamastery

import (
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/internal/savefixturetest"
)

const cleanDocument = `{"schema":1,"weapons":{"axe":{"banked":200,"unbanked":75},"future:weapon":{"banked":100,"unbanked":49}},"stain":{"id":"death-original","points":{"axe":7,"future:weapon":3}}}`

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
	expected := State{Schema: 1, Weapons: map[string]Track{"axe": {200, 75}, "future:weapon": {100, 49}}, Stain: Stain{ID: "death-original", Points: map[string]int64{"axe": 7, "future:weapon": 3}}}
	for _, fixture := range savefixturetest.Read(t, "mastery") {
		got, err := decodeMasteryDocument(string(fixture.Bytes))
		if err != nil || !reflect.DeepEqual(got, expected) {
			t.Fatalf("v%d = %#v %v", fixture.Version, got, err)
		}
	}
}

func TestRetainedMasteryOutcomeReader(t *testing.T) {
	expected := Outcome{Schema: 1, Kind: "death", Credited: 0, Dropped: map[string]int64{"axe": 37, "future:weapon": 24}, Destroyed: map[string]int64{"axe": 7, "future:weapon": 3}, State: State{Schema: 1, Weapons: map[string]Track{"axe": {200, 38}, "future:weapon": {100, 25}}, Stain: Stain{ID: "death-event-identity", Points: map[string]int64{"axe": 37, "future:weapon": 24}}}}
	for _, fixture := range savefixturetest.Read(t, "mastery_outcome") {
		got, err := decodeOutcome(string(fixture.Bytes))
		if err != nil || !reflect.DeepEqual(got, expected) {
			t.Fatalf("v%d = %#v %v", fixture.Version, got, err)
		}
	}
}
