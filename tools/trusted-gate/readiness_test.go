package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const readinessTestAppID int64 = 900001

func readinessDefaultConditions() map[string]any {
	return map[string]any{"ref_name": map[string]any{"include": []string{"~DEFAULT_BRANCH"}, "exclude": []string{}}}
}

func readinessRulesetFixtures() (map[string]any, map[string]any) {
	replacement := map[string]any{
		"id": 77, "name": "Product protection", "target": "branch", "source": "devantler-tech/world-at-ruin", "source_type": "Repository", "enforcement": "active",
		"bypass_actors": []any{}, "conditions": readinessDefaultConditions(),
		"rules": []any{map[string]any{"type": "required_status_checks", "parameters": map[string]any{
			"do_not_enforce_on_create": false, "strict_required_status_checks_policy": false,
			"required_status_checks": []any{map[string]any{"context": "World trusted regressions", "integration_id": readinessTestAppID}},
		}}},
	}
	retained := map[string]any{
		"id": 21102220, "name": "Require workflow - World at Ruin trusted regressions", "target": "branch", "source": "devantler-tech", "source_type": "Organization", "enforcement": "active",
		"bypass_actors": []any{}, "conditions": readinessDefaultConditions(),
		"rules": []any{map[string]any{"type": "workflows", "parameters": map[string]any{
			"do_not_enforce_on_create": false,
			"workflows":                []any{map[string]any{"repository_id": 933213756, "path": ".github/workflows/world-at-ruin-required-regressions.yaml", "ref": "refs/heads/main"}},
		}}},
	}
	return replacement, retained
}

func readinessSummary(detail map[string]any) map[string]any {
	result := map[string]any{}
	for _, key := range []string{"id", "name", "target", "source", "source_type", "enforcement"} {
		result[key] = detail[key]
	}
	return result
}

func readinessClient(t *testing.T, replacement, retained map[string]any, inventory []map[string]any, extra ...map[string]any) *Client {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("readiness performed a mutation: %s", r.Method)
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Query().Get("includes_parents") != "true" {
			t.Error("readiness omitted inherited rules")
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/repos/devantler-tech/world-at-ruin/rulesets":
			if r.URL.Query().Get("page") != "1" || r.URL.Query().Get("per_page") != "100" {
				t.Errorf("unbounded or unexpected inventory query: %s", r.URL.RawQuery)
			}
			_ = json.NewEncoder(w).Encode(inventory)
		case "/repos/devantler-tech/world-at-ruin/rulesets/77":
			_ = json.NewEncoder(w).Encode(replacement)
		case "/repos/devantler-tech/world-at-ruin/rulesets/21102220":
			_ = json.NewEncoder(w).Encode(retained)
		case "/repos/devantler-tech/world-at-ruin/rulesets/88":
			if len(extra) != 1 {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			_ = json.NewEncoder(w).Encode(extra[0])
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return &Client{BaseURL: server.URL, Token: "read-only-test", HTTP: server.Client()}
}

func readinessThirdRuleset() map[string]any {
	third, _ := readinessRulesetFixtures()
	third["id"] = 88
	third["name"] = "Another product gate"
	readinessCheck(third)["context"] = "Unrelated check"
	return third
}

func TestReadinessCannotSkipIncompleteAdditionalRepositoryRuleset(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{"missing rules", func(third map[string]any) { delete(third, "rules") }},
		{"null rules", func(third map[string]any) { third["rules"] = nil }},
		{"missing status parameters", func(third map[string]any) { delete(third["rules"].([]any)[0].(map[string]any), "parameters") }},
		{"null status parameters", func(third map[string]any) { third["rules"].([]any)[0].(map[string]any)["parameters"] = nil }},
		{"missing status checks", func(third map[string]any) { delete(readinessParameters(third), "required_status_checks") }},
		{"null status checks", func(third map[string]any) { readinessParameters(third)["required_status_checks"] = nil }},
		{"empty status checks", func(third map[string]any) { readinessParameters(third)["required_status_checks"] = []any{} }},
		{"null check entry", func(third map[string]any) { readinessParameters(third)["required_status_checks"] = []any{nil} }},
		{"missing check context", func(third map[string]any) { delete(readinessCheck(third), "context") }},
		{"missing rule type", func(third map[string]any) { delete(third["rules"].([]any)[0].(map[string]any), "type") }},
		{"missing strict policy", func(third map[string]any) { delete(readinessParameters(third), "strict_required_status_checks_policy") }},
		{"missing creation policy", func(third map[string]any) { delete(readinessParameters(third), "do_not_enforce_on_create") }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			replacement, retained := readinessRulesetFixtures()
			third := readinessThirdRuleset()
			test.mutate(third)
			inventory := []map[string]any{readinessSummary(replacement), readinessSummary(retained), readinessSummary(third)}
			client := readinessClient(t, replacement, retained, inventory, third)
			if err := client.Inspect(context.Background(), readinessTestAppID); err == nil || !strings.Contains(err.Error(), "UNKNOWN") {
				t.Fatalf("incomplete additional repository rule must keep overlap UNKNOWN: %v", err)
			}
		})
	}
}

