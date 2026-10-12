package spiretrial

import (
	"net/http"
	"sync/atomic"
)

// expectedCaller permits exactly one predecessor in the diagnostic role cycle.
// Unknown roles have no permitted caller.
func expectedCaller(server string) string {
	switch server {
	case "custodian":
		return "supervisor"
	case "child":
		return "custodian"
	case "supervisor":
		return "child"
	default:
		return ""
	}
}

// diagnosticHandler applies the exact method/path gate after TLS authenticates the role.
// This counter is deliberately unrelated to any launch or storage authority.
func diagnosticHandler(effects *uint64) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/diagnostic" || r.URL.RawQuery != "" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		atomic.AddUint64(effects, 1)
		w.WriteHeader(http.StatusNoContent)
	})
}
