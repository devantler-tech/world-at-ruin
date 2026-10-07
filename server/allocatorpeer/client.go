// Package allocatorpeer observes pinned allocator generations and connects only
// to their selected, independently authenticated peer. It grants no fence authority.
package allocatorpeer

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"errors"
	"net"
	"net/netip"
	"time"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	"github.com/devantler-tech/world-at-ruin/server/agonesalloc"
	"github.com/devantler-tech/world-at-ruin/server/allocatordiscovery"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
)

var (
	ErrDisabled        = errors.New("allocator peer: disabled")
	ErrInvalidArgument = errors.New("allocator peer: invalid argument")
	ErrObservation     = errors.New("allocator peer: incomplete or changed observation")
	ErrUncertain       = errors.New("allocator peer: allocation outcome uncertain")
	ErrConnection      = errors.New("allocator peer: authenticated connection unavailable")
)

// GenerationReader loads complete versioned private records using the operation context.
type GenerationReader interface {
	Load(context.Context, string) (nakamageneration.Record, error)
}

// DiscoveryReader returns a complete namespace-scoped allocator observation.
type DiscoveryReader interface {
	Discover(context.Context) (allocatordiscovery.Snapshot, error)
}

// Sources supplies context-aware readers; neither reader grants admission authority.
type Sources struct {
	Generations GenerationReader
	Discovery   DiscoveryReader
}

// PeerIdentity independently binds a generation member to its TLS name and server key.
type PeerIdentity struct {
	ServerName string
	SPKI       [32]byte
}

// Credentials accepts static DER inputs only. No caller TLS callbacks, mutable
// pools, session caches, alternate clocks or key log destinations are retained.
type Credentials struct {
	RootDER, CertificateDER [][]byte
	PrivateKeyDER           []byte
}

// Config pins one generation, selected actor, allocation pool and whole-operation budget.
type Config struct {
	Enabled                      bool
	Record                       nakamageneration.Record
	ActorUID, AllocatorNamespace string
	Peers                        map[string]PeerIdentity
	Credentials                  Credentials
	Allocation                   agonesalloc.Config
	Timeout                      time.Duration
}

// Binding is observation metadata, never an admission or quarantine-release token.
type Binding struct {
	GenerationID, SourceVersion, MemberSetDigest, ActorUID                            string
	PodName, PodResourceVersion, PodListResourceVersion, EndpointSliceResourceVersion string
	Address                                                                           netip.AddrPort
	ServerName                                                                        string
}

// Result contains validated allocation material and the observations used for that call.
type Result struct {
	GameServer agonesalloc.GameServer
	Binding    Binding
}

// Client owns an immutable transport configuration and creates one channel per operation.
type Client struct {
	sources Sources
	config  Config
	tls     *tls.Config
}

// NewClient requires explicit opt-in and copies all security-sensitive inputs.
// Construction performs no source reads and opens no connection.
func NewClient(sources Sources, cfg Config) (*Client, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	if nilSource(sources.Generations) || nilSource(sources.Discovery) || !validConfig(cfg) {
		return nil, ErrInvalidArgument
	}
	ownedTLS, err := staticTLS(cfg.Credentials)
	if err != nil {
		return nil, ErrInvalidArgument
	}
	coordinatorKey := sha256.Sum256(ownedTLS.Certificates[0].Leaf.RawSubjectPublicKeyInfo)
	for _, peer := range cfg.Peers {
		if peer.SPKI == coordinatorKey {
			return nil, ErrInvalidArgument
		}
	}
	cfg.Record.MemberPodUIDs = append([]string(nil), cfg.Record.MemberPodUIDs...)
	peers := make(map[string]PeerIdentity, len(cfg.Peers))
	for uid, identity := range cfg.Peers {
		peers[uid] = identity
	}
	cfg.Peers = peers
	cfg.Credentials = Credentials{}
	if cfg.Timeout == 0 {
		cfg.Timeout = 5 * time.Second
	}
	return &Client{sources: sources, config: cfg, tls: ownedTLS}, nil
}

