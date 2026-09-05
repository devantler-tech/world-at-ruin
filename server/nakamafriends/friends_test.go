package nakamafriends

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

const (
	alice         = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
	bob           = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
	carol         = "cccccccc-3333-4333-8333-cccccccccccc"
	dave          = "dddddddd-4444-4444-8444-dddddddddddd"
	aliceUsername = "alice"
	bobUsername   = "bob"
)

// sessionValues stands in for the values Nakama's runtime places on an RPC
// context. Only the two keys the boundary reads are carried; everything else
// falls through to the parent.
type sessionValues struct {
	context.Context
	values map[string]any
}

func (c sessionValues) Value(key any) any {
	name, ok := key.(string)
	if ok {
		if value, present := c.values[name]; present {
			return value
		}
	}
	return c.Context.Value(key)
}

func session(userID, username string) context.Context {
	return sessionValues{
		Context: context.Background(),
		values: map[string]any{
			runtime.RUNTIME_CTX_USER_ID:  userID,
			runtime.RUNTIME_CTX_USERNAME: username,
		},
	}
}

func sessionWith(parent context.Context, userID, username string) context.Context {
	return sessionValues{
		Context: parent,
		values: map[string]any{
			runtime.RUNTIME_CTX_USER_ID:  userID,
			runtime.RUNTIME_CTX_USERNAME: username,
		},
	}
}

// fakeGraph is an in-memory friend graph that keeps the edge transitions
// Nakama's own friends API documents: an invite creates a sent/received pair,
// the reciprocal invite accepts it, a block replaces the blocker's edge and
// drops the other side's, a delete removes the caller's edge and the other
// side's unless that side has blocked, and an invite towards a player who has
// blocked the caller is dropped. It also validates its inputs the way the
// runtime module does, so a boundary that hands it an id it should have
// refused fails here rather than passing by accident.
type fakeGraph struct {
	edges map[string]map[string]int32
	calls []string
	err   error

	// statusOverride and listOverride, when non-nil, replace the graph's own
	// answer so a test can hand the boundary a malformed shape.
	statusOverride []*api.Friend
	listOverride   []*api.Friend
	lastListLimit  int
	lastListCursor string
}

func newFakeGraph() *fakeGraph {
	return &fakeGraph{edges: make(map[string]map[string]int32)}
}

func (g *fakeGraph) record(format string, args ...any) {
	g.calls = append(g.calls, fmt.Sprintf(format, args...))
}

// lowerSubjectID reports whether id is the lower-cased subject id form the
// boundary promises to hand the graph.
func lowerSubjectID(id string) bool {
	return nakamastorage.ValidSubjectID(id) && id == strings.ToLower(id)
}

// checkMutationArgs validates what every friend mutation hands the runtime
// module, the way Nakama does, and returns the single target it names.
func (g *fakeGraph) checkMutationArgs(
	userID string,
	username string,
	ids []string,
	usernames []string,
	metadata map[string]any,
) (string, error) {
	if len(usernames) != 0 || metadata != nil {
		return "", errors.New("fake graph: the boundary must select by id only")
	}
	if !lowerSubjectID(userID) {
		return "", fmt.Errorf("fake graph: acting user %q is not a lowercase subject id", userID)
	}
	if strings.TrimSpace(username) == "" {
		return "", errors.New("fake graph: acting username is required")
	}
	if len(ids) != 1 {
		return "", fmt.Errorf("fake graph: expected exactly one target, got %d", len(ids))
	}
	target := ids[0]
	if !lowerSubjectID(target) {
		return "", fmt.Errorf("fake graph: target %q is not a lowercase subject id", target)
	}
	if target == userID {
		return "", errors.New("fake graph: cannot add self as friend")
	}
	return target, nil
}

func (g *fakeGraph) edge(source, destination string) (int32, bool) {
	state, ok := g.edges[source][destination]
	return state, ok
}

