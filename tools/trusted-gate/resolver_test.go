package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const (
	resolverRepo  = "devantler-tech/world-at-ruin"
	resolverBase  = "1111111111111111111111111111111111111111"
	resolverHead  = "2222222222222222222222222222222222222222"
	resolverMerge = "3333333333333333333333333333333333333333"
)

type resolverFixture struct {
	run, main, commit, queue, compare map[string]any
	pages                             map[string][]map[string]any
	seen                              []string
}

func newResolverFixture() *resolverFixture {
	return &resolverFixture{
		run:    map[string]any{"id": int64(73), "status": "completed", "conclusion": "failure", "event": "pull_request", "path": ".github/workflows/ci.yaml", "head_sha": resolverHead, "head_branch": "codex/feature", "repository": map[string]any{"full_name": resolverRepo}, "head_repository": map[string]any{"full_name": resolverRepo}},
		main:   map[string]any{"ref": "refs/heads/main", "object": map[string]any{"type": "commit", "sha": resolverBase}},
		commit: map[string]any{"sha": resolverMerge, "parents": []map[string]any{{"sha": resolverBase}, {"sha": resolverHead}}},
		pages:  map[string][]map[string]any{"1": {resolverPR(1256, resolverHead)}},
	}
}

func resolverPR(number int, head string) map[string]any {
	return map[string]any{"number": number, "state": "open", "base": map[string]any{"ref": "main", "sha": resolverBase, "repo": map[string]any{"full_name": resolverRepo}}, "head": map[string]any{"ref": "codex/feature", "sha": head, "repo": map[string]any{"full_name": resolverRepo}}, "merge_commit_sha": resolverMerge}
}

func (f *resolverFixture) client(t *testing.T) Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("identity resolution wrote API state: %s", r.Method)
		}
		f.seen = append(f.seen, r.URL.RequestURI())
		var body any
		switch r.URL.Path {
		case "/repos/" + resolverRepo + "/actions/runs/73":
			body = f.run
		case "/repos/" + resolverRepo + "/git/ref/heads/main":
			body = f.main
		case "/repos/" + resolverRepo + "/pulls":
			if r.URL.Query().Get("state") != "open" || r.URL.Query().Get("base") != "main" || r.URL.Query().Get("per_page") != "100" {
				t.Errorf("census not restricted to complete open main pages: %s", r.URL.RawQuery)
			}
			page := r.URL.Query().Get("page")
			if rows, ok := f.pages[page]; ok {
				body = rows
			} else {
				body = []map[string]any{}
			}
		case "/repos/" + resolverRepo + "/git/commits/" + resolverMerge:
			body = f.commit
		case "/repos/" + resolverRepo + "/git/ref/heads/gh-readonly-queue/main/pr-1256-a1b2":
			body = f.queue
		case "/repos/" + resolverRepo + "/compare/" + resolverBase + "..." + resolverMerge:
			body = f.compare
		default:
			http.Error(w, "unexpected endpoint", http.StatusNotFound)
			return
		}
		if err := json.NewEncoder(w).Encode(body); err != nil {
			t.Error(err)
		}
	}))
	t.Cleanup(srv.Close)
	return Client{BaseURL: srv.URL, HTTP: srv.Client()}
}

func TestResolvePRIndependentOfCandidateConclusion(t *testing.T) {
	f := newResolverFixture()
	got, err := f.client(t).Resolve(context.Background(), Notification{RunID: 73})
	if err != nil {
		t.Fatal(err)
	}
	want := Identity{Kind: "pull_request", PRNumber: 1256, RunID: 73, Head: resolverHead, Base: resolverBase, Candidate: resolverMerge, Ref: "refs/pull/1256/merge"}
	if got != want {
		t.Fatalf("identity=%+v want=%+v", got, want)
	}
}

func TestResolvePRCensusIncludesLaterPagesAndForkHeads(t *testing.T) {
	f := newResolverFixture()
	f.pages["1"] = make([]map[string]any, 100)
	for n := range f.pages["1"] {
		f.pages["1"][n] = resolverPR(n+1, fmt.Sprintf("%040x", n+1024))
	}
	f.pages["2"] = []map[string]any{resolverPR(1256, resolverHead)}
	f.run["head_repository"] = map[string]any{"full_name": "contributor/world-at-ruin"}
	f.pages["2"][0]["head"].(map[string]any)["repo"] = map[string]any{"full_name": "contributor/world-at-ruin"}
	got, err := f.client(t).Resolve(context.Background(), Notification{RunID: 73})
	if err != nil || got.PRNumber != 1256 {
		t.Fatalf("later-page canonical integration for fork head rejected: %+v %v", got, err)
	}
	if !strings.Contains(strings.Join(f.seen, "\n"), "page=2") {
		t.Fatal("open-PR census silently truncated to first page")
	}
}

