// Package orphanreaper reclaims exact-UID managed GameServers after complete
// resource and lease scans establish consecutive orphan observations.
//
// The resource scan precedes the lease scan. Safety depends on the handoff
// contract: a durable lease precedes allocation, its attempt ID is never reused,
// and resource cleanup precedes lease removal. Grace is additional crash and
// observation protection, not a transaction across Kubernetes and Nakama.
package orphanreaper

import (
	"context"
	"encoding/base32"
	"errors"
	"strings"
	"sync"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/gameserverapi"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/selection"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/validation"
)

const pageSize = 100

var (
	// ErrScan means absence could not be established from complete evidence.
	ErrScan = errors.New("orphan reconciliation: incomplete observation")
	// ErrCleanup means an exact resource still needs cleanup or observation.
	ErrCleanup = errors.New("orphan reconciliation: cleanup pending")
	// ErrBusy prevents overlapping sweeps from sharing observation history.
	ErrBusy = errors.New("orphan reconciliation: sweep already running")
)

// LeaseReader returns a complete set of protected attempt digests. A nil set
// or any error refuses cleanup. nakamalease.Store implements this boundary.
type LeaseReader interface {
	ProtectedAttempts(context.Context, int) (map[string]struct{}, error)
}

// Config scopes one reconciler to a namespaced Fleet. Zero optional values use
// a two-minute grace, thirty-second interval/deadline, and 100-page scan budget.
// Resource and lease scans each use at most MaxPages pages of 100 objects.
type Config struct {
	Namespace, Fleet              string
	Grace, Interval, SweepTimeout time.Duration
	MaxPages                      int
}

// Report contains only counts, suitable for aggregate metrics without labels
// containing player, lease, GameServer, token or envelope identities. Deleted
// counts acknowledged deletes and ambiguous deletes subsequently proven absent.
type Report struct {
	Scanned, Waiting, Protected, Deleted, Changed, Failed int
}

type candidate struct {
	name    string
	uid     types.UID
	attempt string
}

// Reconciler owns process-local observation history. A restart always requires
// a fresh grace period. Constructing it performs no I/O; Run is explicit opt-in.
type Reconciler struct {
	api          gameserverapi.ResourceAPI
	leases       LeaseReader
	cfg          Config
	selector     string
	now          func() time.Time
	mu           sync.Mutex
	observations map[candidate]time.Time
	lastScan     time.Time
}

// New validates the scope and bounded operational settings without activating
// cleanup. The ResourceAPI must be bound to cfg.Namespace.
func New(api gameserverapi.ResourceAPI, leases LeaseReader, cfg Config) (*Reconciler, error) {
	if api == nil || leases == nil || len(validation.IsDNS1123Label(cfg.Namespace)) != 0 ||
		len(cfg.Fleet) > 63 || len(validation.IsDNS1123Subdomain(cfg.Fleet)) != 0 {
		return nil, errors.New("orphan reconciliation: invalid dependencies or scope")
	}
	if cfg.Grace == 0 {
		cfg.Grace = 2 * time.Minute
	}
	if cfg.Interval == 0 {
		cfg.Interval = 30 * time.Second
	}
	if cfg.SweepTimeout == 0 {
		cfg.SweepTimeout = 30 * time.Second
	}
	if cfg.MaxPages == 0 {
		cfg.MaxPages = 100
	}
	if cfg.Grace < 30*time.Second || cfg.Grace > time.Hour ||
		cfg.Interval < time.Second || cfg.Interval > time.Hour ||
		cfg.SweepTimeout < time.Millisecond || cfg.SweepTimeout > time.Minute ||
		cfg.MaxPages < 1 || cfg.MaxPages > 1000 {
		return nil, errors.New("orphan reconciliation: invalid scan budget")
	}
	requirement, err := labels.NewRequirement(agones.AttemptLabel, selection.Exists, nil)
	if err != nil {
		return nil, errors.New("orphan reconciliation: invalid selector")
	}
	selector := labels.SelectorFromSet(labels.Set{agones.FleetLabel: cfg.Fleet}).Add(*requirement)
	return &Reconciler{api: api, leases: leases, cfg: cfg, selector: selector.String(), now: time.Now, observations: make(map[candidate]time.Time)}, nil
}

