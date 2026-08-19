#!/usr/bin/env bash
set -euo pipefail

# Installs the native Claude Code release plus a wrapper with a per-process
# network kill switch. Claude can only reach loopback; a local CONNECT bridge
# forwards HTTPS through the SOCKS5 endpoint, using SOCKS5 remote DNS
# resolution. Everything this script downloads goes through that same proxy.
#
# Launching Claude needs sudo: the kernel only applies the IP filter when the
# system manager installs it, and the wrapper proves the filter is live before
# it hands over.

SOCKS_HOST="${CLAUDE_SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${CLAUDE_SOCKS_PORT:-10808}"
PROXY_URL="socks5h://${SOCKS_HOST}:${SOCKS_PORT}"

INSTALL_DIR="${HOME}/.local/lib/claude-proxy-wrapper"
BIN_DIR="${HOME}/.local/bin"
VERSIONS_DIR="${HOME}/.local/share/claude/versions"
WRAPPER_PATH="${BIN_DIR}/claude"
BRIDGE_PATH="${INSTALL_DIR}/socks_http_bridge.py"
CLAUDE_MD_PATH="${HOME}/.claude/CLAUDE.md"

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "${HOME}/.claude"

# Highest native release already installed, if any. Native builds are ELF
# executables, so an old shell/Docker wrapper left in versions/ is ignored.
find_native_claude() {
    local version_name candidate
    while IFS= read -r version_name; do
        candidate="${VERSIONS_DIR}/${version_name}"
        if [[ "$(od -An -tx1 -N4 "$candidate" 2>/dev/null | tr -d ' \n')" == "7f454c46" ]]; then
            printf '%s' "$candidate"
            return
        fi
    done < <(find "$VERSIONS_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort -Vr)
}

# Install the native release through the proxy. The official installer shells
# out to curl, which honours these proxy variables, so no request bypasses the
# tunnel and no hostname is resolved locally.
if [[ -z "$(find_native_claude)" ]]; then
    if ! (exec 3<>"/dev/tcp/${SOCKS_HOST}/${SOCKS_PORT}") 2>/dev/null; then
        echo "Error: SOCKS5 proxy is not listening on ${SOCKS_HOST}:${SOCKS_PORT}." >&2
        echo "Start the proxy first: the native release is downloaded through it." >&2
        exit 1
    fi
    exec 3>&-

    echo "No native Claude release found. Downloading it through ${PROXY_URL} ..."
    installer="$(mktemp)"
    curl --fail --silent --show-error --location --max-time 60 \
        --proxy "$PROXY_URL" -o "$installer" https://claude.ai/install.sh || {
        echo "Error: could not download the official installer through the proxy." >&2
        rm -f "$installer"
        exit 1
    }
    ALL_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" \
        bash "$installer" stable || {
        echo "Error: the native installer failed." >&2
        echo "On HTTP 403 the exit IP of this proxy node is blocked by downloads.claude.ai;" >&2
        echo "switch to another node and run this script again." >&2
        rm -f "$installer"
        exit 1
    }
    rm -f "$installer"
fi

# Only a real previous wrapper is worth keeping. The native installer leaves a
# symlink into versions/ here, which must be removed rather than backed up:
# writing through it would overwrite the release binary it points at.
if [[ -f "$WRAPPER_PATH" && ! -L "$WRAPPER_PATH" && ! -e "${WRAPPER_PATH}.docker-backup" ]]; then
    cp -a "$WRAPPER_PATH" "${WRAPPER_PATH}.docker-backup"
fi
rm -f "$WRAPPER_PATH"

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
RECHECK_SECONDS="${CLAUDE_COUNTRY_RECHECK_SECONDS:-120}"
BRIDGE="${HOME}/.local/lib/claude-proxy-wrapper/socks_http_bridge.py"

if [[ "$SOCKS_HOST" != "127.0.0.1" ]]; then
    echo "Error: this fail-closed wrapper only permits a SOCKS proxy on 127.0.0.1." >&2
    exit 1
fi

