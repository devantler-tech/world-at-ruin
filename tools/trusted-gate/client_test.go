package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestDoJSONAuthenticatedBoundedRequest(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/devantler-tech/world-at-ruin/statuses/abc" || r.Method != http.MethodPost {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer private-test-token" {
			t.Error("missing independent authentication")
		}
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body["state"] != "pending" {
			t.Errorf("incorrect JSON body: %v %v", body, err)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		fmt.Fprint(w, `{"id":73}`)
	}))
	defer srv.Close()
	client := Client{BaseURL: srv.URL, Token: "private-test-token", HTTP: srv.Client()}
	var result struct{ ID int }
	if err := client.DoJSON(context.Background(), http.MethodPost, "/repos/devantler-tech/world-at-ruin/statuses/abc", map[string]string{"state": "pending"}, &result); err != nil {
		t.Fatal(err)
	}
	if result.ID != 73 {
		t.Fatalf("response not decoded: %v", result)
	}
}

func TestDoJSONRefusesRedirectBeforeCredentialLeaves(t *testing.T) {
	var destinationCalls atomic.Int32
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		destinationCalls.Add(1)
		fmt.Fprint(w, `{}`)
	}))
	defer destination.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, destination.URL, http.StatusTemporaryRedirect)
	}))
	defer origin.Close()
	client := Client{BaseURL: origin.URL, Token: "private-test-token", HTTP: origin.Client()}
	var result any
	if err := client.DoJSON(context.Background(), http.MethodGet, "/repos/devantler-tech/world-at-ruin", nil, &result); err == nil {
		t.Fatal("redirected authenticated request accepted")
	}
	if destinationCalls.Load() != 0 {
		t.Fatal("authenticated transport visited redirect destination")
	}
}

func TestDoJSONRefusesIncompleteAndInvalidBodies(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		status     int
	}{
		{"truncated", `{"id":`, http.StatusOK},
		{"trailing_document", `{} {}`, http.StatusOK},
		{"trailing_garbage", `{} unexpected`, http.StatusOK},
		{"null", `null`, http.StatusOK},
		{"oversized", strings.Repeat(" ", 8*1024*1024+1), http.StatusOK},
		{"forbidden", `{"message":"private-test-token"}`, http.StatusForbidden},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				fmt.Fprint(w, tc.body)
			}))
			defer srv.Close()
			client := Client{BaseURL: srv.URL, Token: "private-test-token", HTTP: srv.Client()}
			var result any
			err := client.DoJSON(context.Background(), http.MethodGet, "/repos/devantler-tech/world-at-ruin", nil, &result)
			if err == nil {
				t.Fatal("invalid or incomplete API body accepted")
			}
			if strings.Contains(err.Error(), "private-test-token") {
				t.Fatal("API error disclosed private response content")
			}
		})
	}
}

func TestDoJSONRefusesForeignEndpointsAndCancelledContext(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		fmt.Fprint(w, `{}`)
	}))
	defer srv.Close()
	client := Client{BaseURL: srv.URL, HTTP: srv.Client()}
	for _, path := range []string{"https://other.invalid/repos/devantler-tech/world-at-ruin", "/repos/other/world-at-ruin", "/repos/devantler-tech/world-at-ruin/../../other", "/repos/devantler-tech/world-at-ruin%2fother", "//other.invalid/path"} {
		var result any
		if err := client.DoJSON(context.Background(), http.MethodGet, path, nil, &result); err == nil {
			t.Errorf("foreign or ambiguous endpoint accepted: %s", path)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var result any
	if err := client.DoJSON(ctx, http.MethodGet, "/repos/devantler-tech/world-at-ruin", nil, &result); err == nil {
		t.Fatal("cancelled request accepted")
	}
	if calls.Load() != 0 {
		t.Fatal("inadmissible request reached network")
	}
}

func TestDoJSONRefusesPartialReadDespiteValidJSONPrefix(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "100")
		fmt.Fprint(w, `{}`)
	}))
	defer srv.Close()
	client := Client{BaseURL: srv.URL, HTTP: srv.Client()}
	var result any
	if err := client.DoJSON(context.Background(), http.MethodGet, "/repos/devantler-tech/world-at-ruin", nil, &result); err == nil {
		t.Fatal("partial API response accepted because its received prefix was valid JSON")
	}
}