func TestReadinessAcceptsExplicitEmptyNoncandidateRulesArray(t *testing.T) {
	replacement, retained := readinessRulesetFixtures()
	third := readinessThirdRuleset()
	third["rules"] = []any{}
	inventory := []map[string]any{readinessSummary(replacement), readinessSummary(retained), readinessSummary(third)}
	if err := readinessClient(t, replacement, retained, inventory, third).Inspect(context.Background(), readinessTestAppID); err != nil {
		t.Fatalf("explicit empty unrelated rules array must not be treated as missing evidence: %v", err)
	}
}

func TestReadinessRejectsMatchedCandidateActionsProducerBeforeReading(t *testing.T) {
	requests := 0
	replacement, retained := readinessRulesetFixtures()
	readinessCheck(replacement)["integration_id"] = int64(15368)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		switch r.URL.Path {
		case "/repos/devantler-tech/world-at-ruin/rulesets":
			_ = json.NewEncoder(w).Encode([]map[string]any{readinessSummary(replacement), readinessSummary(retained)})
		case "/repos/devantler-tech/world-at-ruin/rulesets/77":
			_ = json.NewEncoder(w).Encode(replacement)
		case "/repos/devantler-tech/world-at-ruin/rulesets/21102220":
			_ = json.NewEncoder(w).Encode(retained)
		default:
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	client := Client{BaseURL: server.URL, Token: "read-only-test", HTTP: server.Client()}
	if err := client.Inspect(context.Background(), 15368); err == nil {
		t.Fatal("matched candidate-controlled Actions App was accepted as an independent producer")
	}
	if requests != 0 {
		t.Fatalf("known candidate-controlled producer crossed the API boundary: %d reads", requests)
	}
}

func TestReadinessAcceptsOnlyVerifiedOverlap(t *testing.T) {
	replacement, retained := readinessRulesetFixtures()
	client := readinessClient(t, replacement, retained, []map[string]any{readinessSummary(replacement), readinessSummary(retained)})
	if err := client.Inspect(context.Background(), readinessTestAppID); err != nil {
		t.Fatalf("valid active repository/organization overlap was rejected: %v", err)
	}
}

func TestReadinessRejectsReplacementDrift(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{"wrong producer", func(rule map[string]any) { readinessCheck(rule)["integration_id"] = 15368 }},
		{"missing producer", func(rule map[string]any) { delete(readinessCheck(rule), "integration_id") }},
		{"wrong context", func(rule map[string]any) { readinessCheck(rule)["context"] = "Trusted client regressions" }},
		{"inactive rule", func(rule map[string]any) { rule["enforcement"] = "disabled" }},
		{"organization scope", func(rule map[string]any) { rule["source_type"] = "Organization"; rule["source"] = "devantler-tech" }},
		{"wrong repository", func(rule map[string]any) { rule["source"] = "devantler-tech/platform" }},
		{"wrong target", func(rule map[string]any) { rule["target"] = "tag" }},
		{"bypass", func(rule map[string]any) {
			rule["bypass_actors"] = []any{map[string]any{"actor_type": "OrganizationAdmin", "bypass_mode": "always"}}
		}},
		{"missing bypass inventory", func(rule map[string]any) { delete(rule, "bypass_actors") }},
		{"branch spillover", func(rule map[string]any) {
			rule["conditions"].(map[string]any)["ref_name"].(map[string]any)["include"] = []string{"~ALL"}
		}},
		{"branch exclusion", func(rule map[string]any) {
			rule["conditions"].(map[string]any)["ref_name"].(map[string]any)["exclude"] = []string{"main"}
		}},
		{"strict merge behavior", func(rule map[string]any) { readinessParameters(rule)["strict_required_status_checks_policy"] = true }},
		{"create exemption", func(rule map[string]any) { readinessParameters(rule)["do_not_enforce_on_create"] = true }},
		{"extra check", func(rule map[string]any) {
			readinessParameters(rule)["required_status_checks"] = append(readinessParameters(rule)["required_status_checks"].([]any), map[string]any{"context": "another", "integration_id": readinessTestAppID})
		}},
		{"missing strict field", func(rule map[string]any) { delete(readinessParameters(rule), "strict_required_status_checks_policy") }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			replacement, retained := readinessRulesetFixtures()
			test.mutate(replacement)
			client := readinessClient(t, replacement, retained, []map[string]any{readinessSummary(replacement), readinessSummary(retained)})
			if err := client.Inspect(context.Background(), readinessTestAppID); err == nil {
				t.Fatal("readiness accepted drift in the replacement gate")
			}
		})
	}
}

func readinessParameters(rule map[string]any) map[string]any {
	return rule["rules"].([]any)[0].(map[string]any)["parameters"].(map[string]any)
}

