//go:build !war_native_trial || war_issued_trial

package nakamatrial

import (
	"context"
	"errors"
	"time"

	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Only registered-role convergence is polled. SDK validation precedes selection;
// malformed or wrong-role material and permanent errors cannot become readiness.
func awaitIssuedRole(ctx context.Context, expected string, fetch func(context.Context) (*workloadapi.X509Context, error)) (*workloadapi.X509Context, error) {
	for ctx.Err() == nil {
		request, stop := context.WithTimeout(ctx, time.Second)
		material, err := fetch(request)
		stop()
		if ctx.Err() != nil {
			break
		}
		if err == nil {
			if material == nil || len(material.SVIDs) != 1 || material.SVIDs[0] == nil || material.SVIDs[0].ID.String() != expected || material.SVIDs[0].PrivateKey == nil {
				return nil, errors.New("real role credential selection refused")
			}
			return material, nil
		}
		code := status.Code(err)
		if code != codes.PermissionDenied && code != codes.Unavailable && code != codes.DeadlineExceeded {
			return nil, errors.New("real role credential request refused")
		}
		select {
		case <-ctx.Done():
		case <-time.After(100 * time.Millisecond):
		}
	}
	return nil, errors.New("real role credential readiness expired")
}
