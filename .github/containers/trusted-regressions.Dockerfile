FROM ubuntu:24.04@sha256:a853f94d226358a79c740cfc7bce0c289748f3fe3488d921d038ccd752c61b60
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfontconfig1 libx11-6 libxcursor1 libxinerama1 libgl1 libxi6 \
    libxrandr2 libwayland-client0 libxkbcommon0 libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*
COPY --chmod=0555 godot /usr/local/bin/godot
USER 1001:1001
WORKDIR /project
ENTRYPOINT ["/usr/local/bin/godot"]
