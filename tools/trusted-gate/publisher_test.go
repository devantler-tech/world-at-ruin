package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const publisherTestAppID int64 = 900001

func publisherIdentity() Identity {
	return Identity{Kind: "pull_request", PRNumber: 7, RunID: 501, Head: strings.Repeat("1", 40), Base: strings.Repeat("2", 40), Candidate: strings.Repeat("3", 40), Ref: "refs/pull/7/merge"}
}

type publisherObservation struct {
	posts     int
	refreshes int
	readbacks int
	body      map[string]any
}

type publisherFaults struct {
	fresh         *Identity
	producerAppID int64
	createFailure bool
	readFailure   bool
	mutateCreate  func(map[string]any)
	mutateRead    func(map[string]any)
}

// publisherClient serves complete identity and check fixtures while recording writes and injected faults.
func publisherClient(t *testing.T, identity Identity, faults publisherFaults) (*Client, *publisherObservation) {
	t.Helper()
	seen := &publisherObservation{}
	fresh := identity
	if faults.fresh != nil {
		fresh = *faults.fresh
	}
	var created map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		var value any
		switch r.URL.Path {
		case "/repos/devantler-tech/world-at-ruin/actions/runs/501":
			seen.refreshes++
			value = map[string]any{"id": fresh.RunID, "status": "completed", "conclusion": "failure", "path": ".github/workflows/ci.yaml", "event": fresh.Kind,
				"head_sha": fresh.Head, "head_branch": "codex/fixture", "repository": map[string]any{"full_name": "devantler-tech/world-at-ruin"}, "head_repository": map[string]any{"full_name": "devantler-tech/world-at-ruin"}}
		case "/repos/devantler-tech/world-at-ruin/git/ref/heads/main":
			value = map[string]any{"ref": "refs/heads/main", "object": map[string]any{"type": "commit", "sha": fresh.Base}}
		case "/repos/devantler-tech/world-at-ruin/pulls":
			value = []any{map[string]any{"number": fresh.PRNumber, "state": "open", "base": map[string]any{"ref": "main", "sha": fresh.Base, "repo": map[string]any{"full_name": "devantler-tech/world-at-ruin"}},
				"head": map[string]any{"ref": "codex/fixture", "sha": fresh.Head, "repo": map[string]any{"full_name": "devantler-tech/world-at-ruin"}}, "merge_commit_sha": fresh.Candidate}}
		case "/repos/devantler-tech/world-at-ruin/git/commits/" + fresh.Candidate:
			value = map[string]any{"sha": fresh.Candidate, "parents": []any{map[string]any{"sha": fresh.Base}, map[string]any{"sha": fresh.Head}}}
		case "/repos/devantler-tech/world-at-ruin/check-runs":
			if r.Method != http.MethodPost {
				t.Errorf("check creation used %s", r.Method)
				w.WriteHeader(405)
				return
			}
			seen.posts++
			if seen.refreshes == 0 {
				t.Error("publisher wrote before refreshing the frozen identity")
			}
			if faults.createFailure {
				w.WriteHeader(503)
				return
			}
			if err := json.NewDecoder(r.Body).Decode(&seen.body); err != nil {
				t.Error(err)
				w.WriteHeader(400)
				return
			}
			producerID := publisherTestAppID
			if faults.producerAppID != 0 {
				producerID = faults.producerAppID
			}
			created = map[string]any{"id": 901, "name": seen.body["name"], "head_sha": seen.body["head_sha"], "status": seen.body["status"], "conclusion": seen.body["conclusion"], "app": map[string]any{"id": producerID}}
			if faults.mutateCreate != nil {
				faults.mutateCreate(created)
			}
			value = created
			w.WriteHeader(http.StatusCreated)
		case "/repos/devantler-tech/world-at-ruin/check-runs/901":
			seen.readbacks++
			if r.Method != http.MethodGet {
				t.Error("check readback was not read-only")
				w.WriteHeader(405)
				return
			}
			if faults.readFailure {
				w.WriteHeader(503)
				return
			}
			if faults.mutateRead != nil {
				faults.mutateRead(created)
			}
			value = created
		default:
			t.Errorf("unexpected publisher request %s %s", r.Method, r.URL.String())
			w.WriteHeader(404)
			return
		}
		_ = json.NewEncoder(w).Encode(value)
	}))
	t.Cleanup(server.Close)
	return &Client{BaseURL: server.URL, Token: "configured-app-test", HTTP: server.Client()}, seen
}

