package nakamamastery

const maxExact int64 = 9007199254740991
const maxWeapons = 64

func transition(state State, event eventPayload, identity string) (State, Outcome, error) {
	if validateState(state) != nil || !validID(identity) {
		return State{}, Outcome{}, ErrInvalid
	}
	next := cloneState(state)
	out := Outcome{Schema: 1, Kind: event.Kind, Dropped: map[string]int64{}, Destroyed: map[string]int64{}}
	switch event.Kind {
	case "award":
		if !validID(event.Weapon) || event.Amount <= 0 || event.Amount > maxExact {
			return State{}, Outcome{}, ErrInvalid
		}
		track, err := add(next.Weapons[event.Weapon], event.Amount)
		if err != nil {
			return State{}, Outcome{}, err
		}
		next.Weapons[event.Weapon] = track
		out.Credited = event.Amount
	case "death":
		if event.Percent < 0 || event.Percent > 100 {
			return State{}, Outcome{}, ErrInvalid
		}
		for weapon, track := range next.Weapons {
			loss := track.Unbanked * int64(event.Percent) / 100
			if loss > 0 {
				out.Dropped[weapon] = loss
				track.Unbanked -= loss
				next.Weapons[weapon] = track
			}
		}
		if len(out.Dropped) > 0 {
			out.Destroyed = clonePoints(next.Stain.Points)
			next.Stain = Stain{ID: identity, Points: clonePoints(out.Dropped)}
		}
	case "reclaim":
		if event.StainID == "" || event.StainID != next.Stain.ID {
			return State{}, Outcome{}, ErrInvalid
		}
		for weapon, amount := range next.Stain.Points {
			track, err := add(next.Weapons[weapon], amount)
			if err != nil {
				return State{}, Outcome{}, err
			}
			next.Weapons[weapon] = track
			out.Credited += amount
		}
		next.Stain = Stain{Points: map[string]int64{}}
	default:
		return State{}, Outcome{}, ErrInvalid
	}
	if validateState(next) != nil {
		return State{}, Outcome{}, ErrInvalid
	}
	out.State = cloneState(next)
	return next, out, nil
}

func add(track Track, amount int64) (Track, error) {
	total := track.Banked + track.Unbanked
	if amount <= 0 || amount > maxExact-total {
		return Track{}, ErrInvalid
	}
	total += amount
	return Track{Banked: total / 100 * 100, Unbanked: total % 100}, nil
}

func clonePoints(points map[string]int64) map[string]int64 {
	result := make(map[string]int64, len(points))
	for k, v := range points {
		result[k] = v
	}
	return result
}