func readinessCheck(rule map[string]any) map[string]any {
	return readinessParameters(rule)["required_status_checks"].([]any)[0].(map[string]any)
}

func TestReadinessRejectsPrematureOrganizationRetirement(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{"disabled old gate", func(rule map[string]any) { rule["enforcement"] = "disabled" }},
		{"wrong source", func(rule map[string]any) {
			readinessParameters(rule)["workflows"].([]any)[0].(map[string]any)["repository_id"] = 1
		}},
		{"wrong path", func(rule map[string]any) {
			readinessParameters(rule)["workflows"].([]any)[0].(map[string]any)["path"] = ".github/workflows/candidate.yaml"
		}},
		{"wrong ref", func(rule map[string]any) {
			readinessParameters(rule)["workflows"].([]any)[0].(map[string]any)["ref"] = "refs/heads/unreviewed"
		}},
		{"old gate bypass", func(rule map[string]any) {
			rule["bypass_actors"] = []any{map[string]any{"actor_type": "Integration", "actor_id": readinessTestAppID, "bypass_mode": "always"}}
		}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			replacement, retained := readinessRulesetFixtures()
			test.mutate(retained)
			client := readinessClient(t, replacement, retained, []map[string]any{readinessSummary(replacement), readinessSummary(retained)})
			if err := client.Inspect(context.Background(), readinessTestAppID); err == nil {
				t.Fatal("readiness accepted a changed or retired original protection")
			}
		})
	}
}

func TestReadinessRejectsIncompleteOrAmbiguousEvidence(t *testing.T) {
	for _, name := range []string{"missing replacement", "missing retained", "duplicate inventory", "summary/detail drift", "missing app"} {
		t.Run(name, func(t *testing.T) {
			replacement, retained := readinessRulesetFixtures()
			inventory := []map[string]any{readinessSummary(replacement), readinessSummary(retained)}
			appID := readinessTestAppID
			switch name {
			case "missing replacement":
				inventory = inventory[1:]
			case "missing retained":
				inventory = inventory[:1]
			case "duplicate inventory":
				inventory = append(inventory, inventory[0])
			case "summary/detail drift":
				replacement["enforcement"] = "disabled"
			case "missing app":
				appID = 0
			}
			if err := readinessClient(t, replacement, retained, inventory).Inspect(context.Background(), appID); err == nil {
				t.Fatal("incomplete evidence reported ready")
			}
		})
	}
}

func TestReadinessReadsLaterInventoryPages(t *testing.T) {
	replacement, retained := readinessRulesetFixtures()
	pageOne := []map[string]any{readinessSummary(retained)}
	for i := 0; i < 99; i++ {
		pageOne = append(pageOne, map[string]any{"id": i + 1000, "name": "shared protection", "target": "branch", "source": "devantler-tech", "source_type": "Organization", "enforcement": "active"})
	}
	seenPageTwo := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Query().Get("includes_parents") != "true" {
			t.Error("unexpected mutation or missing inherited rules")
			w.WriteHeader(400)
			return
		}
		var value any
		switch r.URL.Path {
		case "/repos/devantler-tech/world-at-ruin/rulesets":
			switch r.URL.Query().Get("page") {
			case "1":
				value = pageOne
			case "2":
				value = []map[string]any{readinessSummary(replacement)}
				seenPageTwo = true
			default:
				t.Errorf("unexpected page %s", r.URL.RawQuery)
				w.WriteHeader(400)
				return
			}
		case "/repos/devantler-tech/world-at-ruin/rulesets/77":
			value = replacement
		case "/repos/devantler-tech/world-at-ruin/rulesets/21102220":
			value = retained
		default:
			t.Errorf("unexpected detail read %s", r.URL.Path)
			w.WriteHeader(404)
			return
		}
		_ = json.NewEncoder(w).Encode(value)
	}))
	defer server.Close()
	client := Client{BaseURL: server.URL, Token: "read-only-test", HTTP: server.Client()}
	if err := client.Inspect(context.Background(), readinessTestAppID); err != nil || !seenPageTwo {
		t.Fatalf("later-page gate omitted: pageTwo=%v err=%v", seenPageTwo, err)
	}
}

func TestReadinessReportsTransportFailureAsUnknown(t *testing.T) {
	for _, response := range []string{"unavailable", "{}", "null", `[{"id":77}]`} {
		t.Run(response, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if response == "unavailable" {
					w.WriteHeader(503)
					return
				}
				_, _ = w.Write([]byte(response))
			}))
			defer server.Close()
			client := Client{BaseURL: server.URL, Token: "read-only-test", HTTP: server.Client()}
			if err := client.Inspect(context.Background(), readinessTestAppID); err == nil || !strings.Contains(err.Error(), "UNKNOWN") {
				t.Fatalf("partial or unreadable evidence needs UNKNOWN: %v", err)
			}
		})
	}
}