func TestPublisherRejectsMatchedActionsProducerBeforeAnyAPI(t *testing.T) {
	for _, verdict := range []string{"pending", "failure", "success"} {
		t.Run(verdict, func(t *testing.T) {
			client, seen := publisherClient(t, publisherIdentity(), publisherFaults{producerAppID: 15368})
			if err := client.Publish(context.Background(), publisherIdentity(), verdict, 15368); err == nil {
				t.Error("matched candidate-controlled Actions App was accepted as the independent publisher")
			}
			if seen.refreshes != 0 || seen.posts != 0 || seen.readbacks != 0 {
				t.Fatalf("known unsafe producer crossed the API boundary: reads=%d posts=%d readbacks=%d", seen.refreshes, seen.posts, seen.readbacks)
			}
		})
	}
}

func TestPublisherAttributesVerifiedVerdictToCandidateHead(t *testing.T) {
	for _, verdict := range []string{"pending", "failure", "success"} {
		t.Run(verdict, func(t *testing.T) {
			identity := publisherIdentity()
			client, seen := publisherClient(t, identity, publisherFaults{})
			if err := client.Publish(context.Background(), identity, verdict, publisherTestAppID); err != nil {
				t.Fatalf("verified %s publication failed: %v", verdict, err)
			}
			if seen.posts != 1 || seen.readbacks != 1 || seen.refreshes != 1 {
				t.Fatalf("missing refresh/create/readback: %+v", seen)
			}
			if seen.body["head_sha"] != identity.Head || seen.body["name"] != "World trusted regressions" {
				t.Fatalf("wrong candidate status attribution: %v", seen.body)
			}
			if verdict == "pending" {
				if seen.body["status"] != "in_progress" || seen.body["conclusion"] != nil {
					t.Fatalf("pending prematurely became terminal: %v", seen.body)
				}
			} else if seen.body["status"] != "completed" || seen.body["conclusion"] != verdict {
				t.Fatalf("wrong terminal verdict: %v", seen.body)
			}
		})
	}
}

func TestPublisherRefusesFrozenIdentityDriftBeforeWriting(t *testing.T) {
	for _, field := range []string{"head", "base", "candidate", "pull request"} {
		t.Run(field, func(t *testing.T) {
			identity := publisherIdentity()
			fresh := identity
			switch field {
			case "head":
				fresh.Head = strings.Repeat("4", 40)
			case "base":
				fresh.Base = strings.Repeat("4", 40)
			case "candidate":
				fresh.Candidate = strings.Repeat("4", 40)
			case "pull request":
				fresh.PRNumber = 8
				fresh.Ref = "refs/pull/8/merge"
			}
			client, seen := publisherClient(t, identity, publisherFaults{fresh: &fresh})
			if err := client.Publish(context.Background(), identity, "success", publisherTestAppID); err == nil {
				t.Fatal("stale identity was published green")
			}
			if seen.posts != 0 {
				t.Fatal("publisher mutated checks after identity changed")
			}
		})
	}
}

func TestPublisherDoesNotTrustWriteAcknowledgementWithoutReadback(t *testing.T) {
	cases := []struct {
		name  string
		fault publisherFaults
	}{
		{"failed create", publisherFaults{createFailure: true}},
		{"failed readback", publisherFaults{readFailure: true}},
		{"wrong returned id", publisherFaults{mutateCreate: func(check map[string]any) { check["id"] = 0 }}},
		{"wrong returned app", publisherFaults{mutateCreate: func(check map[string]any) { check["app"] = map[string]any{"id": 15368} }}},
		{"wrong readback id", publisherFaults{mutateRead: func(check map[string]any) { check["id"] = 902 }}},
		{"wrong readback head", publisherFaults{mutateRead: func(check map[string]any) { check["head_sha"] = strings.Repeat("5", 40) }}},
		{"wrong readback context", publisherFaults{mutateRead: func(check map[string]any) { check["name"] = "Candidate supplied context" }}},
		{"wrong readback app", publisherFaults{mutateRead: func(check map[string]any) { check["app"] = map[string]any{"id": 15368} }}},
		{"incomplete readback", publisherFaults{mutateRead: func(check map[string]any) { delete(check, "app") }}},
		{"pending readback", publisherFaults{mutateRead: func(check map[string]any) { check["status"] = "in_progress"; check["conclusion"] = nil }}},
		{"failed readback verdict", publisherFaults{mutateRead: func(check map[string]any) { check["conclusion"] = "failure" }}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			client, _ := publisherClient(t, publisherIdentity(), test.fault)
			if err := client.Publish(context.Background(), publisherIdentity(), "success", publisherTestAppID); err == nil {
				t.Fatal("unverified publication reported success")
			}
		})
	}
}

