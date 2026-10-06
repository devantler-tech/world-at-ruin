package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"time"
)

// Notification carries only GitHub's run identity, never candidate-authored data.
type Notification struct {
	RunID int64 `json:"run_id"`
}

// Identity binds the notification to a currently proposed integration commit.
type Identity struct {
	Kind      string `json:"kind"`
	PRNumber  int    `json:"pr_number"`
	RunID     int64  `json:"run_id"`
	Head      string `json:"head"`
	Base      string `json:"base"`
	Candidate string `json:"candidate"`
	Ref       string `json:"ref"`
}

var gateSHA = regexp.MustCompile(`^[0-9a-f]{40}$`)
var gateRepository = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
var gateQueueBranch = regexp.MustCompile(`^gh-readonly-queue/main/pr-[1-9][0-9]*-[A-Za-z0-9]+$`)

type gateRepoIdentity struct {
	FullName string `json:"full_name"`
}

type gateRunIdentity struct {
	ID             int64            `json:"id"`
	Status         string           `json:"status"`
	Event          string           `json:"event"`
	Path           string           `json:"path"`
	HeadSHA        string           `json:"head_sha"`
	HeadBranch     string           `json:"head_branch"`
	Repository     gateRepoIdentity `json:"repository"`
	HeadRepository gateRepoIdentity `json:"head_repository"`
}

type gateRefIdentity struct {
	Ref    string `json:"ref"`
	Object struct {
		Type string `json:"type"`
		SHA  string `json:"sha"`
	} `json:"object"`
}

type gatePRBranch struct {
	Ref  string           `json:"ref"`
	SHA  string           `json:"sha"`
	Repo gateRepoIdentity `json:"repo"`
}

type gatePRIdentity struct {
	Number         int          `json:"number"`
	State          string       `json:"state"`
	Base           gatePRBranch `json:"base"`
	Head           gatePRBranch `json:"head"`
	MergeCommitSHA string       `json:"merge_commit_sha"`
}

