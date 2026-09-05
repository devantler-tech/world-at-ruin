package agones

import (
	"context"
	"net"
	"os"

	sdkproto "agones.dev/agones/pkg/sdk"
	gosdk "agones.dev/agones/sdks/go"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// sdkSidecar uses the official lifecycle SDK and a generated-client watch whose
// termination is observable. The high-level SDK's watch hides EOF and stream
// errors from its caller, so its last snapshot cannot prove admission liveness.
type sdkSidecar struct {
	*gosdk.SDK
}

func (s *sdkSidecar) WatchGameServer(ctx context.Context, callback gosdk.GameServerCallback, ended func()) error {
	host, port := os.Getenv("AGONES_SDK_GRPC_HOST"), os.Getenv("AGONES_SDK_GRPC_PORT")
	if host == "" {
		host = "localhost"
	}
	if port == "" {
		port = "9357"
	}
	// This is the same Pod-local SDK endpoint as the official lifecycle client,
	// with no Kubernetes credential or admission secret in the conversation.
	conn, err := grpc.NewClient(net.JoinHostPort(host, port), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	stream, err := sdkproto.NewSDKClient(conn).WatchGameServer(ctx, &sdkproto.Empty{})
	if err != nil {
		_ = conn.Close()
		return err
	}
	go func() {
		defer func() { _ = conn.Close() }()
		defer ended()
		for {
			current, err := stream.Recv()
			if err != nil {
				return
			}
			callback(current)
		}
	}()
	return nil
}
