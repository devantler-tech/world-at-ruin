module github.com/devantler-tech/world-at-ruin/tools/spire-trial

go 1.27.3

require (
	github.com/devantler-tech/world-at-ruin/server v0.0.0
	github.com/spiffe/go-spiffe/v2 v2.9.0
	golang.org/x/sys v0.49.0
	google.golang.org/grpc v1.84.0
)

require (
	agones.dev/agones v1.61.0 // indirect
	github.com/Microsoft/go-winio v0.6.2 // indirect
	github.com/coder/websocket v1.8.15 // indirect
	github.com/go-jose/go-jose/v4 v4.1.6 // indirect
	github.com/go-logr/logr v1.4.4 // indirect
	github.com/gofrs/uuid/v5 v5.5.1 // indirect
	github.com/grpc-ecosystem/grpc-gateway/v2 v2.30.0 // indirect
	github.com/heroiclabs/nakama-common v1.48.0 // indirect
	golang.org/x/net v0.61.0 // indirect
	golang.org/x/text v0.43.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260908043556-f8649ddbbfe6 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20261005182115-fad411399dd8 // indirect
	google.golang.org/protobuf v1.36.12 // indirect
	k8s.io/apimachinery v0.37.1 // indirect
	k8s.io/klog/v2 v2.140.0 // indirect
	k8s.io/utils v0.0.0-20260626114624-be93311217bd // indirect
)

replace github.com/devantler-tech/world-at-ruin/server => ../../server
