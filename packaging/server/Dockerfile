# NovaSwift Dedicated Server, multi-arch (linux/amd64 + linux/arm64):
#   docker buildx build --platform linux/amd64,linux/arm64 -f packaging/server/Dockerfile -t novaswift-server .
# Build context is the repository root.
FROM swift:6.3-jammy AS build
WORKDIR /src
COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product novaswift-server --static-swift-stdlib \
 && cp "$(swift build -c release --product novaswift-server --show-bin-path)/novaswift-server" /NovaSwiftServer \
 && strip /NovaSwiftServer

FROM ubuntu:22.04
# Runs as an unprivileged account (uid 10001) with no login shell. The data folder is the only writable place; run the
# container with --read-only (see docker-compose.yml).
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libcurl4 libxml2 ca-certificates tzdata && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --user-group --home-dir /data --shell /usr/sbin/nologin novaswift \
 && mkdir -p /data && chown novaswift:novaswift /data && chmod 700 /data
COPY --from=build --chown=root:root /NovaSwiftServer /usr/local/bin/NovaSwiftServer
ENV NOVASWIFT_SUPERVISED=1
# Inside the container the admin panel must listen on all addresses so Docker can publish it; docker-compose.yml
# publishes it on the host's 127.0.0.1 only.
ENV NOVASWIFT_ADMIN_BIND=0.0.0.0
USER 10001:10001
WORKDIR /data
VOLUME /data
# Game (UDP), server-list pings (UDP), admin panel (TCP)
EXPOSE 53735/udp 53736/udp 53737/tcp
ENTRYPOINT ["NovaSwiftServer", "--data", "/data", "--no-browser", "--no-stdin"]
