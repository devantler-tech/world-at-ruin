# Go's multiarchitecture index is pinned; compilation stays on the builder's
# native architecture, so publishing arm64 needs no emulation or privileged VM.
FROM --platform=$BUILDPLATFORM golang:1.27.1@sha256:e0174e51e81218523251d85d248a90d24c3d5e81543b4f07a5d66229397db190 AS build
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -buildvcs=false -o /out/zone ./cmd/zone \
    && CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -buildvcs=false -o /out/zoneprobe ./cmd/zoneprobe

FROM scratch
COPY --from=build /out/zone /zone
COPY --from=build /out/zoneprobe /zoneprobe
# The probe needs normal public trust as well as its explicit fixture CA option.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
EXPOSE 8443
STOPSIGNAL SIGTERM
ENTRYPOINT ["/zone"]
# Running an image without an opt-in does not expose a listener.
CMD ["-ticks", "600"]
