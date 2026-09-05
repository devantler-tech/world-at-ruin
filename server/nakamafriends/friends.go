// Package nakamafriends is the server-owned boundary over Nakama's friend
// graph. It decides WHOSE graph an operation edits — always the verified
// session identity, never a caller-supplied subject — and WHO may be named —
// another well-formed player — and leaves the edge transitions themselves
// (invite, accept, block, delete) to Nakama, which already keeps them
// durably. The boundary holds no state of its own, so a relationship made
// through it is Nakama's edge and outlives the session that made it.
//
// It is inert until an RPC composes it (#476).
package nakamafriends

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// Graph is the slice of Nakama's runtime friend surface the boundary depends
// on. Nakama's runtime module satisfies it, and so does a test fake.
type Graph interface {
	FriendsAdd(
		ctx context.Context,
		userID string,
		username string,
		ids []string,
		usernames []string,
		metadata map[string]any,
	) error
	FriendsDelete(
		ctx context.Context,
		userID string,
		username string,
		ids []string,
		usernames []string,
	) error
	FriendsBlock(
		ctx context.Context,
		userID string,
		username string,
		ids []string,
		usernames []string,
	) error
	FriendsList(
		ctx context.Context,
		userID string,
		limit int,
		state *int,
		cursor string,
	) ([]*api.Friend, string, error)
	UsersGetFriendStatus(
		ctx context.Context,
		userID string,
		userIDs []string,
	) ([]*api.Friend, error)
}

// State is the closed vocabulary of one relationship, read from the acting
// player's side of the edge. Nakama keeps a directed edge per side, so the
// same pair can read INVITE_SENT from one player and INVITE_RECEIVED from the
// other.
type State int

const (
	// StateNone means the acting player has no edge towards the target.
	StateNone State = iota
	// StateFriend means both players have accepted.
	StateFriend
	// StateInviteSent means the acting player invited and awaits acceptance.
	StateInviteSent
	// StateInviteReceived means the target invited the acting player.
	StateInviteReceived
	// StateBlocked means the acting player has blocked the target.
	StateBlocked
)

// String names the state for logs and wire vocabularies. The names are
// stable: a client that learns them keeps understanding them.
func (s State) String() string {
	switch s {
	case StateNone:
		return "none"
	case StateFriend:
		return "friend"
	case StateInviteSent:
		return "invite_sent"
	case StateInviteReceived:
		return "invite_received"
	case StateBlocked:
		return "blocked"
	default:
		return "unknown"
	}
}

// Friend is one edge in the acting player's graph.
type Friend struct {
	// SubjectID is the other player's Nakama user id, lower-cased.
	SubjectID string
	State     State
}

// Page is one bounded slice of a player's friend list.
type Page struct {
	Friends []Friend
	// Cursor continues the listing; empty means the list is exhausted.
	Cursor string
}

const (
	// DefaultListLimit is the page size List uses when the caller passes 0.
	DefaultListLimit = 50
	// MaxListLimit is the largest page List will ask Nakama for.
	MaxListLimit = 100
)

var (
	// ErrUnauthenticated means the session carries no usable identity, or the
	// caller named a subject other than the session's own.
	ErrUnauthenticated = errors.New(
		"nakama friends: authenticated subject must act for itself",
	)
	// ErrInvalidTarget means the target is not another well-formed player: a
	// subject id that is the caller, the system owner, or not a UUID. Whether a
	// player actually exists at a well-formed id is Nakama's to decide; the
	// boundary never asks, because answering would let anyone enumerate accounts.
	ErrInvalidTarget = errors.New(
		"nakama friends: target must name another player",
	)
	// ErrTargetBlocked means the acting player has blocked the target and must
	// remove the block before inviting; Nakama would otherwise drop the invite
	// silently. Only the acting player's OWN block is visible: a block the
	// target placed is hidden by Nakama on purpose, so an invite towards it
	// succeeds and changes nothing — the blocked player must never learn they
	// are blocked.
	ErrTargetBlocked = errors.New(
		"nakama friends: target is blocked; remove the block first",
	)
	// ErrInvalidLimit means a List page size was outside 0 or 1..MaxListLimit.
	ErrInvalidLimit = fmt.Errorf(
		"nakama friends: limit must be 0 or within 1..%d", MaxListLimit,
	)
	// ErrGraph means Nakama failed or returned a shape the boundary refuses.
	// It never carries Nakama's own text.
	ErrGraph = errors.New("nakama friends: friend graph unavailable")
)

