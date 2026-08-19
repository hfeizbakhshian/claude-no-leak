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
# Privoxy lives on 127.0.0.1. The rest of loopback carries Docker's embedded
# resolver on 127.0.0.11, which forwards queries out of the container in the
# clear, so it is rejected along with the port 53 rules that used to let any
# lookup leave. Nothing here needs local DNS: privoxy reaches the proxy by
# address and resolves names at the far end.
iptables -A OUTPUT -o lo -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -o lo -j REJECT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -d $PROXY_IP -p tcp --dport $PROXY_PORT -j ACCEPT
iptables -P OUTPUT DROP

# Filtering v4 alone is worth nothing on a host that hands the container v6.
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F OUTPUT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -d ::1 -j ACCEPT 2>/dev/null || true
    ip6tables -P OUTPUT DROP 2>/dev/null || true
fi

# --- 3. Create proxychains config file (for curl check) ---
{
  echo "strict_chain"
  echo "proxy_dns"
  echo "[ProxyList]"
  echo "socks5  $PROXY_IP $PROXY_PORT"
} > /etc/proxychains.conf

# --- 4. Verify where the proxy leaves the network ---
# Over HTTPS: on plain HTTP anything along the path could answer with the
# expected country and walk straight through this check.
proxy_exit_country() {
    country=$(proxychains -q -f /etc/proxychains.conf curl -s -A "$USER_AGENT" \
        --connect-timeout 10 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
    if ! echo "$country" | grep -qE '^[A-Z]{2}$'; then
        country=$(proxychains -q -f /etc/proxychains.conf curl -s -A "$USER_AGENT" \
            --connect-timeout 10 https://api.country.is/ 2>/dev/null |
            sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([A-Z]\{2\}\)".*/\1/p')
    fi
    printf '%s' "$country"
}

COUNTRY_CODE=$(proxy_exit_country)
if [ "$COUNTRY_CODE" != "$EXPECTED_COUNTRY" ]; then
    echo "❌ Error: the proxy exit IP is in '${COUNTRY_CODE:-unknown}', expected '$EXPECTED_COUNTRY'."
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

# --- 8. Set working directory to the host project path (mounted 1:1) ---
if [ -n "$HOST_PWD" ]; then
    cd "$HOST_PWD"
    # Project venvs contain absolute paths; the 1:1 mount keeps them valid.
    # If one exists, put it on PATH so python/pip resolve to it automatically.
    if [ -x "$HOST_PWD/.venv/bin/python" ]; then
        export VIRTUAL_ENV="$HOST_PWD/.venv"
        export PATH="$VIRTUAL_ENV/bin:$PATH"
    fi
fi

# --- 9. Keep watching where the exit lands ---
# A check at startup only proves where the first packet went; nodes rotate
# under a live session. A lookup that fails to answer is not treated as a move,
# only a valid and different country is - and then everything is cut, including
# the connections already open.
(
    while sleep "${COUNTRY_RECHECK_SECONDS:-120}"; do
        CURRENT_COUNTRY=$(proxy_exit_country)
        if echo "$CURRENT_COUNTRY" | grep -qE '^[A-Z]{2}$' && [ "$CURRENT_COUNTRY" != "$EXPECTED_COUNTRY" ]; then
            echo "❌ Error: the proxy exit IP moved to '$CURRENT_COUNTRY'. Cutting the tunnel." >&2
            iptables -I OUTPUT 1 -j REJECT
            kill 1 2>/dev/null
            exit 0
        fi
    done
) &

# --- 10. Run main command (No proxychains needed for Claude anymore) ---
exec gosu claude-user "$@"
