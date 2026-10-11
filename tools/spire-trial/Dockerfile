# Disposable role-issuer acceptance only. Never publish this image.
FROM golang:1.27.2@sha256:5bc7f572bbaa98885a3a1fd9c0aa76b59e3e14e8628bfc316bbfd0c701e4818c AS build
ARG EXPERIMENTAL=false
ARG TARGETARCH
RUN test "$EXPERIMENTAL" = true
WORKDIR /source
COPY tools/spire-trial/go.mod tools/spire-trial/go.sum ./
RUN go mod download
COPY tools/spire-trial/ ./
RUN gofmt -l . > /tmp/unformatted && test ! -s /tmp/unformatted \
    && go vet -tags=war_spire_trial ./... \
    && go test -race -mod=readonly ./... \
    && CGO_ENABLED=0 go test -mod=readonly -tags=war_spire_trial -c -o /out/spire-trial.test .
# Hashes are release asset SHA256 values, not checksum-file hashes.
RUN case "$TARGETARCH" in \
      amd64) digest=ca1a4d1155317bdd2afc7f36663828a10410c7c840e54725b90b4064b0a301c7 ;; \
      arm64) digest=a9982b3ca7de489def22265fd4586d8e13091ecb6fddf6adcea9291313b18886 ;; \
      *) exit 1 ;; \
    esac \
    && curl --fail --silent --show-error --location --max-time 90 --retry 2 \
      "https://github.com/spiffe/spire/releases/download/v1.15.3/spire-1.15.3-linux-${TARGETARCH}-musl.tar.gz" -o /tmp/spire.tar.gz \
    && printf '%s  %s\n' "$digest" /tmp/spire.tar.gz | sha256sum --check --status \
    && mkdir -p /opt/spire /out/tmp \
    && tar -xzf /tmp/spire.tar.gz --strip-components=1 -C /opt/spire \
    && chmod 1777 /out/tmp \
    && /opt/spire/bin/spire-server --version \
    && /opt/spire/bin/spire-agent --version
FROM scratch
COPY --from=build /out/spire-trial.test /out/spire-trial.test
COPY --from=build /opt/spire/bin/ /opt/spire/bin/
COPY --from=build /out/tmp/ /tmp/
USER 0:0
ENTRYPOINT ["/out/spire-trial.test"]
# Refuses missing explicit opt-in before starting issuer or role processes.
CMD []
