# Disposable diagnostic process acceptance only. Never publish this image.
FROM golang:1.27.2@sha256:5bc7f572bbaa98885a3a1fd9c0aa76b59e3e14e8628bfc316bbfd0c701e4818c AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG EXPERIMENTAL=false
RUN test "$EXPERIMENTAL" = true
WORKDIR /source
COPY tools/owned-child-trial/ ./
RUN gofmt -l . > /tmp/unformatted && test ! -s /tmp/unformatted && go mod download \
    && go test -race -mod=readonly ./... \
    && go vet -tags=war_child_trial ./... \
    && CGO_ENABLED=0 go test -mod=readonly -tags=war_child_trial -c -o /out/owned-child.test . \
    && mkdir -p /out/tmp && chmod 1777 /out/tmp
FROM scratch
COPY --from=build /out/owned-child.test /out/owned-child.test
COPY --from=build /out/tmp/ /tmp/
USER 10001:10001
ENTRYPOINT ["/out/owned-child.test"]
CMD []
