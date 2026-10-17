#!/usr/bin/env bash
set -euo pipefail

# Installs the native Claude Code release plus a wrapper with a per-process
# network kill switch. Claude can only reach loopback; a local CONNECT bridge
# forwards HTTPS through the SOCKS5 endpoint, using SOCKS5 remote DNS
# resolution. Everything this script downloads goes through that same proxy.
#
# The kill switch is a Seatbelt profile applied with sandbox-exec. Unlike the
# Linux filter it needs no root: any process may sandbox itself, and every
# child inherits the sandbox and cannot leave it. The wrapper proves the
# sandbox is live before it hands over.
#
# Written for the stock /bin/bash 3.2 and BSD userland that macOS ships.

SOCKS_HOST="${CLAUDE_SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${CLAUDE_SOCKS_PORT:-10808}"
PROXY_URL="socks5h://${SOCKS_HOST}:${SOCKS_PORT}"
RELEASE_CHANNEL="${CLAUDE_RELEASE_CHANNEL:-latest}"

INSTALL_DIR="${HOME}/.local/lib/claude-proxy-wrapper"
BIN_DIR="${HOME}/.local/bin"
VERSIONS_DIR="${HOME}/.local/share/claude/versions"
WRAPPER_PATH="${BIN_DIR}/claude"
BRIDGE_PATH="${INSTALL_DIR}/socks_http_bridge.py"
PROFILE_PATH="${INSTALL_DIR}/claude-jail.sb"
CLAUDE_MD_PATH="${HOME}/.claude/CLAUDE.md"

[[ "$(uname -s)" == "Darwin" ]] || {
    echo "Error: this script is for macOS. Use linux-native/ or windows-native/ instead." >&2
    exit 1
}

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "${HOME}/.claude"

# Highest native release already installed, if any. Native builds are Mach-O
# executables (thin 64-bit or universal), so an old shell wrapper left in
# versions/ is ignored. BSD sort has no -V, so versions sort field by field.
find_native_claude() {
    local version_name candidate magic
    while IFS= read -r version_name; do
        candidate="${VERSIONS_DIR}/${version_name}"
        [[ -f "$candidate" ]] || continue
        magic="$(od -An -tx1 -N4 "$candidate" 2>/dev/null | tr -d ' \n')"
        if [[ "$magic" == "cffaedfe" || "$magic" == "cafebabe" ]]; then
            printf '%s' "$candidate"
            return
        fi
    done < <(ls -1 "$VERSIONS_DIR" 2>/dev/null | sort -t. -k1,1nr -k2,2nr -k3,3nr)
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

    echo "No native Claude release found. Downloading it through ${PROXY_URL} ..."
    installer="$(mktemp)"
    curl --fail --silent --show-error --location --max-time 60 \
        --proxy "$PROXY_URL" -o "$installer" https://claude.ai/install.sh || {
        echo "Error: could not download the official installer through the proxy." >&2
        rm -f "$installer"
        exit 1
    }
    ALL_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" \
        bash "$installer" "$RELEASE_CHANNEL" || {
        echo "Error: the native installer failed." >&2
        echo "On HTTP 403 the exit IP of this proxy node is blocked by downloads.claude.ai;" >&2
        echo "switch to another node and run this script again." >&2
        rm -f "$installer"
        exit 1
    }
    rm -f "$installer"
fi