func (g *fakeGraph) setEdge(source, destination string, state int32) {
	if g.edges[source] == nil {
		g.edges[source] = make(map[string]int32)
	}
	g.edges[source][destination] = state
}

func (g *fakeGraph) dropEdge(source, destination string) {
	delete(g.edges[source], destination)
}

func (g *fakeGraph) FriendsAdd(
	_ context.Context,
	userID string,
	username string,
	ids []string,
	usernames []string,
	metadata map[string]any,
) error {
	g.record("add %s -> %v", userID, ids)
	if g.err != nil {
		return g.err
	}
	target, err := g.checkMutationArgs(userID, username, ids, usernames, metadata)
	if err != nil {
		return err
	}
	reverse, hasReverse := g.edge(target, userID)
	switch {
	case hasReverse && reverse == int32(api.Friend_INVITE_SENT):
		g.setEdge(userID, target, int32(api.Friend_FRIEND))
		g.setEdge(target, userID, int32(api.Friend_FRIEND))
	case hasReverse && reverse == int32(api.Friend_BLOCKED):
		// Nakama drops an invite towards a player who has blocked the caller.
	default:
		if _, exists := g.edge(userID, target); exists {
			return nil
		}
		g.setEdge(userID, target, int32(api.Friend_INVITE_SENT))
		g.setEdge(target, userID, int32(api.Friend_INVITE_RECEIVED))
	}
	return nil
}

func (g *fakeGraph) FriendsDelete(
	_ context.Context,
	userID string,
	username string,
	ids []string,
	usernames []string,
) error {
	g.record("delete %s -> %v", userID, ids)
	if g.err != nil {
		return g.err
	}
	target, err := g.checkMutationArgs(userID, username, ids, usernames, nil)
	if err != nil {
		return err
	}
	g.dropEdge(userID, target)
	if reverse, ok := g.edge(target, userID); ok && reverse != int32(api.Friend_BLOCKED) {
		g.dropEdge(target, userID)
	}
	return nil
}

func (g *fakeGraph) FriendsBlock(
	_ context.Context,
	userID string,
	username string,
	ids []string,
	usernames []string,
) error {
	g.record("block %s -> %v", userID, ids)
	if g.err != nil {
		return g.err
	}
	target, err := g.checkMutationArgs(userID, username, ids, usernames, nil)
	if err != nil {
		return err
	}
	g.setEdge(userID, target, int32(api.Friend_BLOCKED))
	g.dropEdge(target, userID)
	return nil
}

func friendOf(destination string, state int32) *api.Friend {
	return &api.Friend{
		User:  &api.User{Id: destination},
		State: wrapperspb.Int32(state),
	}
}

func (g *fakeGraph) FriendsList(
	_ context.Context,
	userID string,
	limit int,
	state *int,
	cursor string,
) ([]*api.Friend, string, error) {
	g.record("list %s limit=%d cursor=%q", userID, limit, cursor)
	g.lastListLimit = limit
	g.lastListCursor = cursor
	if g.err != nil {
		return nil, "", g.err
	}
	if g.listOverride != nil {
		return g.listOverride, "", nil
	}
	if state != nil {
		return nil, "", errors.New("fake graph: the boundary lists every state")
	}
	if !lowerSubjectID(userID) {
		return nil, "", fmt.Errorf("fake graph: acting user %q is not a lowercase subject id", userID)
	}
	if limit < 1 || limit > 100 {
		return nil, "", fmt.Errorf("fake graph: limit %d outside 1..100", limit)
	}
	destinations := make([]string, 0, len(g.edges[userID]))
	for destination := range g.edges[userID] {
		destinations = append(destinations, destination)
	}
	sort.Strings(destinations)
	start := 0
	if cursor != "" {
		parsed, err := strconv.Atoi(cursor)
		if err != nil || parsed < 0 || parsed > len(destinations) {
			return nil, "", errors.New("fake graph: malformed cursor")
		}
		start = parsed
	}
	end := start + limit
	if end > len(destinations) {
		end = len(destinations)
	}
	friends := make([]*api.Friend, 0, end-start)
	for _, destination := range destinations[start:end] {
		friends = append(friends, friendOf(destination, g.edges[userID][destination]))
	}
	next := ""
	if end < len(destinations) {
		next = strconv.Itoa(end)
	}
	return friends, next, nil
}

