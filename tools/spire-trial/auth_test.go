package spiretrial

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestDiagnosticEffectsRequireExactMethodAndPath requires refusal before any counted effect.
func TestDiagnosticEffectsRequireExactMethodAndPath(t *testing.T) {
	var effects uint64
	h := diagnosticHandler(&effects)
	for _, tc := range []struct{ method, path string }{
		{http.MethodGet, "/diagnostic"},
		{http.MethodPost, "/claim"},
		{http.MethodPost, "/diagnostic/"},
	} {
		r := httptest.NewRequestWithContext(t.Context(), tc.method, tc.path, nil)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != http.StatusForbidden || effects != 0 {
			t.Fatalf("unauthorized effect: %s %s status=%d effects=%d", tc.method, tc.path, w.Code, effects)
		}
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/diagnostic", nil))
	if w.Code != http.StatusNoContent || effects != 1 {
		t.Fatalf("authorized control status=%d effects=%d", w.Code, effects)
	}
}
