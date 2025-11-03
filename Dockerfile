# 1. Use Ubuntu LTS (22.04) base image
FROM ubuntu:22.04

# Set German timezone
ENV TZ=Europe/Berlin
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# 2. Install required tools
# --- MODIFIED: Install modern Node.js (v20) from NodeSource PPA ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    iptables \
    iproute2 \
    grep \
    tini \
    proxychains-ng \
    gosu \
    tzdata \
    dnsutils \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && NODE_MAJOR=20 \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# 3. Install the claude tool globally
RUN npm install -g @anthropic-ai/claude-code

# 4. Copy the entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 5. Set the working directory (parent directory for mounting)
WORKDIR /app

# 6. Set Entrypoint with tini
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]

# 7. Default command
CMD ["claude"]