func (g *fakeGraph) UsersGetFriendStatus(
	_ context.Context,
	userID string,
	userIDs []string,
) ([]*api.Friend, error) {
	g.record("status %s -> %v", userID, userIDs)
	if g.err != nil {
		return nil, g.err
	}
	if g.statusOverride != nil {
		return g.statusOverride, nil
	}
	if len(userIDs) != 1 {
		return nil, fmt.Errorf("fake graph: expected exactly one target, got %d", len(userIDs))
	}
	target := userIDs[0]
	if !lowerSubjectID(userID) || !lowerSubjectID(target) {
		return nil, errors.New("fake graph: ids must be lowercase subject ids")
	}
	state, ok := g.edge(userID, target)
	if !ok {
		return []*api.Friend{}, nil
	}
	return []*api.Friend{friendOf(target, state)}, nil
}

func newBoundary(t *testing.T, graph Graph) *Boundary {
	t.Helper()
	boundary, err := New(graph)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return boundary
}

func mustStatus(t *testing.T, boundary *Boundary, ctx context.Context, subject, target string) State {
	t.Helper()
	state, err := boundary.Status(ctx, subject, target)
	if err != nil {
		t.Fatalf("Status(%s -> %s): %v", subject, target, err)
	}
	return state
}

func TestFakeGraphRejectsWhatTheRuntimeModuleRejects(t *testing.T) {
	graph := newFakeGraph()
	cases := map[string]error{
		"self":      graph.FriendsAdd(context.Background(), alice, aliceUsername, []string{alice}, nil, nil),
		"uppercase": graph.FriendsAdd(context.Background(), alice, aliceUsername, []string{strings.ToUpper(bob)}, nil, nil),
		"system":    graph.FriendsAdd(context.Background(), alice, aliceUsername, []string{nakamastorage.SystemOwnerID}, nil, nil),
		"blank user": graph.FriendsAdd(
			context.Background(), alice, "  ", []string{bob}, nil, nil,
		),
		"two targets": graph.FriendsAdd(
			context.Background(), alice, aliceUsername, []string{bob, carol}, nil, nil,
		),
	}
	for name, err := range cases {
		if err == nil {
			t.Errorf("%s: fake accepted an input Nakama refuses", name)
		}
	}
	if len(graph.edges) != 0 {
		t.Fatalf("refused inputs mutated the graph: %v", graph.edges)
	}
}

func TestInviteCreatesAPendingInviteAndTheReciprocalInviteMakesFriends(t *testing.T) {
	graph := newFakeGraph()
	boundary := newBoundary(t, graph)
	aliceCtx := session(alice, aliceUsername)
	bobCtx := session(bob, bobUsername)

	if err := boundary.Invite(aliceCtx, alice, bob); err != nil {
		t.Fatalf("alice invites bob: %v", err)
	}
	if got := mustStatus(t, boundary, aliceCtx, alice, bob); got != StateInviteSent {
		t.Fatalf("alice -> bob after invite = %v, want %v", got, StateInviteSent)
	}
	if got := mustStatus(t, boundary, bobCtx, bob, alice); got != StateInviteReceived {
		t.Fatalf("bob -> alice after invite = %v, want %v", got, StateInviteReceived)
	}

	if err := boundary.Invite(bobCtx, bob, alice); err != nil {
		t.Fatalf("bob accepts alice: %v", err)
	}
	if got := mustStatus(t, boundary, aliceCtx, alice, bob); got != StateFriend {
		t.Fatalf("alice -> bob after acceptance = %v, want %v", got, StateFriend)
	}
	if got := mustStatus(t, boundary, bobCtx, bob, alice); got != StateFriend {
		t.Fatalf("bob -> alice after acceptance = %v, want %v", got, StateFriend)
	}

	page, err := boundary.List(aliceCtx, alice, 0, "")
	if err != nil {
		t.Fatalf("alice lists: %v", err)
	}
	if len(page.Friends) != 1 || page.Friends[0] != (Friend{SubjectID: bob, State: StateFriend}) || page.Cursor != "" {
		t.Fatalf("alice's list = %+v, want exactly bob as a friend with no cursor", page)
	}

	// The boundary holds no state of its own: a fresh boundary over the same
	// graph — a new process, a later session — reads the same relationship.
	fresh := newBoundary(t, graph)
	if got := mustStatus(t, fresh, bobCtx, bob, alice); got != StateFriend {
		t.Fatalf("fresh boundary reads bob -> alice = %v, want %v", got, StateFriend)
	}
}

