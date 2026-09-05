package nakamastorage

import (
	"context"
	"strings"

	"github.com/heroiclabs/nakama-common/runtime"
)

// AuthenticatedSubjectID returns the lower-cased subject the Nakama runtime
// authenticated for ctx, provided it is a valid subject and the caller asked
// for exactly that account. A store keyed by account calls this before every
// read or write, so one player can never address another's record whatever
// the request claims.
func AuthenticatedSubjectID(
	ctx context.Context,
	requestedSubjectID string,
) (string, bool) {
	if ctx == nil {
		return "", false
	}
	callerSubjectID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	callerSubjectID = strings.ToLower(callerSubjectID)
	requestedSubjectID = strings.ToLower(requestedSubjectID)
	if !ok ||
		!ValidSubjectID(callerSubjectID) ||
		!ValidSubjectID(requestedSubjectID) ||
		callerSubjectID != requestedSubjectID {
		return "", false
	}
	return callerSubjectID, true
}