// TestPublisherRejectsInvalidInputsBeforeNetwork refuses malformed verdicts, App IDs and candidates before API use.
func TestPublisherRejectsInvalidInputsBeforeNetwork(t *testing.T) {
	for _, name := range []string{"empty outcome", "unknown outcome", "no configured app", "invalid candidate", "invalid head", "unknown identity kind", "missing run", "missing pull request", "wrong ref"} {
		t.Run(name, func(t *testing.T) {
			identity, verdict, appID := publisherIdentity(), "success", publisherTestAppID
			switch name {
			case "empty outcome":
				verdict = ""
			case "unknown outcome":
				verdict = "neutral"
			case "no configured app":
				appID = 0
			case "invalid candidate":
				identity.Candidate = "main"
			case "invalid head":
				identity.Head = "HEAD"
			case "unknown identity kind":
				identity.Kind = "workflow_dispatch"
			case "missing run":
				identity.RunID = 0
			case "missing pull request":
				identity.PRNumber = 0
			case "wrong ref":
				identity.Ref = "refs/heads/candidate"
			}
			client, seen := publisherClient(t, identity, publisherFaults{})
			if err := client.Publish(context.Background(), identity, verdict, appID); err == nil {
				t.Fatalf("invalid %s admitted", name)
			}
			if seen.posts != 0 || seen.refreshes != 0 {
				t.Fatal("invalid input crossed the API boundary")
			}
		})
	}
}

// TestPublisherQueueCheckAttachesQueueCandidate binds publication to the verified queue head.
func TestPublisherQueueCheckAttachesQueueCandidate(t *testing.T) {
	identity := publisherIdentity()
	identity.Kind = "merge_group"
	identity.Head = identity.Candidate
	identity.PRNumber = 0
	identity.Ref = "refs/heads/gh-readonly-queue/main/pr-7-fixture"
	var publishedHead string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var value any
		switch r.URL.Path {
		case "/repos/devantler-tech/world-at-ruin/actions/runs/501":
			value = map[string]any{"id": 501, "status": "completed", "path": ".github/workflows/ci.yaml", "event": "merge_group", "head_sha": identity.Candidate, "head_branch": strings.TrimPrefix(identity.Ref, "refs/heads/"), "repository": map[string]any{"full_name": "devantler-tech/world-at-ruin"}, "head_repository": map[string]any{"full_name": "devantler-tech/world-at-ruin"}}
		case "/repos/devantler-tech/world-at-ruin/git/ref/heads/main":
			value = map[string]any{"ref": "refs/heads/main", "object": map[string]any{"type": "commit", "sha": identity.Base}}
		case "/repos/devantler-tech/world-at-ruin/git/ref/heads/gh-readonly-queue/main/pr-7-fixture":
			value = map[string]any{"ref": identity.Ref, "object": map[string]any{"type": "commit", "sha": identity.Candidate}}
		case "/repos/devantler-tech/world-at-ruin/compare/" + identity.Base + "..." + identity.Candidate:
			value = map[string]any{"status": "ahead", "ahead_by": 1, "behind_by": 0, "merge_base_commit": map[string]any{"sha": identity.Base}}
		case "/repos/devantler-tech/world-at-ruin/check-runs":
			if r.Method != http.MethodPost {
				t.Error("expected check create")
				w.WriteHeader(405)
				return
			}
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
			}
			publishedHead, _ = body["head_sha"].(string)
			value = map[string]any{"id": 901, "name": "World trusted regressions", "head_sha": publishedHead, "status": "completed", "conclusion": "success", "app": map[string]any{"id": publisherTestAppID}}
			w.WriteHeader(201)
		case "/repos/devantler-tech/world-at-ruin/check-runs/901":
			value = map[string]any{"id": 901, "name": "World trusted regressions", "head_sha": publishedHead, "status": "completed", "conclusion": "success", "app": map[string]any{"id": publisherTestAppID}}
		default:
			t.Errorf("unexpected queue read %s", r.URL.Path)
			w.WriteHeader(404)
			return
		}
		_ = json.NewEncoder(w).Encode(value)
	}))
	defer server.Close()
	client := Client{BaseURL: server.URL, Token: "configured-app-test", HTTP: server.Client()}
	if err := client.Publish(context.Background(), identity, "success", publisherTestAppID); err != nil {
		t.Fatal(err)
	}
	if publishedHead != identity.Candidate {
		t.Fatalf("queue check attached to %s instead of %s", publishedHead, identity.Candidate)
	}
}

func TestPublisherRejectsCheckReadbackWithMissingConclusion(t *testing.T) {
	client, _ := publisherClient(t, publisherIdentity(), publisherFaults{mutateRead: func(check map[string]any) { delete(check, "conclusion") }})
	if err := client.Publish(context.Background(), publisherIdentity(), "success", publisherTestAppID); err == nil {
		t.Fatal("missing terminal conclusion accepted")
	}
}