func TestEveryOperationRefusesActingForAnotherSubject(t *testing.T) {
	cases := map[string]context.Context{
		"another player's session": session(bob, bobUsername),
		"no session identity":      context.Background(),
		"malformed session id":     session("not-a-subject", aliceUsername),
		"system owner session":     session(nakamastorage.SystemOwnerID, aliceUsername),
		"blank username":           session(alice, "   "),
		"missing username":         session(alice, ""),
	}
	for name, ctx := range cases {
		graph := newFakeGraph()
		boundary := newBoundary(t, graph)
		operations := map[string]error{}
		operations["invite"] = boundary.Invite(ctx, alice, carol)
		operations["remove"] = boundary.Remove(ctx, alice, carol)
		operations["block"] = boundary.Block(ctx, alice, carol)
		_, operations["status"] = boundary.Status(ctx, alice, carol)
		_, operations["list"] = boundary.List(ctx, alice, 10, "")
		for operation, err := range operations {
			if !errors.Is(err, ErrUnauthenticated) {
				t.Errorf("%s / %s: err = %v, want ErrUnauthenticated", name, operation, err)
			}
		}
		if len(graph.calls) != 0 {
			t.Errorf("%s: graph was called before the refusal: %v", name, graph.calls)
		}
	}
}

func TestEveryOperationRefusesAnInvalidTargetBeforeTheGraph(t *testing.T) {
	targets := map[string]string{
		"self":         alice,
		"self, upper":  strings.ToUpper(alice),
		"system owner": nakamastorage.SystemOwnerID,
		"empty":        "",
		"not a uuid":   "bob",
		"too long":     bob + "0",
	}
	ctx := session(alice, aliceUsername)
	for name, target := range targets {
		graph := newFakeGraph()
		boundary := newBoundary(t, graph)
		operations := map[string]error{}
		operations["invite"] = boundary.Invite(ctx, alice, target)
		operations["remove"] = boundary.Remove(ctx, alice, target)
		operations["block"] = boundary.Block(ctx, alice, target)
		_, operations["status"] = boundary.Status(ctx, alice, target)
		for operation, err := range operations {
			if !errors.Is(err, ErrInvalidTarget) {
				t.Errorf("%s / %s: err = %v, want ErrInvalidTarget", name, operation, err)
			}
		}
		if len(graph.calls) != 0 {
			t.Errorf("%s: graph was called before the refusal: %v", name, graph.calls)
		}
	}
}

