# Go's multiarchitecture index is pinned; compilation stays on the builder's
# native architecture, so publishing arm64 needs no emulation or privileged VM.
FROM --platform=$BUILDPLATFORM golang:1.27.2@sha256:5bc7f572bbaa98885a3a1fd9c0aa76b59e3e14e8628bfc316bbfd0c701e4818c AS build
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
