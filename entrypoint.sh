#!/bin/sh
set -e

# --- Variables ---
PROXY_HOST="host.docker.internal"
PROXY_PORT="10808"
EXPECTED_COUNTRY=${EXPECTED_COUNTRY:-DE}
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.0.0 Safari/537.36"

# --- 1. Check permissions (requires root) ---
if ! ip link add dummy0 type dummy >/dev/null 2>&1; then
    echo "❌ Error: Container was not run with '--cap-add=NET_ADMIN' permission."
    exit 1
fi
ip link del dummy0 >/dev/null 2>&1 || true

# --- 2. Activate Kill Switch (requires root) ---
PROXY_IP=$(getent ahostsv4 $PROXY_HOST 2>/dev/null | awk 'NR==1{print $1}')
[ -z "$PROXY_IP" ] && PROXY_IP=$(getent hosts $PROXY_HOST | awk '{ print $1 }')
if [ -z "$PROXY_IP" ]; then
    echo "❌ Error: Could not resolve IP for $PROXY_HOST."
    exit 1
fi
iptables -F OUTPUT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -d $PROXY_IP -p tcp --dport $PROXY_PORT -j ACCEPT
iptables -P OUTPUT DROP

# --- 3. Create proxychains config file (for curl check) ---
{
  echo "strict_chain"
  echo "proxy_dns"
  echo "[ProxyList]"
  echo "socks5  $PROXY_IP $PROXY_PORT"
} > /etc/proxychains.conf

# --- 4. Verify IP and DNS ---
JSON_RESPONSE=$(proxychains -q -f /etc/proxychains.conf curl -s -A "$USER_AGENT" --connect-timeout 10 "http://ip-api.com/json" || echo "fail")
MY_IP=$(echo "$JSON_RESPONSE" | grep -o '"query":"[^"]*"' | cut -d '"' -f 4)
COUNTRY_CODE=$(echo "$JSON_RESPONSE" | grep -o '"countryCode":"[^"]*"' | cut -d '"' -f 4)
if [ -z "$MY_IP" ] || [ -z "$COUNTRY_CODE" ]; then
    echo "❌ Error: Could not extract IP/Country from JSON response."
    exit 1
fi
if [ "$COUNTRY_CODE" != "$EXPECTED_COUNTRY" ]; then
    echo "❌ Error: Your IP is not in Finland ($EXPECTED_COUNTRY). Current location: $COUNTRY_CODE."
    exit 1
fi

# --- 5. Start Privoxy (SOCKS5 to HTTP Translator) ---
echo "listen-address 127.0.0.1:8118" > /etc/privoxy/config
# forward-socks5t ensures DNS requests are also tunneled securely
echo "forward-socks5t / $PROXY_IP:$PROXY_PORT ." >> /etc/privoxy/config
privoxy /etc/privoxy/config

# --- 6. Setup user and drop privileges ---
USER_ID=${HOST_UID:-1000}
GROUP_ID=${HOST_GID:-1000}

if ! getent group $GROUP_ID > /dev/null; then
    addgroup --gid $GROUP_ID claude-group >/dev/null 2>&1
fi
GROUP_NAME=$(getent group $GROUP_ID | cut -d: -f1)

mkdir -p /home/claude-user
if ! getent passwd $USER_ID > /dev/null; then
    adduser \
        --uid $USER_ID \
        --ingroup $GROUP_NAME \
        --home /home/claude-user \
        --shell /bin/sh \
        --no-create-home \
        --disabled-password \
        --gecos "" \
        claude-user >/dev/null 2>&1
fi

chown $USER_ID:$GROUP_ID /home/claude-user
chown -R $USER_ID:$GROUP_ID /app

# --- 7. Set HTTP_PROXY targeting the internal Privoxy ---
export HTTP_PROXY="http://127.0.0.1:8118"
export HTTPS_PROXY="http://127.0.0.1:8118"
export http_proxy="http://127.0.0.1:8118"
export https_proxy="http://127.0.0.1:8118"

# --- 8. Set working directory to /app/<host project name> if provided ---
if [ -n "$HOST_PWD" ]; then
    WORKDIR="/app/$(basename "$HOST_PWD")"
    mkdir -p "$WORKDIR"
    chown $USER_ID:$GROUP_ID "$WORKDIR"
    cd "$WORKDIR"
fi

# --- 9. Run main command (No proxychains needed for Claude anymore) ---
exec gosu claude-user "$@"