// Resolve treats a candidate CI run only as a notification. Its conclusion and
// artifacts cannot select the harness, candidate bytes or published verdict.
func (c Client) Resolve(ctx context.Context, notification Notification) (Identity, error) {
	if notification.RunID <= 0 {
		return Identity{}, errors.New("notification needs a positive run identity")
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	var run gateRunIdentity
	if err := c.DoJSON(ctx, http.MethodGet, gateAPIPath+"/actions/runs/"+strconv.FormatInt(notification.RunID, 10), nil, &run); err != nil {
		return Identity{}, err
	}
	if run.ID != notification.RunID || run.Status != "completed" || run.Path != ".github/workflows/ci.yaml" ||
		run.Repository.FullName != "devantler-tech/world-at-ruin" || !gateSHA.MatchString(run.HeadSHA) ||
		run.HeadBranch == "" || !gateRepository.MatchString(run.HeadRepository.FullName) {
		return Identity{}, errors.New("notification is not a completed canonical World CI run")
	}
	if run.Event != "pull_request" && run.Event != "merge_group" {
		return Identity{}, errors.New("notification is not a pull-request or merge-group run")
	}
	var main gateRefIdentity
	if err := c.DoJSON(ctx, http.MethodGet, gateAPIPath+"/git/ref/heads/main", nil, &main); err != nil {
		return Identity{}, err
	}
	if main.Ref != "refs/heads/main" || main.Object.Type != "commit" || !gateSHA.MatchString(main.Object.SHA) {
		return Identity{}, errors.New("current World main identity is incomplete")
	}
	if run.Event == "pull_request" {
		return c.resolvePR(ctx, run, main.Object.SHA)
	}
	return c.resolveQueue(ctx, run, main.Object.SHA)
}

func (c Client) resolvePR(ctx context.Context, run gateRunIdentity, base string) (Identity, error) {
	var matching []gatePRIdentity
	seen := make(map[int]bool)
	complete := false
	// Finish the entire census even when an early page contains a match. A later
	// PR with the same head makes attribution ambiguous, not permission to guess.
	for page := 1; page <= 32; page++ {
		query := url.Values{"state": {"open"}, "base": {"main"}, "per_page": {"100"}, "page": {strconv.Itoa(page)}}
		var rows []gatePRIdentity
		if err := c.DoJSON(ctx, http.MethodGet, gateAPIPath+"/pulls?"+query.Encode(), nil, &rows); err != nil {
			return Identity{}, err
		}
		if len(rows) > 100 {
			return Identity{}, errors.New("open pull-request census exceeded its page bound")
		}
		for _, row := range rows {
			if row.Number <= 0 || seen[row.Number] || row.State != "open" || row.Base.Ref != "main" ||
				row.Base.Repo.FullName != "devantler-tech/world-at-ruin" || !gateSHA.MatchString(row.Base.SHA) ||
				!gateSHA.MatchString(row.Head.SHA) || row.Head.Ref == "" || !gateRepository.MatchString(row.Head.Repo.FullName) {
				return Identity{}, errors.New("open pull-request census is incomplete or inconsistent")
			}
			seen[row.Number] = true
			if row.Head.SHA == run.HeadSHA {
				matching = append(matching, row)
			}
		}
		if len(rows) < 100 {
			complete = true
			break
		}
	}
	if !complete || len(matching) != 1 {
		return Identity{}, errors.New("completed census does not identify exactly one current pull request")
	}
	pr := matching[0]
	if pr.Base.SHA != base || pr.Head.Ref != run.HeadBranch || pr.Head.Repo.FullName != run.HeadRepository.FullName ||
		!gateSHA.MatchString(pr.MergeCommitSHA) || pr.MergeCommitSHA == base || pr.MergeCommitSHA == pr.Head.SHA {
		return Identity{}, errors.New("pull-request identity is stale or lacks an exact integration commit")
	}
	var integration struct {
		SHA     string `json:"sha"`
		Parents []struct {
			SHA string `json:"sha"`
		} `json:"parents"`
	}
	if err := c.DoJSON(ctx, http.MethodGet, gateAPIPath+"/git/commits/"+pr.MergeCommitSHA, nil, &integration); err != nil {
		return Identity{}, err
	}
	if integration.SHA != pr.MergeCommitSHA || len(integration.Parents) != 2 ||
		integration.Parents[0].SHA != base || integration.Parents[1].SHA != pr.Head.SHA {
		return Identity{}, errors.New("integration commit does not bind the exact current base and head")
	}
	return Identity{Kind: "pull_request", PRNumber: pr.Number, RunID: run.ID, Head: pr.Head.SHA, Base: base,
		Candidate: integration.SHA, Ref: fmt.Sprintf("refs/pull/%d/merge", pr.Number)}, nil
}

func (c Client) resolveQueue(ctx context.Context, run gateRunIdentity, base string) (Identity, error) {
	if run.HeadRepository.FullName != "devantler-tech/world-at-ruin" || !gateQueueBranch.MatchString(run.HeadBranch) || run.HeadSHA == base {
		return Identity{}, errors.New("merge-group notification is not a canonical World main queue")
	}
	var queue gateRefIdentity
	if err := c.DoJSON(ctx, http.MethodGet, gateAPIPath+"/git/ref/heads/"+run.HeadBranch, nil, &queue); err != nil {
		return Identity{}, err
	}
	ref := "refs/heads/" + run.HeadBranch
	if queue.Ref != ref || queue.Object.Type != "commit" || queue.Object.SHA != run.HeadSHA {
		return Identity{}, errors.New("merge-group ref is stale or does not match its notification")
	}
	var comparison struct {
		Status          string `json:"status"`
		AheadBy         int    `json:"ahead_by"`
		BehindBy        *int   `json:"behind_by"`
		MergeBaseCommit struct {
			SHA string `json:"sha"`
		} `json:"merge_base_commit"`
	}
	if err := c.DoJSON(ctx, http.MethodGet, gateAPIPath+"/compare/"+base+"..."+run.HeadSHA, nil, &comparison); err != nil {
		return Identity{}, err
	}
	if comparison.Status != "ahead" || comparison.AheadBy <= 0 || comparison.BehindBy == nil || *comparison.BehindBy != 0 || comparison.MergeBaseCommit.SHA != base {
		return Identity{}, errors.New("merge group does not include the exact current main ancestor")
	}
	return Identity{Kind: "merge_group", RunID: run.ID, Head: run.HeadSHA, Base: base,
		Candidate: run.HeadSHA, Ref: ref}, nil
}