// Sweep completes both bounded scans before allowing any deletion. An
// incomplete scan clears history so it cannot count as a consecutive absence.
// Individual cleanup failures are retried in later sweeps; unrelated orphans
// still progress. Every API error is sanitized at this boundary.
func (r *Reconciler) Sweep(ctx context.Context) (Report, error) {
	if !r.mu.TryLock() {
		return Report{}, ErrBusy
	}
	defer r.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, r.cfg.SweepTimeout)
	defer cancel()
	servers, err := r.scan(ctx)
	if err != nil {
		return Report{}, r.refuseScan(ctx, err)
	}
	protected, err := r.leases.ProtectedAttempts(ctx, r.cfg.MaxPages)
	if err != nil || protected == nil {
		return Report{}, r.refuseScan(ctx, err)
	}
	if err := ctx.Err(); err != nil {
		return Report{}, r.refuseScan(ctx, err)
	}
	now := r.now()
	if now.IsZero() || now.Before(r.lastScan) {
		return Report{}, r.refuseScan(ctx, ErrScan)
	}
	r.lastScan = now
	report := Report{Scanned: len(servers)}
	next := make(map[candidate]time.Time)
	var cleanupErr error
	for _, server := range servers {
		if err := ctx.Err(); err != nil {
			clear(r.observations)
			return report, err
		}
		if _, owned := protected[server.attempt]; owned {
			report.Protected++
			continue
		}
		first, observed := r.observations[server]
		if !observed {
			first = now
		}
		next[server] = first
		if !observed || now.Sub(first) < r.cfg.Grace {
			report.Waiting++
			continue
		}
		deleted, err := r.reclaim(ctx, server)
		if err != nil {
			report.Failed++
			cleanupErr = nakamastorage.SanitizeError(ctx, err, ErrCleanup)
			continue
		}
		delete(next, server)
		if deleted {
			report.Deleted++
		} else {
			report.Changed++
		}
	}
	r.observations = next
	return report, cleanupErr
}

func (r *Reconciler) refuseScan(ctx context.Context, err error) error {
	clear(r.observations)
	return nakamastorage.SanitizeError(ctx, err, ErrScan)
}

func (r *Reconciler) scan(ctx context.Context) ([]candidate, error) {
	var candidates []candidate
	seen := make(map[string]bool)
	cursors := map[string]bool{"": true}
	cursor, revision := "", ""
	for range r.cfg.MaxPages {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		list, err := r.api.List(ctx, metav1.ListOptions{LabelSelector: r.selector, Limit: pageSize, Continue: cursor})
		if err != nil {
			return nil, err
		}
		if list == nil || len(list.Items) > pageSize || list.ResourceVersion == "" || list.ResourceVersion == "0" || len(list.Continue) > 16384 {
			return nil, ErrScan
		}
		if revision != "" && list.ResourceVersion != revision {
			return nil, ErrScan
		}
		revision = list.ResourceVersion
		for i := range list.Items {
			server := &list.Items[i]
			if server.Namespace != r.cfg.Namespace || server.Labels[agones.FleetLabel] != r.cfg.Fleet || seen[server.Name] {
				return nil, ErrScan
			}
			seen[server.Name] = true
			if server.Status.State != agonesv1.GameServerStateAllocated {
				continue
			}
			value := server.Labels[agones.AttemptLabel]
			if value == "" {
				continue
			}
			if !validDigest(value) || server.UID == "" || len(validation.IsDNS1123Subdomain(server.Name)) != 0 {
				return nil, ErrScan
			}
			candidates = append(candidates, candidate{name: server.Name, uid: server.UID, attempt: value})
		}
		if list.Continue == "" {
			return candidates, nil
		}
		if cursors[list.Continue] {
			return nil, ErrScan
		}
		cursors[list.Continue] = true
		cursor = list.Continue
	}
	return nil, ErrScan
}

func validDigest(value string) bool {
	if len(value) != 52 {
		return false
	}
	encoding := base32.StdEncoding.WithPadding(base32.NoPadding)
	decoded, err := encoding.DecodeString(strings.ToUpper(value))
	return err == nil && len(decoded) == 32 && strings.ToLower(encoding.EncodeToString(decoded)) == value
}

func (r *Reconciler) reclaim(ctx context.Context, expected candidate) (bool, error) {
	server, err := r.api.Get(ctx, expected.name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if server == nil {
		return false, ErrCleanup
	}
	if server.Namespace != r.cfg.Namespace || server.Name != expected.name || server.UID != expected.uid ||
		server.Labels[agones.FleetLabel] != r.cfg.Fleet || server.Labels[agones.AttemptLabel] != expected.attempt ||
		server.Status.State != agonesv1.GameServerStateAllocated {
		return false, nil
	}
	if server.ResourceVersion == "" {
		return false, ErrCleanup
	}
	uid, revision := expected.uid, server.ResourceVersion
	err = r.api.Delete(ctx, expected.name, metav1.DeleteOptions{Preconditions: &metav1.Preconditions{UID: &uid, ResourceVersion: &revision}})
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if err == nil || apierrors.IsNotFound(err) {
		return true, nil
	}
	// A delete response can be lost after commit. Observe once; a surviving
	// exact UID retries through the full next sweep, never an immediate loop.
	latest, readErr := r.api.Get(ctx, expected.name, metav1.GetOptions{})
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if apierrors.IsNotFound(readErr) {
		return true, nil
	}
	if readErr != nil {
		return false, readErr
	}
	if latest != nil && latest.Namespace == r.cfg.Namespace && latest.Name == expected.name && latest.UID != "" && latest.UID != expected.uid {
		return false, nil
	}
	return false, ErrCleanup
}

// Run sweeps at startup and then at the configured interval until cancellation.
// Observation callbacks receive sanitized errors and aggregate counts only.
// Failed scans and cleanup retry on the next tick. Callbacks must be prompt.
func (r *Reconciler) Run(ctx context.Context, observe func(Report, error)) error {
	ticker := time.NewTicker(r.cfg.Interval)
	defer ticker.Stop()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		report, err := r.Sweep(ctx)
		if observe != nil {
			observe(report, err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}
