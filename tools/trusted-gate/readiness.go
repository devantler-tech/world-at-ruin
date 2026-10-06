package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

const retainedOrganizationGateID int64 = 21102220

type rulesetRecord struct {
	ID           int64                      `json:"id"`
	Name         string                     `json:"name"`
	Target       string                     `json:"target"`
	Source       string                     `json:"source"`
	SourceType   string                     `json:"source_type"`
	Enforcement  string                     `json:"enforcement"`
	BypassActors json.RawMessage            `json:"bypass_actors"`
	Conditions   map[string]json.RawMessage `json:"conditions"`
	Rules        []rulesetRule              `json:"rules"`
}

type rulesetRule struct {
	Type       string          `json:"type"`
	Parameters json.RawMessage `json:"parameters"`
}

type requiredStatusParameters struct {
	DoNotEnforceOnCreate *bool `json:"do_not_enforce_on_create"`
	Strict               *bool `json:"strict_required_status_checks_policy"`
	Checks               []struct {
		Context       string `json:"context"`
		IntegrationID *int64 `json:"integration_id"`
	} `json:"required_status_checks"`
}

// Inspect establishes the overlap needed before retiring the old organization
// gate. It never writes settings, and API summaries never stand in for full
// ruleset readback. The independent status producer must already be configured.
func (c *Client) Inspect(ctx context.Context, appID int64) error {
	if !independentAppID(appID) {
		return fmt.Errorf("readiness UNKNOWN: a dedicated status producer is required")
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	inventory, err := c.rulesetInventory(ctx)
	if err != nil {
		return err
	}
	var retained *rulesetRecord
	var replacements []rulesetRecord
	for _, summary := range inventory {
		if summary.ID != retainedOrganizationGateID && (summary.SourceType != "Repository" || summary.Source != "devantler-tech/world-at-ruin") {
			continue
		}
		var detail rulesetRecord
		path := fmt.Sprintf("/repos/devantler-tech/world-at-ruin/rulesets/%d?includes_parents=true", summary.ID)
		if err := c.DoJSON(ctx, http.MethodGet, path, nil, &detail); err != nil {
			return fmt.Errorf("readiness UNKNOWN: ruleset detail cannot be read: %w", err)
		}
		if !sameRulesetSummary(summary, detail) {
			return fmt.Errorf("readiness UNKNOWN: ruleset summary and detail disagree")
		}
		if detail.Rules == nil {
			return fmt.Errorf("readiness UNKNOWN: ruleset detail omits its explicit rules array")
		}
		if summary.ID == retainedOrganizationGateID {
			retained = &detail
			continue
		}
		for _, rule := range detail.Rules {
			if rule.Type == "" {
				return fmt.Errorf("readiness UNKNOWN: ruleset detail contains an incomplete rule")
			}
			if rule.Type != "required_status_checks" {
				continue
			}
			var params requiredStatusParameters
			if err := json.Unmarshal(rule.Parameters, &params); err != nil || params.DoNotEnforceOnCreate == nil || params.Strict == nil || params.Checks == nil || len(params.Checks) == 0 {
				return fmt.Errorf("readiness UNKNOWN: status-rule parameters cannot be read")
			}
			for _, check := range params.Checks {
				if check.Context == "" {
					return fmt.Errorf("readiness UNKNOWN: required-status check context is incomplete")
				}
				if check.Context == TrustedContext {
					replacements = append(replacements, detail)
				}
			}
		}
	}
	if retained == nil || len(replacements) == 0 {
		return fmt.Errorf("readiness NOT_READY: both the retained organization gate and repository replacement must exist")
	}
	if len(replacements) != 1 {
		return fmt.Errorf("readiness UNKNOWN: more than one repository rule requires the trusted context")
	}
	if err := verifyRetainedOrganizationGate(*retained); err != nil {
		return fmt.Errorf("readiness NOT_READY: retained organization gate: %w", err)
	}
	if err := verifyRepositoryGate(replacements[0], appID); err != nil {
		return fmt.Errorf("readiness NOT_READY: repository replacement: %w", err)
	}
	return nil
}

func (c *Client) rulesetInventory(ctx context.Context) ([]rulesetRecord, error) {
	var inventory []rulesetRecord
	seen := map[int64]bool{}
	for page := 1; page <= 10; page++ {
		var batch []rulesetRecord
		path := fmt.Sprintf("/repos/devantler-tech/world-at-ruin/rulesets?includes_parents=true&per_page=100&page=%d", page)
		if err := c.DoJSON(ctx, http.MethodGet, path, nil, &batch); err != nil {
			return nil, fmt.Errorf("readiness UNKNOWN: ruleset inventory cannot be read: %w", err)
		}
		if batch == nil || len(batch) > 100 {
			return nil, fmt.Errorf("readiness UNKNOWN: malformed ruleset inventory page")
		}
		for _, rule := range batch {
			if rule.ID <= 0 || rule.Name == "" || rule.Target == "" || rule.Source == "" || rule.SourceType == "" || rule.Enforcement == "" || seen[rule.ID] {
				return nil, fmt.Errorf("readiness UNKNOWN: incomplete or duplicate ruleset inventory")
			}
			seen[rule.ID] = true
			inventory = append(inventory, rule)
		}
		if len(batch) < 100 {
			return inventory, nil
		}
	}
	return nil, fmt.Errorf("readiness UNKNOWN: ruleset inventory exceeds its bounded pagination budget")
}

func sameRulesetSummary(summary, detail rulesetRecord) bool {
	return summary.ID == detail.ID && summary.Name == detail.Name && summary.Target == detail.Target && summary.Source == detail.Source && summary.SourceType == detail.SourceType && summary.Enforcement == detail.Enforcement
}

func verifyBranchGate(rule rulesetRecord) error {
	if rule.Target != "branch" || rule.Enforcement != "active" {
		return fmt.Errorf("must be an active branch gate")
	}
	var bypass []json.RawMessage
	if err := json.Unmarshal(rule.BypassActors, &bypass); err != nil || bypass == nil || len(bypass) != 0 {
		return fmt.Errorf("complete empty bypass inventory is required")
	}
	if len(rule.Conditions) != 1 {
		return fmt.Errorf("only the default-branch selector may be declared")
	}
	var refs struct {
		Include []string `json:"include"`
		Exclude []string `json:"exclude"`
	}
	if err := json.Unmarshal(rule.Conditions["ref_name"], &refs); err != nil || len(refs.Include) != 1 || refs.Include[0] != "~DEFAULT_BRANCH" || refs.Exclude == nil || len(refs.Exclude) != 0 {
		return fmt.Errorf("must target only the default branch without exclusions")
	}
	return nil
}

func verifyRepositoryGate(rule rulesetRecord, appID int64) error {
	if rule.SourceType != "Repository" || rule.Source != "devantler-tech/world-at-ruin" {
		return fmt.Errorf("must be owned by the World at Ruin repository")
	}
	if err := verifyBranchGate(rule); err != nil {
		return err
	}
	if len(rule.Rules) != 1 || rule.Rules[0].Type != "required_status_checks" {
		return fmt.Errorf("must contain exactly the trusted required-status rule")
	}
	var params requiredStatusParameters
	if err := json.Unmarshal(rule.Rules[0].Parameters, &params); err != nil || params.DoNotEnforceOnCreate == nil || *params.DoNotEnforceOnCreate || params.Strict == nil || *params.Strict || len(params.Checks) != 1 {
		return fmt.Errorf("status requirements must preserve strictness and prohibit creation exemptions")
	}
	check := params.Checks[0]
	if check.Context != TrustedContext || check.IntegrationID == nil || *check.IntegrationID != appID {
		return fmt.Errorf("trusted context must require the configured independent producer")
	}
	return nil
}

func verifyRetainedOrganizationGate(rule rulesetRecord) error {
	if rule.ID != retainedOrganizationGateID || rule.SourceType != "Organization" || rule.Source != "devantler-tech" {
		return fmt.Errorf("existing organization identity must be retained")
	}
	if err := verifyBranchGate(rule); err != nil {
		return err
	}
	if len(rule.Rules) != 1 || rule.Rules[0].Type != "workflows" {
		return fmt.Errorf("existing required-workflow rule must be retained")
	}
	var params struct {
		DoNotEnforceOnCreate *bool `json:"do_not_enforce_on_create"`
		Workflows            []struct {
			RepositoryID int64  `json:"repository_id"`
			Path         string `json:"path"`
			Ref          string `json:"ref"`
			SHA          string `json:"sha"`
		} `json:"workflows"`
	}
	if err := json.Unmarshal(rule.Rules[0].Parameters, &params); err != nil || params.DoNotEnforceOnCreate == nil || *params.DoNotEnforceOnCreate || len(params.Workflows) != 1 {
		return fmt.Errorf("existing required-workflow parameters must be complete")
	}
	workflow := params.Workflows[0]
	if workflow.RepositoryID != 933213756 || workflow.Path != ".github/workflows/world-at-ruin-required-regressions.yaml" || workflow.Ref != "refs/heads/main" || workflow.SHA != "" {
		return fmt.Errorf("existing reviewed catalogue workflow source must remain active")
	}
	return nil
}
