# syntax=docker/dockerfile:1.7

FROM debian:bookworm-slim

ARG TARGETARCH
ARG VERSION=dev
ARG SOURCE_REPOSITORY=https://github.com/TomyJan/itdog-agent
ARG SOURCE_REVISION=unknown

LABEL org.opencontainers.image.title="ITDOG Agent" \
      org.opencontainers.image.description="Container image for an ITDOG contributed node agent" \
      org.opencontainers.image.source="$SOURCE_REPOSITORY" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.revision="$SOURCE_REVISION"

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        tini \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 agent-downloads/agent_${TARGETARCH} /usr/local/bin/itdog-agent
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN sha256sum /usr/local/bin/itdog-agent \
    | cut -d ' ' -f 1 > /usr/local/share/itdog-agent.sha256

WORKDIR /opt/itdog-agent
VOLUME ["/opt/itdog-agent"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/local/bin/itdog-agent"]