// Boundary edits and reads one player's friend graph through Nakama.
type Boundary struct {
	graph Graph
}

// New builds a friends boundary over Nakama's runtime friend surface.
func New(graph Graph) (*Boundary, error) {
	if graph == nil {
		return nil, errors.New("nakama friends: graph is required")
	}
	return &Boundary{graph: graph}, nil
}

// actor is the verified session identity an operation acts for.
type actor struct {
	subjectID string
	username  string
}

// Invite sends a friend invite to target, or accepts target's pending invite.
// A target the acting player has blocked is refused rather than silently
// dropped. The refusal reads the player's own edge first, so it costs one extra
// graph read on a path a player takes by hand, not per tick; that read and the
// write are not one transaction, so a Block issued by the SAME account from
// another session in between lets Nakama decide the outcome — never a corrupt
// edge, only the silent no-op this check removes in the steady state.
func (b *Boundary) Invite(ctx context.Context, subjectID, targetID string) error {
	who, target, err := b.resolve(ctx, subjectID, targetID)
	if err != nil {
		return err
	}
	state, err := b.status(ctx, who, target)
	if err != nil {
		return err
	}
	if state == StateBlocked {
		return ErrTargetBlocked
	}
	return graphErr(ctx, b.graph.FriendsAdd(
		ctx, who.subjectID, who.username, []string{target}, nil, nil,
	))
}

// Remove ends a friendship, withdraws or declines an invite, or clears a
// block — whichever edge the acting player holds towards target.
func (b *Boundary) Remove(ctx context.Context, subjectID, targetID string) error {
	who, target, err := b.resolve(ctx, subjectID, targetID)
	if err != nil {
		return err
	}
	return graphErr(ctx, b.graph.FriendsDelete(
		ctx, who.subjectID, who.username, []string{target}, nil,
	))
}

// Block records that the acting player wants nothing from target: Nakama
// replaces any edge with a block and drops target's edge back.
func (b *Boundary) Block(ctx context.Context, subjectID, targetID string) error {
	who, target, err := b.resolve(ctx, subjectID, targetID)
	if err != nil {
		return err
	}
	return graphErr(ctx, b.graph.FriendsBlock(
		ctx, who.subjectID, who.username, []string{target}, nil,
	))
}

// Status reads the acting player's edge towards target.
func (b *Boundary) Status(ctx context.Context, subjectID, targetID string) (State, error) {
	who, target, err := b.resolve(ctx, subjectID, targetID)
	if err != nil {
		return StateNone, err
	}
	return b.status(ctx, who, target)
}

// List reads one page of the acting player's graph across every state. A
// limit of 0 selects DefaultListLimit; the cursor is Nakama's and opaque.
func (b *Boundary) List(
	ctx context.Context,
	subjectID string,
	limit int,
	cursor string,
) (Page, error) {
	who, err := b.actingFor(ctx, subjectID)
	if err != nil {
		return Page{}, err
	}
	switch {
	case limit == 0:
		limit = DefaultListLimit
	case limit < 1 || limit > MaxListLimit:
		return Page{}, ErrInvalidLimit
	}
	entries, next, err := b.graph.FriendsList(ctx, who.subjectID, limit, nil, cursor)
	if err != nil {
		return Page{}, graphErr(ctx, err)
	}
	page := Page{Friends: make([]Friend, 0, len(entries)), Cursor: next}
	for _, entry := range entries {
		friend, err := decodeFriend(entry, who.subjectID)
		if err != nil {
			return Page{}, err
		}
		page.Friends = append(page.Friends, friend)
	}
	return page, nil
}