func TestResolvePRRefusesUntrustedOrAmbiguousIdentity(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*resolverFixture)
	}{
		{"wrong_run", func(f *resolverFixture) { f.run["id"] = 74 }},
		{"running", func(f *resolverFixture) { f.run["status"] = "in_progress" }},
		{"other_workflow", func(f *resolverFixture) { f.run["path"] = ".github/workflows/candidate.yaml" }},
		{"wrong_event", func(f *resolverFixture) { f.run["event"] = "workflow_dispatch" }},
		{"fork_target", func(f *resolverFixture) {
			f.run["repository"] = map[string]any{"full_name": "contributor/world-at-ruin"}
		}},
		{"malformed_head", func(f *resolverFixture) { f.run["head_sha"] = "main" }},
		{"missing_head_repo", func(f *resolverFixture) { delete(f.run, "head_repository") }},
		{"missing_pr", func(f *resolverFixture) { f.pages["1"] = nil }},
		{"closed_pr", func(f *resolverFixture) { f.pages["1"][0]["state"] = "closed" }},
		{"ambiguous_pr", func(f *resolverFixture) { f.pages["1"] = append(f.pages["1"], resolverPR(1257, resolverHead)) }},
		{"changed_base", func(f *resolverFixture) { f.pages["1"][0]["base"].(map[string]any)["sha"] = resolverMerge }},
		{"foreign_base", func(f *resolverFixture) {
			f.pages["1"][0]["base"].(map[string]any)["repo"] = map[string]any{"full_name": "contributor/world-at-ruin"}
		}},
		{"wrong_branch", func(f *resolverFixture) { f.pages["1"][0]["head"].(map[string]any)["ref"] = "other" }},
		{"wrong_head_repo", func(f *resolverFixture) {
			f.pages["1"][0]["head"].(map[string]any)["repo"] = map[string]any{"full_name": "other/world-at-ruin"}
		}},
		{"missing_merge", func(f *resolverFixture) { f.pages["1"][0]["merge_commit_sha"] = nil }},
		{"wrong_commit", func(f *resolverFixture) { f.commit["sha"] = resolverHead }},
		{"wrong_parents", func(f *resolverFixture) {
			f.commit["parents"] = []map[string]any{{"sha": resolverBase}, {"sha": resolverMerge}}
		}},
		{"octopus_parents", func(f *resolverFixture) {
			f.commit["parents"] = []map[string]any{{"sha": resolverBase}, {"sha": resolverHead}, {"sha": resolverMerge}}
		}},
		{"repeated_page_number", func(f *resolverFixture) { f.pages["1"] = append(f.pages["1"], resolverPR(1256, resolverBase)) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newResolverFixture()
			tc.mutate(f)
			if got, err := f.client(t).Resolve(context.Background(), Notification{RunID: 73}); err == nil || got != (Identity{}) {
				t.Fatalf("inadmissible identity accepted: %+v %v", got, err)
			}
		})
	}
}

func TestResolvePRRefusesLaterPageAmbiguity(t *testing.T) {
	f := newResolverFixture()
	for n := 0; n < 99; n++ {
		f.pages["1"] = append(f.pages["1"], resolverPR(n+1, fmt.Sprintf("%040x", n+1024)))
	}
	f.pages["2"] = []map[string]any{resolverPR(1257, resolverHead)}
	if got, err := f.client(t).Resolve(context.Background(), Notification{RunID: 73}); err == nil || got != (Identity{}) {
		t.Fatalf("later census page ambiguity accepted: %+v %v", got, err)
	}
}

func newQueueFixture() *resolverFixture {
	f := newResolverFixture()
	f.run["event"] = "merge_group"
	f.run["head_sha"] = resolverMerge
	f.run["head_branch"] = "gh-readonly-queue/main/pr-1256-a1b2"
	f.queue = map[string]any{"ref": "refs/heads/gh-readonly-queue/main/pr-1256-a1b2", "object": map[string]any{"type": "commit", "sha": resolverMerge}}
	f.compare = map[string]any{"status": "ahead", "ahead_by": 1, "behind_by": 0, "merge_base_commit": map[string]any{"sha": resolverBase}}
	return f
}

func TestResolveQueueRequiresCurrentRefAndMainAncestry(t *testing.T) {
	f := newQueueFixture()
	got, err := f.client(t).Resolve(context.Background(), Notification{RunID: 73})
	if err != nil {
		t.Fatal(err)
	}
	want := Identity{Kind: "merge_group", RunID: 73, Head: resolverMerge, Base: resolverBase, Candidate: resolverMerge, Ref: "refs/heads/gh-readonly-queue/main/pr-1256-a1b2"}
	if got != want {
		t.Fatalf("queue identity=%+v want=%+v", got, want)
	}
}

func TestResolveQueueRefusesForeignOrStaleQueue(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*resolverFixture)
	}{
		{"foreign_branch", func(f *resolverFixture) { f.run["head_branch"] = "gh-readonly-queue/develop/pr-1256-a1b2" }},
		{"branch_traversal", func(f *resolverFixture) { f.run["head_branch"] = "gh-readonly-queue/main/../main" }},
		{"foreign_repository", func(f *resolverFixture) {
			f.run["head_repository"] = map[string]any{"full_name": "other/world-at-ruin"}
		}},
		{"stale_ref", func(f *resolverFixture) { f.queue["object"].(map[string]any)["sha"] = resolverHead }},
		{"wrong_ref", func(f *resolverFixture) { f.queue["ref"] = "refs/heads/main" }},
		{"noncommit_ref", func(f *resolverFixture) { f.queue["object"].(map[string]any)["type"] = "tag" }},
		{"diverged", func(f *resolverFixture) { f.compare["status"] = "diverged" }},
		{"behind", func(f *resolverFixture) { f.compare["behind_by"] = 1 }},
		{"unknown_behind", func(f *resolverFixture) { delete(f.compare, "behind_by") }},
		{"no_proposed_change", func(f *resolverFixture) { f.compare["ahead_by"] = 0 }},
		{"wrong_merge_base", func(f *resolverFixture) { f.compare["merge_base_commit"] = map[string]any{"sha": resolverHead} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newQueueFixture()
			tc.mutate(f)
			if got, err := f.client(t).Resolve(context.Background(), Notification{RunID: 73}); err == nil || got != (Identity{}) {
				t.Fatalf("inadmissible queue accepted: %+v %v", got, err)
			}
		})
	}
}