for command_name in python3 systemd-run curl sudo; do
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
    echo "Run linux-native/claude_native_setup.sh, which installs it through the proxy." >&2
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
WATCHDOG_PID=""
cleanup() {
    [[ -n "$WATCHDOG_PID" ]] && kill "$WATCHDOG_PID" 2>/dev/null || true
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

# Where the proxy leaves the network. Both lookups go through SOCKS5 with
# remote name resolution, so asking the question cannot itself leak a DNS
# query or expose the real address.
proxy_exit_country() {
    local country
    country="$(curl --silent --max-time 15 \
        --socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" https://ipinfo.io/country | tr -d '[:space:]')" || true
    if [[ ! "$country" =~ ^[A-Z]{2}$ ]]; then
        country="$(curl --silent --max-time 15 \
            --socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" https://api.country.is/ |
            sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([A-Z]\{2\}\)".*/\1/p')" || true
    fi
    printf '%s' "$country"
}

# Fail closed before anything else talks to Anthropic: an undetermined country
# stops Claude just as a wrong one does.
exit_country="$(proxy_exit_country)"
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

# The jail. Claude and every child it spawns may address only the two loopback
# hosts, so the single route out is bridge -> SOCKS5.
#
# It runs under the system manager on purpose: IP filtering is a BPF program
# that only the system manager can install, and a "--user" scope accepts
# IPAddressDeny= and then silently enforces nothing. sudo buys enforcement,
# --uid/--gid hand the process straight back to the caller.
#
# 127.0.0.53 is deliberately outside the allow list: with the stub resolver
# unreachable, a child that ignores the proxy variables cannot resolve a name
# either, so no lookup reaches the local network.
jail=(sudo systemd-run --scope --quiet --collect
      -p IPAddressDeny=any
      -p IPAddressAllow=127.0.0.1/32
      -p IPAddressAllow=::1/128
      --uid="$(id -u)" --gid="$(id -g)")

# sudo clears the environment and "sudo -E" needs a sudoers tag that may not be
# granted, so hand every variable over explicitly. The proxy variables and TZ
# were exported above, so they travel with the rest.
while IFS= read -r -d '' variable; do
    jail+=(--setenv="$variable")
done < <(env -0)

# Never take the filter on trust: a scope that quietly ignored IPAddressDeny
# would send every request straight out. A UDP write answers immediately -
# refused outright while the filter is live, accepted the moment it is not -
# and the address comes from the documentation range, so in the one case a
# packet is emitted at all it dies at the first hop.
if timeout 5 "${jail[@]}" bash -c 'exec 3<>/dev/udp/198.51.100.1/9 && printf x >&3' 2>/dev/null; then
    echo "Error: the network jail is not being enforced - refusing to start Claude." >&2
    echo "Every request would leave this machine directly, with your real address." >&2
    exit 1
fi

# A check at startup only proves where the first packet went; exit nodes rotate
# under a live session. Keep asking, and cut the tunnel the moment the exit
# leaves the expected country. A lookup that fails to answer is not a move, so
# only a valid and different country ends the session.
(
    while sleep "$RECHECK_SECONDS"; do
        current_country="$(proxy_exit_country)"
        if [[ "$current_country" =~ ^[A-Z]{2}$ && "$current_country" != "$EXPECTED_COUNTRY" ]]; then
            echo "Error: the proxy exit IP moved to '${current_country}'. Cutting the tunnel." >&2
            kill "$BRIDGE_PID" 2>/dev/null || true
            exit 0
        fi
    done
) &
WATCHDOG_PID=$!

set +e
"${jail[@]}" "$REAL_CLAUDE" "$@"
status=$?
set -e
exit "$status"
WRAPPER
chmod 700 "$WRAPPER_PATH"

if [[ -e "$CLAUDE_MD_PATH" && ! -e "${CLAUDE_MD_PATH}.backup" ]]; then
    cp -a "$CLAUDE_MD_PATH" "${CLAUDE_MD_PATH}.backup"
fi

cat > "$CLAUDE_MD_PATH" <<'CLAUDE_MD'
# Claude Code — Native Environment (Linux)

## Runtime
Claude Code runs natively on this machine. There is no container and no image:
the whole filesystem, every installed tool, and the user's own environment are
directly available, and nothing written outside the project is ephemeral.

## File and code edits
- Always prefer editing existing files over creating new ones.
- Never create `*.md` documentation files unless explicitly requested.
- Do not add error handling, fallbacks, or validation for scenarios that can't happen.

## Security
- Never introduce command injection, XSS, SQL injection, or other OWASP Top 10 vulnerabilities.
- Only validate at system boundaries (user input, external APIs).

## Git
- Only commit when the user explicitly asks.
- Never include the `Claude-Session:` link in commit messages.
- Never skip hooks (`--no-verify`) or force-push unless explicitly instructed.
- Prefer new commits over amending existing ones.

## Risky actions
- Ask before deleting files, force-pushing, resetting hard, or affecting shared state.
- Match scope of actions to what was actually requested.

## Environment constraints
- Ask before installing or removing system packages.
- When shell commands are needed interactively (e.g. auth flows), suggest the user run `! <command>` in the prompt.
CLAUDE_MD

echo "Installed native Claude release: $(find_native_claude)"
echo "Installed instructions: $CLAUDE_MD_PATH"
echo "Installed native Claude wrapper: $WRAPPER_PATH"
[[ -e "${WRAPPER_PATH}.docker-backup" ]] &&
    echo "Saved previous wrapper as: ${WRAPPER_PATH}.docker-backup"
echo "SOCKS5 endpoint: 127.0.0.1:10808 (exit IP must be in DE)"
echo "Run: claude"
