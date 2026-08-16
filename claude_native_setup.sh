#!/usr/bin/env bash
set -euo pipefail

# Installs a native Claude Code wrapper with a per-process network kill switch.
# Claude can only reach loopback; a local CONNECT bridge forwards HTTPS through
# the SOCKS5 endpoint, using SOCKS5 remote DNS resolution.

INSTALL_DIR="${HOME}/.local/lib/claude-proxy-wrapper"
BIN_DIR="${HOME}/.local/bin"
WRAPPER_PATH="${BIN_DIR}/claude"
BRIDGE_PATH="${INSTALL_DIR}/socks_http_bridge.py"

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

if [[ -e "$WRAPPER_PATH" && ! -e "${WRAPPER_PATH}.docker-backup" ]]; then
    cp -a "$WRAPPER_PATH" "${WRAPPER_PATH}.docker-backup"
fi

cat > "$BRIDGE_PATH" <<'PYTHON'
#!/usr/bin/env python3
import asyncio
import os
import signal
import socket
import struct

SOCKS_HOST = os.environ.get("CLAUDE_SOCKS_HOST", "127.0.0.1")
SOCKS_PORT = int(os.environ.get("CLAUDE_SOCKS_PORT", "10808"))


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(client_reader, client_writer):
    upstream_writer = None
    try:
        request = await asyncio.wait_for(client_reader.readuntil(b"\r\n\r\n"), 10)
        first_line = request.split(b"\r\n", 1)[0].decode("ascii", "strict")
        method, authority, _ = first_line.split(" ", 2)
        if method.upper() != "CONNECT":
            client_writer.write(b"HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n")
            await client_writer.drain()
            return

        host, separator, port_text = authority.rpartition(":")
        if not separator or not host or not port_text.isdigit():
            raise ValueError("invalid CONNECT authority")
        port = int(port_text)
        encoded_host = host.strip("[]").encode("idna")
        if len(encoded_host) > 255 or not 1 <= port <= 65535:
            raise ValueError("invalid destination")

        upstream_reader, upstream_writer = await asyncio.wait_for(
            asyncio.open_connection(SOCKS_HOST, SOCKS_PORT), 10
        )
        upstream_writer.write(b"\x05\x01\x00")
        await upstream_writer.drain()
        if await upstream_reader.readexactly(2) != b"\x05\x00":
            raise ConnectionError("SOCKS5 authentication negotiation failed")

        # Domain-name address type makes DNS resolution happen at the proxy.
        upstream_writer.write(
            b"\x05\x01\x00\x03" + bytes([len(encoded_host)]) + encoded_host + struct.pack("!H", port)
        )
        await upstream_writer.drain()
        response = await upstream_reader.readexactly(4)
        if response[1] != 0:
            raise ConnectionError(f"SOCKS5 connect failed with code {response[1]}")
        address_length = {1: 4, 4: 16}.get(response[3])
        if response[3] == 3:
            address_length = (await upstream_reader.readexactly(1))[0]
        if address_length is None:
            raise ConnectionError("invalid SOCKS5 response")
        await upstream_reader.readexactly(address_length + 2)

        client_writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await client_writer.drain()
        await asyncio.gather(
            pipe(client_reader, upstream_writer),
            pipe(upstream_reader, client_writer),
        )
        upstream_writer = None
    except Exception:
        try:
            client_writer.write(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
            await client_writer.drain()
        except ConnectionError:
            pass
    finally:
        client_writer.close()
        if upstream_writer is not None:
            upstream_writer.close()


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", 0, family=socket.AF_INET)
    port = server.sockets[0].getsockname()[1]
    print(port, flush=True)
    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    async with server:
        await stop.wait()


asyncio.run(main())
PYTHON
chmod 700 "$BRIDGE_PATH"

cat > "$WRAPPER_PATH" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

SOCKS_HOST="${CLAUDE_SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${CLAUDE_SOCKS_PORT:-10808}"
TIMEZONE="${CLAUDE_TIMEZONE:-Europe/Berlin}"
EXPECTED_COUNTRY="${CLAUDE_EXPECTED_COUNTRY:-DE}"
BRIDGE="${HOME}/.local/lib/claude-proxy-wrapper/socks_http_bridge.py"

if [[ "$SOCKS_HOST" != "127.0.0.1" ]]; then
    echo "Error: this fail-closed wrapper only permits a SOCKS proxy on 127.0.0.1." >&2
    exit 1
fi

for command_name in python3 systemd-run curl; do
    command -v "$command_name" >/dev/null || {
        echo "Error: required command not found: $command_name" >&2
        exit 1
    }
done

[[ -x "$BRIDGE" ]] || { echo "Error: proxy bridge not found: $BRIDGE" >&2; exit 1; }

REAL_CLAUDE="${CLAUDE_REAL_BINARY:-}"
if [[ -z "$REAL_CLAUDE" ]]; then
    while IFS= read -r version_name; do
        candidate="${HOME}/.local/share/claude/versions/${version_name}"
        # Native Claude releases are ELF executables. Never recurse into an
        # old shell/Docker wrapper accidentally stored in versions/.
        # Only the native install is used; an npm-installed copy is ignored.
        if [[ "$(od -An -tx1 -N4 "$candidate" 2>/dev/null | tr -d ' \n')" == "7f454c46" ]]; then
            REAL_CLAUDE="$candidate"
            break
        fi
    done < <(find "${HOME}/.local/share/claude/versions" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort -Vr)
fi
[[ -x "$REAL_CLAUDE" ]] || {
    echo "Error: a native Claude executable was not found." >&2
    echo "Install the official native release with:" >&2
    echo "    curl -fsSL https://claude.ai/install.sh | bash" >&2
    echo "then run claude_native_setup.sh again." >&2
    echo "You may also set CLAUDE_REAL_BINARY to its absolute path." >&2
    exit 1
}

if ! (exec 3<>"/dev/tcp/${SOCKS_HOST}/${SOCKS_PORT}") 2>/dev/null; then
    echo "Error: SOCKS5 proxy is not listening on ${SOCKS_HOST}:${SOCKS_PORT}." >&2
    exit 1
fi
exec 3>&-

PORT_FILE="$(mktemp)"
BRIDGE_PID=""
cleanup() {
    [[ -n "$BRIDGE_PID" ]] && kill "$BRIDGE_PID" 2>/dev/null || true
    rm -f "$PORT_FILE"
}
trap cleanup EXIT INT TERM HUP

CLAUDE_SOCKS_HOST="$SOCKS_HOST" CLAUDE_SOCKS_PORT="$SOCKS_PORT" \
    python3 "$BRIDGE" >"$PORT_FILE" &
BRIDGE_PID=$!

for _ in {1..50}; do
    [[ -s "$PORT_FILE" ]] && break
    kill -0 "$BRIDGE_PID" 2>/dev/null || {
        echo "Error: local proxy bridge failed to start." >&2
        exit 1
    }
    sleep 0.05
done
BRIDGE_PORT="$(<"$PORT_FILE")"
[[ "$BRIDGE_PORT" =~ ^[0-9]+$ ]] || { echo "Error: proxy bridge did not become ready." >&2; exit 1; }
PROXY_URL="http://127.0.0.1:${BRIDGE_PORT}"

# Confirm the proxy leaves the network in the expected country before anything
# else talks to Anthropic. Fail closed: an undetermined country stops Claude.
# curl resolves every hostname through SOCKS5 (socks5h), so no check leaks DNS.
exit_country="$(curl --silent --max-time 15 \
    --socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" https://ipinfo.io/country | tr -d '[:space:]')" || true
if [[ ! "$exit_country" =~ ^[A-Z]{2}$ ]]; then
    exit_country="$(curl --silent --max-time 15 \
        --socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" https://api.country.is/ |
        sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([A-Z]\{2\}\)".*/\1/p')" || true
fi
if [[ "$exit_country" != "$EXPECTED_COUNTRY" ]]; then
    echo "Error: the proxy exit IP is in '${exit_country:-unknown}', expected '${EXPECTED_COUNTRY}'." >&2
    echo "Switch the SOCKS5 proxy to a ${EXPECTED_COUNTRY} endpoint, or set CLAUDE_EXPECTED_COUNTRY." >&2
    exit 1
fi

# Confirm the tunnel reaches Anthropic before Claude gets a chance to start.
curl --silent --show-error --max-time 15 \
    --socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" https://api.anthropic.com/ >/dev/null || {
    echo "Error: Anthropic is unreachable through the SOCKS5 proxy." >&2
    exit 1
}

export TZ="$TIMEZONE"
export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
unset ALL_PROXY all_proxy NO_PROXY no_proxy

# The Claude process and every child it creates may connect only to loopback.
# External connections therefore have exactly one route: bridge -> SOCKS5.
set +e
systemd-run --user --scope --quiet --collect \
    -p IPAddressDeny=any \
    -p IPAddressAllow=localhost \
    "$REAL_CLAUDE" "$@"
status=$?
set -e
exit "$status"
WRAPPER
chmod 700 "$WRAPPER_PATH"

echo "Installed native Claude wrapper: $WRAPPER_PATH"
echo "Saved previous wrapper as: ${WRAPPER_PATH}.docker-backup"
echo "SOCKS5 endpoint: 127.0.0.1:10808 (exit IP must be in DE)"
echo "Run: claude"
