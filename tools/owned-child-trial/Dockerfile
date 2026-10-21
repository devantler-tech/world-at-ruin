# Disposable diagnostic process acceptance only. Never publish this image.
FROM golang:1.27.3@sha256:957861185dbf29d93668ace41e011d091c6e779953d47f0316ef2cc58e28fe2b AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG EXPERIMENTAL=false
RUN test "$EXPERIMENTAL" = true
WORKDIR /source
COPY tools/owned-child-trial/ ./
RUN gofmt -l . > /tmp/unformatted && test ! -s /tmp/unformatted && go mod download \
    && go test -race -mod=readonly ./... \
    && go vet -tags=war_child_trial ./... \
    && go test -race -mod=readonly -tags=war_child_trial -c -o /out/owned-child-race.test . \
    && CGO_ENABLED=0 go test -mod=readonly -tags=war_child_trial -c -o /out/owned-child.test . \
    && bash audit-fork-assembly.sh /out/owned-child.test \
    && bash audit-fork-assembly.sh /out/owned-child-race.test \
    && mkdir -p /out/tmp && chmod 1777 /out/tmp
FROM build AS source-race
# The race executable needs the builder's C runtime. This unpublished target is
# exercised through the same read-only, offline, least-capability containment.
USER 10001:10001
ENTRYPOINT ["/out/owned-child-race.test"]
CMD []
FROM scratch
COPY --from=build /out/owned-child.test /out/owned-child.test
COPY --from=build /out/tmp/ /tmp/
USER 10001:10001
ENTRYPOINT ["/out/owned-child.test"]
CMD []
