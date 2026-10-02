FROM ubuntu:24.04@sha256:a853f94d226358a79c740cfc7bce0c289748f3fe3488d921d038ccd752c61b60
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfontconfig1=2.15.0-1.1ubuntu2 libx11-6=2:1.8.7-1build1 \
    libxcursor1=1:1.2.1-1build1 libxinerama1=2:1.1.4-3build1 \
    libgl1=1.7.0-1build1 libxi6=2:1.8.1-1build1 libxrandr2=2:1.5.2-2build1 \
    libwayland-client0=1.22.0-2.1build1 libxkbcommon0=1.6.0-1build1 \
    libdbus-1-3=1.14.10-4ubuntu4.1 \
    && rm -rf /var/lib/apt/lists/*
COPY --chmod=0555 godot /usr/local/bin/godot
USER 1001:1001
WORKDIR /project
ENTRYPOINT ["/usr/local/bin/godot"]
