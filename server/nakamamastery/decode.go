package nakamamastery

import (
	"encoding/json"
	"strings"
	"unicode"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
)

func validID(value string) bool {
	if value == "" || len(value) > 128 || strings.TrimSpace(value) != value {
		return false
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func validateState(state State) error {
	if state.Schema != 1 || state.Weapons == nil || len(state.Weapons) > maxWeapons || state.Stain.Points == nil || len(state.Stain.Points) > maxWeapons {
		return ErrInvalid
	}
	for weapon, track := range state.Weapons {
		if !validID(weapon) || track.Banked < 0 || track.Banked > maxExact || track.Banked%100 != 0 || track.Unbanked < 0 || track.Unbanked >= 100 || track.Unbanked > maxExact-track.Banked {
			return ErrInvalid
		}
	}
	if (state.Stain.ID == "") != (len(state.Stain.Points) == 0) || (state.Stain.ID != "" && !validID(state.Stain.ID)) {
		return ErrInvalid
	}
	for weapon, amount := range state.Stain.Points {
		if _, ok := state.Weapons[weapon]; !ok || amount <= 0 || amount >= 100 {
			return ErrInvalid
		}
	}
	return nil
}

// fields refuses duplicate, missing and unknown members before typed decoding.
// A nil vocabulary accepts dynamic keys, still bounded and duplicate-free.
func fields(value string, vocabulary []string) (map[string]json.RawMessage, error) {
	if len(value) > 65536 {
		return nil, ErrInvalid
	}
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return nil, ErrInvalid
	}
	result := map[string]json.RawMessage{}
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, ErrInvalid
		}
		name, ok := token.(string)
		if !ok {
			return nil, ErrInvalid
		}
		if _, found := result[name]; found {
			return nil, ErrInvalid
		}
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil {
			return nil, ErrInvalid
		}
		if strings.TrimSpace(string(raw)) == "null" {
			return nil, ErrInvalid
		}
		result[name] = raw
		if len(result) > maxWeapons {
			return nil, ErrInvalid
		}
	}
	if nakamastorage.EndObject(decoder) != nil {
		return nil, ErrInvalid
	}
	if vocabulary != nil {
		if len(result) != len(vocabulary) {
			return nil, ErrInvalid
		}
		for _, name := range vocabulary {
			if _, ok := result[name]; !ok {
				return nil, ErrInvalid
			}
		}
	}
	return result, nil
}

func decodeMasteryDocument(value string) (State, error) {
	document, err := fields(value, []string{"schema", "weapons", "stain"})
	if err != nil {
		return State{}, err
	}
	weapons, err := fields(string(document["weapons"]), nil)
	if err != nil {
		return State{}, err
	}
	for _, raw := range weapons {
		if _, err := fields(string(raw), []string{"banked", "unbanked"}); err != nil {
			return State{}, err
		}
	}
	stain, err := fields(string(document["stain"]), []string{"id", "points"})
	if err != nil {
		return State{}, err
	}
	if _, err := fields(string(stain["points"]), nil); err != nil {
		return State{}, err
	}
	var state State
	if json.Unmarshal([]byte(value), &state) != nil || validateState(state) != nil {
		return State{}, ErrInvalid
	}
	return state, nil
}

func decodeOutcome(value string) (Outcome, error) {
	document, err := fields(value, []string{"schema", "kind", "credited", "dropped", "destroyed", "state"})
	if err != nil {
		return Outcome{}, err
	}
	state, err := decodeMasteryDocument(string(document["state"]))
	if err != nil {
		return Outcome{}, err
	}
	for _, name := range []string{"dropped", "destroyed"} {
		if _, err := fields(string(document[name]), nil); err != nil {
			return Outcome{}, err
		}
	}
	var out Outcome
	if json.Unmarshal([]byte(value), &out) != nil || out.Schema != 1 || out.Credited < 0 || out.Credited > maxExact ||
		(out.Kind != "award" && out.Kind != "death" && out.Kind != "reclaim") {
		return Outcome{}, ErrInvalid
	}
	for _, points := range []map[string]int64{out.Dropped, out.Destroyed} {
		for weapon, amount := range points {
			if !validID(weapon) || amount <= 0 || amount >= 100 {
				return Outcome{}, ErrInvalid
			}
		}
	}
	if out.Kind != "death" && (len(out.Dropped) > 0 || len(out.Destroyed) > 0) || out.Kind == "death" && out.Credited != 0 {
		return Outcome{}, ErrInvalid
	}
	if out.Kind == "death" && len(out.Dropped) == 0 && len(out.Destroyed) != 0 {
		return Outcome{}, ErrInvalid
	}
	for _, points := range []map[string]int64{out.Dropped, out.Destroyed} {
		for weapon := range points {
			if _, ok := state.Weapons[weapon]; !ok {
				return Outcome{}, ErrInvalid
			}
		}
	}
	if out.Kind != "death" && out.Credited == 0 {
		return Outcome{}, ErrInvalid
	}
	out.State = state
	return out, nil
}
