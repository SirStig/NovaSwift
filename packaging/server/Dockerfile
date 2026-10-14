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
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libcurl4 libxml2 ca-certificates tzdata && rm -rf /var/lib/apt/lists/* \
 && useradd --system --home-dir /data --shell /usr/sbin/nologin novaswift && mkdir -p /data && chown novaswift /data
COPY --from=build /NovaSwiftServer /usr/local/bin/NovaSwiftServer
ENV NOVASWIFT_SUPERVISED=1
USER novaswift
VOLUME /data
# Game (UDP), server-list pings (UDP), admin panel (TCP)
EXPOSE 53735/udp 53736/udp 53737/tcp
ENTRYPOINT ["NovaSwiftServer", "--data", "/data", "--no-browser", "--no-stdin"]
