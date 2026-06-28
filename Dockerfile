FROM ubuntu:22.04

# Set German timezone
ENV TZ=Europe/Helsinki
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Install required tools (Added privoxy)
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    iptables \
    iproute2 \
    grep \
    proxychains-ng \
    gosu \
    tzdata \
    dnsutils \
    git \
    privoxy \
    && rm -rf /var/lib/apt/lists/*


ARG HTTP_PROXY
ARG HTTPS_PROXY

# Install Claude (Updated for v2.1+)
RUN curl -x "$HTTPS_PROXY" -fsSL https://claude.ai/install.sh | bash && \
    cp -L /root/.local/bin/claude /usr/local/bin/claude && \
    chmod +x /usr/local/bin/claude && \
    rm -rf /root/.claude /root/.local

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /app
ENTRYPOINT ["/entrypoint.sh"]
CMD ["claude"]