func TestIdentitiesAreLowercasedBeforeTheyReachTheGraph(t *testing.T) {
	graph := newFakeGraph()
	boundary := newBoundary(t, graph)
	ctx := session(strings.ToUpper(alice), aliceUsername)

	if err := boundary.Invite(ctx, strings.ToUpper(alice), strings.ToUpper(bob)); err != nil {
		t.Fatalf("invite with uppercase ids: %v", err)
	}
	if got := mustStatus(t, boundary, ctx, alice, strings.ToUpper(bob)); got != StateInviteSent {
		t.Fatalf("status = %v, want %v", got, StateInviteSent)
	}
	want := []string{
		fmt.Sprintf("status %s -> [%s]", alice, bob),
		fmt.Sprintf("add %s -> [%s]", alice, bob),
		fmt.Sprintf("status %s -> [%s]", alice, bob),
	}
	if strings.Join(graph.calls, "\n") != strings.Join(want, "\n") {
		t.Fatalf("graph calls = %q, want %q", graph.calls, want)
	}
}

func TestInviteRefusesATargetTheSubjectHasBlocked(t *testing.T) {
	graph := newFakeGraph()
	boundary := newBoundary(t, graph)
	ctx := session(alice, aliceUsername)
	if err := boundary.Block(ctx, alice, bob); err != nil {
		t.Fatalf("block: %v", err)
	}
	calls := len(graph.calls)

	err := boundary.Invite(ctx, alice, bob)
	if !errors.Is(err, ErrTargetBlocked) {
		t.Fatalf("invite of a blocked target: err = %v, want ErrTargetBlocked", err)
	}
	for _, call := range graph.calls[calls:] {
		if strings.HasPrefix(call, "add ") {
			t.Fatalf("invite reached the graph despite the block: %v", graph.calls)
		}
	}
	if got := mustStatus(t, boundary, ctx, alice, bob); got != StateBlocked {
		t.Fatalf("status after refused invite = %v, want %v", got, StateBlocked)
	}
}

func TestBlockRecordsTheBlockAndRemoveClearsIt(t *testing.T) {
	graph := newFakeGraph()
	boundary := newBoundary(t, graph)
	aliceCtx := session(alice, aliceUsername)
	bobCtx := session(bob, bobUsername)
	if err := boundary.Invite(bobCtx, bob, alice); err != nil {
		t.Fatalf("bob invites alice: %v", err)
	}

	if err := boundary.Block(aliceCtx, alice, bob); err != nil {
		t.Fatalf("alice blocks bob: %v", err)
	}
	if got := mustStatus(t, boundary, aliceCtx, alice, bob); got != StateBlocked {
		t.Fatalf("alice -> bob = %v, want %v", got, StateBlocked)
	}
	if got := mustStatus(t, boundary, bobCtx, bob, alice); got != StateNone {
		t.Fatalf("bob -> alice after being blocked = %v, want %v", got, StateNone)
	}
	if err := boundary.Invite(bobCtx, bob, alice); err != nil {
		t.Fatalf("bob re-invites alice: %v", err)
	}
	if got := mustStatus(t, boundary, aliceCtx, alice, bob); got != StateBlocked {
		t.Fatalf("a blocked player's invite changed alice's edge to %v", got)
	}

	if err := boundary.Remove(aliceCtx, alice, bob); err != nil {
		t.Fatalf("alice unblocks bob: %v", err)
	}
	if got := mustStatus(t, boundary, aliceCtx, alice, bob); got != StateNone {
		t.Fatalf("alice -> bob after unblock = %v, want %v", got, StateNone)
	}
}

func TestRemoveEndsAFriendshipOnBothSides(t *testing.T) {
	graph := newFakeGraph()
	boundary := newBoundary(t, graph)
	aliceCtx := session(alice, aliceUsername)
	bobCtx := session(bob, bobUsername)
	if err := boundary.Invite(aliceCtx, alice, bob); err != nil {
		t.Fatalf("alice invites bob: %v", err)
	}
	if err := boundary.Invite(bobCtx, bob, alice); err != nil {
		t.Fatalf("bob accepts: %v", err)
	}

	if err := boundary.Remove(aliceCtx, alice, bob); err != nil {
		t.Fatalf("alice removes bob: %v", err)
	}
	if got := mustStatus(t, boundary, aliceCtx, alice, bob); got != StateNone {
		t.Fatalf("alice -> bob after removal = %v, want %v", got, StateNone)
	}
	if got := mustStatus(t, boundary, bobCtx, bob, alice); got != StateNone {
		t.Fatalf("bob -> alice after removal = %v, want %v", got, StateNone)
	}
}