# --- network jail ------------------------------------------------------------
# Seatbelt applies the last rule that matches, so the order below matters.
#
# Every IP destination is refused except loopback, which leaves bridge ->
# SOCKS5 as the single route out. Unix sockets stay open so local tools (ssh
# agent, git credential helpers) keep working - with one exception: name
# lookups on macOS are answered by mDNSResponder over its socket, and with
# that closed a child that ignores the proxy variables cannot resolve a name,
# so no lookup reaches the local network. This is the counterpart of leaving
# 127.0.0.53 out of the Linux allow list.
#
# What Seatbelt cannot see is work handed to a system daemon over XPC: a tool
# that asks nsurlsessiond or softwareupdated to fetch something has that
# request made outside the sandbox. Claude itself and ordinary command-line
# tools open their own sockets and stay covered.
cat > "$PROFILE_PATH" <<'PROFILE'
(version 1)
(allow default)
(deny network-outbound (remote ip "*:*"))
(allow network-outbound (remote ip "localhost:*"))
(deny network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
PROFILE
chmod 600 "$PROFILE_PATH"

# Only a real previous wrapper is worth keeping. The native installer leaves a
# symlink into versions/ here, which must be removed rather than backed up:
# writing through it would overwrite the release binary it points at.
if [[ -f "$WRAPPER_PATH" && ! -L "$WRAPPER_PATH" && ! -e "${WRAPPER_PATH}.backup" ]]; then
    cp -a "$WRAPPER_PATH" "${WRAPPER_PATH}.backup"
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
PROFILE="${HOME}/.local/lib/claude-proxy-wrapper/claude-jail.sb"
VERSIONS_DIR="${HOME}/.local/share/claude/versions"

if [[ "$SOCKS_HOST" != "127.0.0.1" ]]; then
    echo "Error: this fail-closed wrapper only permits a SOCKS proxy on 127.0.0.1." >&2
    exit 1
fi

for command_name in python3 sandbox-exec curl; do
    command -v "$command_name" >/dev/null || {
        echo "Error: required command not found: $command_name" >&2
        exit 1
    }
done

[[ -x "$BRIDGE" ]] || { echo "Error: proxy bridge not found: $BRIDGE" >&2; exit 1; }
[[ -f "$PROFILE" ]] || {
    echo "Error: sandbox profile not found: $PROFILE. Run mac-native/claude_native_setup.sh again." >&2
    exit 1
}

REAL_CLAUDE="${CLAUDE_REAL_BINARY:-}"
if [[ -z "$REAL_CLAUDE" ]]; then
    while IFS= read -r version_name; do
        candidate="${VERSIONS_DIR}/${version_name}"
        [[ -f "$candidate" ]] || continue
        # Native Claude releases are Mach-O executables. Never recurse into an
        # old shell wrapper accidentally stored in versions/.
        # Only the native install is used; an npm-installed copy is ignored.
        magic="$(od -An -tx1 -N4 "$candidate" 2>/dev/null | tr -d ' \n')"
        if [[ "$magic" == "cffaedfe" || "$magic" == "cafebabe" ]]; then
            REAL_CLAUDE="$candidate"
            break
        fi
    done < <(ls -1 "$VERSIONS_DIR" 2>/dev/null | sort -t. -k1,1nr -k2,2nr -k3,3nr)
fi
[[ -x "$REAL_CLAUDE" ]] || {
    echo "Error: a native Claude executable was not found." >&2
    echo "Run mac-native/claude_native_setup.sh, which installs it through the proxy." >&2
    echo "You may also set CLAUDE_REAL_BINARY to its absolute path." >&2
    exit 1
}

if ! (exec 3<>"/dev/tcp/${SOCKS_HOST}/${SOCKS_PORT}") 2>/dev/null; then
    echo "Error: SOCKS5 proxy is not listening on ${SOCKS_HOST}:${SOCKS_PORT}." >&2
    exit 1
fi

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

# Never take the sandbox on trust. The probe runs inside it and must see
# exactly this: loopback reachable, a UDP write to the documentation range
# refused, and a name lookup failing. Only a clean exit counts, so a profile
# sandbox-exec rejected, or a sandbox that never applied, stops Claude as
# surely as a leak does. In the one case a packet is emitted at all, its
# address dies at the first hop.
probe_status=0
sandbox-exec -f "$PROFILE" /bin/bash -c '
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null || exit 2
    (exec 3<>/dev/udp/198.51.100.1/9 && printf x >&3) 2>/dev/null && exit 3
    python3 -c "import socket; socket.getaddrinfo(\"api.anthropic.com\", 443)" 2>/dev/null && exit 4
    exit 0
' probe "$BRIDGE_PORT" 2>/dev/null || probe_status=$?
case "$probe_status" in
    0) ;;
    3|4)
        echo "Error: the network jail is not being enforced - refusing to start Claude." >&2
        echo "Every request would leave this machine directly, with your real address." >&2
        exit 1
        ;;
    *)
        echo "Error: the network jail could not be set up (probe exit ${probe_status}) - refusing to start Claude." >&2
        echo "Check $PROFILE, or run mac-native/claude_native_setup.sh again." >&2
        exit 1
        ;;
esac

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
sandbox-exec -f "$PROFILE" "$REAL_CLAUDE" "$@"
status=$?
set -e
exit "$status"
WRAPPER
chmod 700 "$WRAPPER_PATH"

if [[ -e "$CLAUDE_MD_PATH" && ! -e "${CLAUDE_MD_PATH}.backup" ]]; then
    cp -a "$CLAUDE_MD_PATH" "${CLAUDE_MD_PATH}.backup"
fi

cat > "$CLAUDE_MD_PATH" <<'CLAUDE_MD'
# Claude Code — Native Environment (macOS)

## Runtime
Claude Code runs natively on this machine. There is no container and no image:
the whole filesystem, every installed tool, and the user's own environment are
directly available, and nothing written outside the project is ephemeral.

## Shell
Commands run with the BSD userland macOS ships, not GNU coreutils: flags such
as `sed -i`, `find -printf`, `sort -V` or `date -d` behave differently or do not
exist. GNU tools are present only where the user installed them (Homebrew's
`gsed`, `gfind`, ...), so check before depending on them.

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
- Ask before installing or removing system packages or Homebrew formulae.
- When shell commands are needed interactively (e.g. auth flows), suggest the user run `! <command>` in the prompt.
CLAUDE_MD

echo "Installed native Claude release: $(find_native_claude)"
echo "Installed instructions: $CLAUDE_MD_PATH"
echo "Installed native Claude wrapper: $WRAPPER_PATH"
echo "Kill switch: Seatbelt profile $PROFILE_PATH"
[[ -e "${WRAPPER_PATH}.backup" ]] &&
    echo "Saved previous wrapper as: ${WRAPPER_PATH}.backup"
echo "SOCKS5 endpoint: ${SOCKS_HOST}:${SOCKS_PORT} (exit IP must be in ${CLAUDE_EXPECTED_COUNTRY:-DE})"
echo "Run: claude"