// Reserve performs fresh complete observations before and after connection
// readiness, then invokes the existing allocation boundary once. This does not
// replace the coordinator's durable dispatch barrier, atomic fence or recovery.
func (c *Client) Reserve(ctx context.Context, request agonesalloc.Request) (Result, error) {
	ctx, cancel := context.WithTimeout(ctx, c.config.Timeout)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	if err := c.checkGeneration(ctx); err != nil {
		return Result{}, err
	}
	if !handoffidentity.CorrelationID(request.ReservationID) || !handoffidentity.CorrelationID(request.AttemptID) || !handoffidentity.SHA256Hex(request.LeaseObjectID) {
		return Result{}, ErrInvalidArgument
	}
	binding, err := c.observe(ctx)
	if err != nil {
		return Result{}, err
	}
	tlsConfig := c.tls.Clone()
	identity := c.config.Peers[c.config.ActorUID]
	tlsConfig.ServerName = identity.ServerName
	tlsConfig.VerifyConnection = verifyPeer(identity.SPKI)
	literal := binding.Address.String()
	dialer := &net.Dialer{}
	connection, err := grpc.NewClient("passthrough:///"+literal,
		grpc.WithTransportCredentials(credentials.NewTLS(tlsConfig)), grpc.WithAuthority(identity.ServerName),
		grpc.WithContextDialer(func(dialCtx context.Context, target string) (net.Conn, error) {
			if target != literal {
				return nil, ErrConnection
			}
			return dialer.DialContext(dialCtx, "tcp", literal)
		}), grpc.WithNoProxy(), grpc.WithDisableServiceConfig(), grpc.WithDisableRetry(),
		grpc.WithDefaultCallOptions(grpc.MaxRetryRPCBufferSize(0), grpc.MaxCallRecvMsgSize(65536), grpc.MaxCallSendMsgSize(8192)))
	if err != nil {
		return Result{}, ErrConnection
	}
	defer func() { _ = connection.Close() }()
	connection.Connect()
	for {
		state := connection.GetState()
		if state == connectivity.Ready {
			break
		}
		if state == connectivity.Shutdown || !connection.WaitForStateChange(ctx, state) {
			return Result{}, boundedFailure(ctx, ErrConnection)
		}
	}
	// A slow handshake must not authorize a now-stale observation. These reads
	// still cannot make admission atomic with the allocator's later native write.
	fresh, err := c.observe(ctx)
	if err != nil {
		return Result{}, err
	}
	if fresh != binding {
		return Result{}, ErrObservation
	}
	api := &allocationCall{client: allocationpb.NewAllocationServiceClient(connection)}
	allocator, err := agonesalloc.NewClient(api, c.config.Allocation)
	if err != nil {
		return Result{}, ErrInvalidArgument
	}
	gameServer, err := allocator.Reserve(ctx, request)
	if err == nil {
		err = ctx.Err()
	}
	if err != nil {
		if api.entered {
			// Strip terminal-looking allocator sentinels and upstream text. Even an
			// allocator's empty-pool answer cannot rule out a delayed native write.
			interruption := ctx.Err()
			code := status.Code(err)
			// A peer or transport deadline may arrive before our context timer.
			// Preserve interrupted RPC identity independently of that timer race.
			switch code {
			case codes.Canceled:
				interruption = errors.Join(interruption, context.Canceled)
			case codes.DeadlineExceeded:
				interruption = errors.Join(interruption, context.DeadlineExceeded)
			case codes.OK, codes.Unknown, codes.InvalidArgument, codes.NotFound,
				codes.AlreadyExists, codes.PermissionDenied, codes.ResourceExhausted,
				codes.FailedPrecondition, codes.Aborted, codes.OutOfRange, codes.Unimplemented,
				codes.Internal, codes.Unavailable, codes.DataLoss, codes.Unauthenticated:
				// Other RPC codes do not assert an interruption identity.
			}
			return Result{}, errors.Join(ErrUncertain, interruption, status.Error(code, "allocator peer: allocation failed"))
		}
		return Result{}, ErrInvalidArgument
	}
	return Result{GameServer: gameServer, Binding: binding}, nil
}

// observe brackets complete discovery with reads of the exact pinned generation.
func (c *Client) observe(ctx context.Context) (Binding, error) {
	if err := c.checkGeneration(ctx); err != nil {
		return Binding{}, err
	}
	snapshot, err := c.sources.Discovery.Discover(ctx)
	if err != nil {
		return Binding{}, boundedFailure(ctx, ErrObservation)
	}
	binding, err := selectBinding(c.config, snapshot)
	if err != nil {
		return Binding{}, err
	}
	if err := c.checkGeneration(ctx); err != nil {
		return Binding{}, err
	}
	return binding, nil
}

// checkGeneration refuses missing, changed or invalid source state without exposing backend text.
func (c *Client) checkGeneration(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	record, err := c.sources.Generations.Load(ctx, c.config.Record.GenerationID)
	if err != nil || !sameGeneration(record, c.config.Record) {
		return boundedFailure(ctx, ErrObservation)
	}
	return ctx.Err()
}

// boundedFailure retains the boundary category and caller cancellation without upstream details.
func boundedFailure(ctx context.Context, kind error) error { return errors.Join(kind, ctx.Err()) }

type allocationCall struct {
	client  allocationpb.AllocationServiceClient
	entered bool
}

// Allocate marks dispatch before entering the generated RPC so later errors remain uncertain.
func (c *allocationCall) Allocate(ctx context.Context, request *allocationpb.AllocationRequest, options ...grpc.CallOption) (*allocationpb.AllocationResponse, error) {
	c.entered = true
	return c.client.Allocate(ctx, request, options...)
}
