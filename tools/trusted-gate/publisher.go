package main

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"
)

const TrustedContext = "World trusted regressions"

// GitHub's public github-actions App is 15368. Candidate-owned workflows share
// that identity, so matching it cannot authenticate an independent verdict.
const knownActionsAppID int64 = 15368

// publisherAppID accepts configured App identities and excludes the shared Actions identity.
func publisherAppID(id int64) bool {
	return id > 0 && id != knownActionsAppID
}

type publishedCheck struct {
	ID         int64   `json:"id"`
	Name       string  `json:"name"`
	HeadSHA    string  `json:"head_sha"`
	Status     string  `json:"status"`
	Conclusion *string `json:"conclusion"`
	App        *struct {
		ID int64 `json:"id"`
	} `json:"app"`
}

// Publish is called only by the credential-isolated reporter after the trusted
// evaluator supplies its verdict. Notification CI conclusions are not verdicts.
// Every write rebinds the evaluated identity to current GitHub state; readback
// must prove the check belongs to the configured producer and exact candidate.
func (c *Client) Publish(ctx context.Context, identity Identity, verdict string, appID int64) error {
	if !publisherAppID(appID) || (verdict != "pending" && verdict != "failure" && verdict != "success") {
		return fmt.Errorf("trusted publication needs a configured producer and an explicit verdict")
	}
	if err := validatePublishIdentity(identity); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	current, err := c.Resolve(ctx, Notification{RunID: identity.RunID})
	if err != nil {
		return fmt.Errorf("trusted publication cannot refresh the evaluated identity: %w", err)
	}
	if current != identity {
		return fmt.Errorf("trusted publication refused a changed evaluated identity")
	}
	head := identity.Head
	if identity.Kind == "merge_group" {
		head = identity.Candidate
	}
	status := "completed"
	payload := map[string]any{
		"name":        TrustedContext,
		"head_sha":    head,
		"status":      status,
		"external_id": fmt.Sprintf("war:%d:%s:%s:%s", identity.RunID, identity.Head, identity.Base, identity.Candidate),
	}
	if verdict == "pending" {
		status = "in_progress"
		payload["status"] = status
	} else {
		payload["conclusion"] = verdict
	}
	var created publishedCheck
	if err := c.DoJSON(ctx, http.MethodPost, gateAPIPath+"/check-runs", payload, &created); err != nil {
		return fmt.Errorf("trusted check was not acknowledged: %w", err)
	}
	if err := verifyPublishedCheck(created, created.ID, head, status, verdict, appID); err != nil {
		return fmt.Errorf("trusted check acknowledgement could not be verified: %w", err)
	}
	var observed publishedCheck
	if err := c.DoJSON(ctx, http.MethodGet, fmt.Sprintf("%s/check-runs/%d", gateAPIPath, created.ID), nil, &observed); err != nil {
		return fmt.Errorf("trusted check readback failed: %w", err)
	}
	if err := verifyPublishedCheck(observed, created.ID, head, status, verdict, appID); err != nil {
		return fmt.Errorf("trusted check readback could not be verified: %w", err)
	}
	return nil
}

func validatePublishIdentity(identity Identity) error {
	if identity.RunID <= 0 || !gateSHA.MatchString(identity.Head) || !gateSHA.MatchString(identity.Base) || !gateSHA.MatchString(identity.Candidate) {
		return fmt.Errorf("trusted publication needs complete immutable commit and run identities")
	}
	switch identity.Kind {
	case "pull_request":
		if identity.PRNumber <= 0 || identity.Ref != fmt.Sprintf("refs/pull/%d/merge", identity.PRNumber) || identity.Candidate == identity.Base || identity.Candidate == identity.Head {
			return fmt.Errorf("trusted publication needs the exact pull-request integration identity")
		}
	case "merge_group":
		if identity.PRNumber != 0 || identity.Head != identity.Candidate || identity.Candidate == identity.Base || !strings.HasPrefix(identity.Ref, "refs/heads/") || !gateQueueBranch.MatchString(strings.TrimPrefix(identity.Ref, "refs/heads/")) {
			return fmt.Errorf("trusted publication needs the exact canonical queue identity")
		}
	default:
		return fmt.Errorf("trusted publication rejects an unsupported identity kind")
	}
	return nil
}

func verifyPublishedCheck(check publishedCheck, id int64, head, status, verdict string, appID int64) error {
	if id <= 0 || check.ID != id || check.Name != TrustedContext || check.HeadSHA != head || check.App == nil || check.App.ID != appID || check.Status != status {
		return fmt.Errorf("check identity, producer or state disagrees with publication")
	}
	if verdict == "pending" {
		if check.Conclusion != nil {
			return fmt.Errorf("pending publication must not report a terminal conclusion")
		}
	} else if check.Conclusion == nil || *check.Conclusion != verdict {
		return fmt.Errorf("terminal check conclusion disagrees with publication")
	}
	return nil
}
