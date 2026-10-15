# Reuse the immutable public trust bundle already used by the zone image.
FROM golang:1.27.1@sha256:e0174e51e81218523251d85d248a90d24c3d5e81543b4f07a5d66229397db190 AS certificates

FROM ubuntu:24.04@sha256:a853f94d226358a79c740cfc7bce0c289748f3fe3488d921d038ccd752c61b60
ARG WAR_RUNTIME_INVENTORY=0
COPY capture-trusted-runtime-inventory.sh /tmp/capture-trusted-runtime-inventory.sh
# Minimal Ubuntu has no CA store: preserve HTTPS and package signature checks.
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
# Every locked runtime dependency resolves from main. Restrict index acquisition
# to that component while retaining the immutable snapshot and all package checks.
# The snapshot service can fail intermittently: extend APT's default three
# retries to six, bound each connection/data stall and reject incomplete indexes.
# The reviewed runtime build/pull phase still owns the 900-second overall bound.
RUN sed -i 's/^Components:.*/Components: main/' /etc/apt/sources.list.d/ubuntu.sources \
    && printf '%s\n' \
    'APT::Snapshot "20261003T000000Z";' \
    'Acquire::Retries "6";' \
    'Acquire::http::Timeout "20";' \
    'Acquire::https::Timeout "20";' \
    'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/50snapshot \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    libfontconfig1=2.15.0-1.1ubuntu2 libx11-6=2:1.8.7-1build1 \
    libxcursor1=1:1.2.1-1build1 libxinerama1=2:1.1.4-3build1 \
    libgl1=1.7.0-1build1 libxi6=2:1.8.1-1build1 libxrandr2=2:1.5.2-2build1 \
    libwayland-client0=1.22.0-2.1build1 libxkbcommon0=1.6.0-1build1 \
    libdbus-1-3=1.14.10-4ubuntu4.1 \
    && case "$WAR_RUNTIME_INVENTORY" in 0) ;; 1) bash /tmp/capture-trusted-runtime-inventory.sh;; *) exit 1;; esac \
    && rm /tmp/capture-trusted-runtime-inventory.sh \
    && rm -rf /var/lib/apt/lists/*
COPY --chmod=0555 godot /usr/local/bin/godot
RUN if [ "$WAR_RUNTIME_INVENTORY" = 1 ]; then \
    printf 'engine\t%s\nEND\n' "$(sha256sum /usr/local/bin/godot | cut -d ' ' -f 1)" >> /usr/share/war-trusted-runtime/inventory.tsv; fi
USER 1001:1001
WORKDIR /project
ENTRYPOINT ["/usr/local/bin/godot"]