func (b *Boundary) status(ctx context.Context, who actor, target string) (State, error) {
	entries, err := b.graph.UsersGetFriendStatus(ctx, who.subjectID, []string{target})
	if err != nil {
		return StateNone, graphErr(ctx, err)
	}
	switch len(entries) {
	case 0:
		return StateNone, nil
	case 1:
		friend, err := decodeFriend(entries[0], who.subjectID)
		if err != nil || friend.SubjectID != target {
			return StateNone, ErrGraph
		}
		return friend.State, nil
	default:
		return StateNone, ErrGraph
	}
}

// graphErr is the one place a graph failure becomes a boundary error: the
// caller's own cancellation when there is one, ErrGraph otherwise, and nil
// for nil — so no call site can leak Nakama's text by forgetting the wrap.
func graphErr(ctx context.Context, err error) error {
	if err == nil {
		return nil
	}
	return nakamastorage.SanitizeError(ctx, err, ErrGraph)
}

// resolve authenticates the acting identity and validates the target as a
// selector: another well-formed player, never the caller and never the
// system owner.
func (b *Boundary) resolve(
	ctx context.Context,
	subjectID string,
	targetID string,
) (actor, string, error) {
	who, err := b.actingFor(ctx, subjectID)
	if err != nil {
		return actor{}, "", err
	}
	target := strings.ToLower(targetID)
	if !nakamastorage.ValidSubjectID(target) || target == who.subjectID {
		return actor{}, "", ErrInvalidTarget
	}
	return who, target, nil
}

// actingFor derives the acting identity from the runtime session and requires
// the caller to have named that same subject, so a deputy cannot be pointed
// at another player's graph.
func (b *Boundary) actingFor(ctx context.Context, requestedSubjectID string) (actor, error) {
	if ctx == nil {
		return actor{}, ErrUnauthenticated
	}
	callerID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok {
		return actor{}, ErrUnauthenticated
	}
	username, ok := ctx.Value(runtime.RUNTIME_CTX_USERNAME).(string)
	if !ok || nakamastorage.InvalidIdentityPart(username) {
		return actor{}, ErrUnauthenticated
	}
	callerID = strings.ToLower(callerID)
	if !nakamastorage.ValidSubjectID(callerID) ||
		callerID != strings.ToLower(requestedSubjectID) {
		return actor{}, ErrUnauthenticated
	}
	return actor{subjectID: callerID, username: username}, nil
}

// decodeFriend maps one Nakama friend entry onto the closed vocabulary,
// refusing any shape that is not another well-formed player in a known state.
func decodeFriend(entry *api.Friend, subjectID string) (Friend, error) {
	if entry == nil || entry.GetUser() == nil || entry.GetState() == nil {
		return Friend{}, ErrGraph
	}
	other := strings.ToLower(entry.GetUser().GetId())
	if !nakamastorage.ValidSubjectID(other) || other == subjectID {
		return Friend{}, ErrGraph
	}
	state, ok := stateFromNakama(entry.GetState().GetValue())
	if !ok {
		return Friend{}, ErrGraph
	}
	return Friend{SubjectID: other, State: state}, nil
}

func stateFromNakama(value int32) (State, bool) {
	switch api.Friend_State(value) {
	case api.Friend_FRIEND:
		return StateFriend, true
	case api.Friend_INVITE_SENT:
		return StateInviteSent, true
	case api.Friend_INVITE_RECEIVED:
		return StateInviteReceived, true
	case api.Friend_BLOCKED:
		return StateBlocked, true
	default:
		return StateNone, false
	}
}