func TestListPagesThroughTheGraphWithABoundedLimit(t *testing.T) {
	graph := newFakeGraph()
	boundary := newBoundary(t, graph)
	ctx := session(alice, aliceUsername)
	for _, other := range []string{bob, carol, dave} {
		if err := boundary.Invite(ctx, alice, other); err != nil {
			t.Fatalf("invite %s: %v", other, err)
		}
	}
	if err := boundary.Block(ctx, alice, dave); err != nil {
		t.Fatalf("block dave: %v", err)
	}

	first, err := boundary.List(ctx, alice, 2, "")
	if err != nil {
		t.Fatalf("first page: %v", err)
	}
	wantFirst := []Friend{
		{SubjectID: bob, State: StateInviteSent},
		{SubjectID: carol, State: StateInviteSent},
	}
	if fmt.Sprint(first.Friends) != fmt.Sprint(wantFirst) || first.Cursor == "" {
		t.Fatalf("first page = %+v, want %+v with a cursor", first, wantFirst)
	}
	second, err := boundary.List(ctx, alice, 2, first.Cursor)
	if err != nil {
		t.Fatalf("second page: %v", err)
	}
	if graph.lastListCursor != first.Cursor {
		t.Fatalf("second page forwarded cursor %q, want %q", graph.lastListCursor, first.Cursor)
	}
	wantSecond := []Friend{{SubjectID: dave, State: StateBlocked}}
	if fmt.Sprint(second.Friends) != fmt.Sprint(wantSecond) || second.Cursor != "" {
		t.Fatalf("second page = %+v, want %+v with no cursor", second, wantSecond)
	}

	if _, err := boundary.List(ctx, alice, 0, ""); err != nil {
		t.Fatalf("default limit: %v", err)
	}
	if graph.lastListLimit != DefaultListLimit {
		t.Fatalf("limit 0 reached the graph as %d, want the default %d", graph.lastListLimit, DefaultListLimit)
	}
	if _, err := boundary.List(ctx, alice, MaxListLimit, ""); err != nil {
		t.Fatalf("maximum limit: %v", err)
	}

	calls := len(graph.calls)
	for _, limit := range []int{-1, MaxListLimit + 1} {
		if _, err := boundary.List(ctx, alice, limit, ""); !errors.Is(err, ErrInvalidLimit) {
			t.Errorf("limit %d: err = %v, want ErrInvalidLimit", limit, err)
		}
	}
	if len(graph.calls) != calls {
		t.Fatalf("an out-of-range limit reached the graph: %v", graph.calls[calls:])
	}
}

