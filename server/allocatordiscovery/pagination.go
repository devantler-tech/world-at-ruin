package allocatordiscovery

import (
	"context"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const pageSize = 100

// collect never restarts an expired list internally or returns its partial data.
// The empty resourceVersion requests a current consistent read, never cache RV 0.
func collect[T any](ctx context.Context, maxPages int, selector string, list func(context.Context, metav1.ListOptions) ([]T, metav1.ListMeta, error)) ([]T, string, error) {
	var items []T
	var version, cursor string
	seen := make(map[string]bool)
	for range maxPages {
		if err := ctx.Err(); err != nil {
			return nil, "", err
		}
		page, meta, err := list(ctx, metav1.ListOptions{LabelSelector: selector, Limit: pageSize, Continue: cursor})
		if cancel := ctx.Err(); cancel != nil {
			return nil, "", cancel
		}
		if err != nil {
			return nil, "", observationError(err)
		}
		if len(page) > pageSize || !token(meta.ResourceVersion, 1024) || (version != "" && version != meta.ResourceVersion) || len(meta.Continue) > 16384 {
			return nil, "", ErrObservation
		}
		version = meta.ResourceVersion
		items = append(items, page...)
		if meta.Continue == "" {
			return items, version, nil
		}
		if seen[meta.Continue] {
			return nil, "", ErrObservation
		}
		seen[meta.Continue] = true
		cursor = meta.Continue
	}
	return nil, "", ErrObservation
}