func TestStatusAndListRejectMalformedGraphOutput(t *testing.T) {
	ctx := session(alice, aliceUsername)
	malformed := map[string][]*api.Friend{
		"nil entry":      {nil},
		"nil user":       {{State: wrapperspb.Int32(0)}},
		"wrong subject":  {{User: &api.User{Id: carol}, State: wrapperspb.Int32(0)}},
		"missing state":  {{User: &api.User{Id: bob}}},
		"unknown state":  {{User: &api.User{Id: bob}, State: wrapperspb.Int32(7)}},
		"negative state": {{User: &api.User{Id: bob}, State: wrapperspb.Int32(-1)}},
		"two entries":    {{User: &api.User{Id: bob}, State: wrapperspb.Int32(0)}, {User: &api.User{Id: bob}, State: wrapperspb.Int32(0)}},
		"malformed id":   {{User: &api.User{Id: "bob"}, State: wrapperspb.Int32(0)}},
		"self as friend": {{User: &api.User{Id: alice}, State: wrapperspb.Int32(0)}},
		"system as friend": {
			{User: &api.User{Id: nakamastorage.SystemOwnerID}, State: wrapperspb.Int32(0)},
		},
	}
	for name, friends := range malformed {
		graph := newFakeGraph()
		graph.statusOverride = friends
		boundary := newBoundary(t, graph)
		if _, err := boundary.Status(ctx, alice, bob); !errors.Is(err, ErrGraph) {
			t.Errorf("status / %s: err = %v, want ErrGraph", name, err)
		}
	}
	// A wrong-subject or duplicate entry is fine in a LIST — those are other
	// friends — but the per-entry shape rules still hold.
	for name, friends := range malformed {
		if name == "wrong subject" || name == "two entries" {
			continue
		}
		graph := newFakeGraph()
		graph.listOverride = friends
		boundary := newBoundary(t, graph)
		if _, err := boundary.List(ctx, alice, 10, ""); !errors.Is(err, ErrGraph) {
			t.Errorf("list / %s: err = %v, want ErrGraph", name, err)
		}
	}
	// An upper-case id from the graph is still the same player.
	graph := newFakeGraph()
	graph.statusOverride = []*api.Friend{{User: &api.User{Id: strings.ToUpper(bob)}, State: wrapperspb.Int32(0)}}
	boundary := newBoundary(t, graph)
	if got := mustStatus(t, boundary, ctx, alice, bob); got != StateFriend {
		t.Fatalf("upper-case graph id read as %v, want %v", got, StateFriend)
	}
}

func TestGraphFailuresAreSanitizedAndCancellationIsPreserved(t *testing.T) {
	ctx := session(alice, aliceUsername)
	graph := newFakeGraph()
	graph.err = errors.New("pq: connection refused to nakama-postgres:5432")
	boundary := newBoundary(t, graph)
	results := map[string]error{}
	results["invite"] = boundary.Invite(ctx, alice, bob)
	results["remove"] = boundary.Remove(ctx, alice, bob)
	results["block"] = boundary.Block(ctx, alice, bob)
	_, results["status"] = boundary.Status(ctx, alice, bob)
	_, results["list"] = boundary.List(ctx, alice, 10, "")
	for operation, err := range results {
		if !errors.Is(err, ErrGraph) {
			t.Errorf("%s: err = %v, want ErrGraph", operation, err)
		}
		if err != nil && strings.Contains(err.Error(), "pq") {
			t.Errorf("%s: the store's own error text leaked: %v", operation, err)
		}
	}

	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	cancelledSession := sessionWith(cancelled, alice, aliceUsername)
	graph = newFakeGraph()
	graph.err = errors.New("pq: statement cancelled")
	boundary = newBoundary(t, graph)
	results = map[string]error{}
	results["invite"] = boundary.Invite(cancelledSession, alice, bob)
	results["remove"] = boundary.Remove(cancelledSession, alice, bob)
	results["block"] = boundary.Block(cancelledSession, alice, bob)
	_, results["status"] = boundary.Status(cancelledSession, alice, bob)
	_, results["list"] = boundary.List(cancelledSession, alice, 10, "")
	for operation, err := range results {
		if !errors.Is(err, context.Canceled) {
			t.Errorf("%s: err = %v, want the caller's own context.Canceled", operation, err)
		}
	}
}

func TestNewRequiresAGraph(t *testing.T) {
	if _, err := New(nil); err == nil {
		t.Fatal("New(nil) succeeded")
	}
}

func TestStateNamesAreAClosedStableVocabulary(t *testing.T) {
	want := map[State]string{
		StateNone:           "none",
		StateFriend:         "friend",
		StateInviteSent:     "invite_sent",
		StateInviteReceived: "invite_received",
		StateBlocked:        "blocked",
	}
	for state, name := range want {
		if state.String() != name {
			t.Errorf("%d.String() = %q, want %q", int(state), state.String(), name)
		}
	}
	if State(99).String() != "unknown" {
		t.Errorf("an out-of-range state must read as unknown, got %q", State(99).String())
	}
}
