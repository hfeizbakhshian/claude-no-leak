#Requires -Version 5.1
<#
    Installs the native Claude Code release plus a wrapper with a per-binary
    network kill switch.

    An outbound Windows Firewall rule blocks the release binary from reaching
    any address; loopback is not filtered by the firewall, so the local proxy
    stays reachable and is the binary's only route out. The proxy speaks HTTP
    CONNECT, which sends the hostname to the far end, so names are resolved
    there rather than locally. Everything this script downloads takes the same
    route.

    Run it from an elevated PowerShell: creating the firewall rule needs
    administrator rights.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$proxyHost = if ($env:CLAUDE_PROXY_HOST) { $env:CLAUDE_PROXY_HOST } else { '127.0.0.1' }
$proxyPort = if ($env:CLAUDE_PROXY_PORT) { [int]$env:CLAUDE_PROXY_PORT } else { 10808 }
$proxyUrl = "http://${proxyHost}:${proxyPort}"

$wrapperDir = Join-Path $env:USERPROFILE '.claude-proxy-wrapper'
$wrapperCmd = Join-Path $wrapperDir 'claude.cmd'
$wrapperPs1 = Join-Path $wrapperDir 'claude-wrapper.ps1'
$binaryFile = Join-Path $wrapperDir 'binary.txt'
$claudeMdPath = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'
$firewallRuleName = 'Claude Code proxy kill switch'

if ($proxyHost -ne '127.0.0.1') {
    throw "This fail-closed wrapper only permits a proxy on 127.0.0.1."
}

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell: the kill switch is a firewall rule."
}

New-Item -ItemType Directory -Force -Path $wrapperDir, (Split-Path $claudeMdPath) | Out-Null

# The release binary, wherever the official installer put it. Anything inside
# the wrapper directory is skipped so the wrapper can never point at itself.
function Find-NativeClaude {
    $candidates = @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'claude\claude.exe')
    )
    $onPath = Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ($candidate.StartsWith($wrapperDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $resolved = (Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue)
        if (-not $resolved) { continue }
        # A native release is a real executable of some size, never a shim.
        if ($resolved.Length -gt 10MB) { return $resolved.FullName }
    }
    return $null
}

$realClaude = Find-NativeClaude
if (-not $realClaude) {
    try {
        $probe = New-Object Net.Sockets.TcpClient
        $probe.Connect($proxyHost, $proxyPort)
        $probe.Close()
    }
    catch {
        throw "Proxy is not listening on ${proxyHost}:${proxyPort}. Start it first: the release is downloaded through it."
    }

    Write-Output "No native Claude release found. Downloading it through $proxyUrl ..."
    $installer = Join-Path $env:TEMP 'claude-install.ps1'
    Invoke-WebRequest -Proxy $proxyUrl -Uri 'https://claude.ai/install.ps1' -OutFile $installer -TimeoutSec 60

    # The installer downloads with Invoke-RestMethod/Invoke-WebRequest, and the
    # release binary's own installer step reads the proxy variables. Setting
    # both keeps every request inside the tunnel.
    [Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy($proxyUrl, $true)
    $env:HTTP_PROXY = $proxyUrl
    $env:HTTPS_PROXY = $proxyUrl
    $env:ALL_PROXY = $proxyUrl
    try {
        & $installer stable
    }
    catch {
        throw "The native installer failed: $_`nOn HTTP 403 this proxy node's exit IP is blocked by downloads.claude.ai; switch nodes and run this script again."
    }
    finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }

    $realClaude = Find-NativeClaude
    if (-not $realClaude) {
        throw "The installer finished but no release binary was found. Set it manually in $binaryFile."
    }
}

# Kill switch. Windows does not filter loopback traffic, so blocking every
# remote address still leaves the local proxy reachable.
Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $firewallRuleName `
    -Description 'Claude Code may reach the network only through the local proxy.' `
    -Direction Outbound -Action Block -Program $realClaude -Profile Any -Enabled True | Out-Null

Set-Content -LiteralPath $binaryFile -Value $realClaude -Encoding ASCII

Set-Content -LiteralPath $wrapperPs1 -Encoding UTF8 -Value @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$proxyHost = if ($env:CLAUDE_PROXY_HOST) { $env:CLAUDE_PROXY_HOST } else { '127.0.0.1' }
$proxyPort = if ($env:CLAUDE_PROXY_PORT) { [int]$env:CLAUDE_PROXY_PORT } else { 10808 }
$expectedCountry = if ($env:CLAUDE_EXPECTED_COUNTRY) { $env:CLAUDE_EXPECTED_COUNTRY } else { 'DE' }
$timezone = if ($env:CLAUDE_TIMEZONE) { $env:CLAUDE_TIMEZONE } else { 'Europe/Berlin' }
$firewallRuleName = 'Claude Code proxy kill switch'

if ($proxyHost -ne '127.0.0.1') {
    Write-Error "This fail-closed wrapper only permits a proxy on 127.0.0.1."
    exit 1
}
$proxyUrl = "http://${proxyHost}:${proxyPort}"

$binaryFile = Join-Path $PSScriptRoot 'binary.txt'
if (-not (Test-Path -LiteralPath $binaryFile)) {
    Write-Error "Wrapper is not installed correctly: $binaryFile is missing. Run claude_native_setup.ps1."
    exit 1
}
$realClaude = (Get-Content -LiteralPath $binaryFile -Raw).Trim()
if (-not (Test-Path -LiteralPath $realClaude)) {
    Write-Error "The native Claude release is gone from $realClaude. Run claude_native_setup.ps1 again."
    exit 1
}

try {
    $probe = New-Object Net.Sockets.TcpClient
    $probe.Connect($proxyHost, $proxyPort)
    $probe.Close()
}
catch {
    Write-Error "Proxy is not listening on ${proxyHost}:${proxyPort}."
    exit 1
}

# Without the firewall rule there is nothing stopping a request from leaving
# directly, so a missing kill switch is fatal rather than a warning.
$rule = Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue
if (-not $rule -or $rule.Enabled -ne 'True') {
    Write-Error "The kill-switch firewall rule is missing or disabled. Re-run claude_native_setup.ps1 as administrator."
    exit 1
}
$blockedProgram = ($rule | Get-NetFirewallApplicationFilter).Program
if ($blockedProgram -ne $realClaude) {
    Write-Error "The kill-switch rule covers '$blockedProgram', not '$realClaude'. Re-run claude_native_setup.ps1 as administrator."
    exit 1
}

# Confirm the proxy leaves the network in the expected country before anything
# else talks to Anthropic. Fail closed: an undetermined country stops Claude.
$exitCountry = $null
try {
    $exitCountry = (Invoke-RestMethod -Proxy $proxyUrl -Uri 'https://ipinfo.io/country' -TimeoutSec 15).ToString().Trim()
}
catch { }
if ($exitCountry -notmatch '^[A-Z]{2}$') {
    try {
        $exitCountry = (Invoke-RestMethod -Proxy $proxyUrl -Uri 'https://api.country.is/' -TimeoutSec 15).country
    }
    catch { }
}
if ($exitCountry -ne $expectedCountry) {
    $seen = if ($exitCountry) { $exitCountry } else { 'unknown' }
    Write-Error "The proxy exit IP is in '$seen', expected '$expectedCountry'. Switch the proxy to a $expectedCountry endpoint, or set CLAUDE_EXPECTED_COUNTRY."
    exit 1
}

# Confirm the tunnel reaches Anthropic. Any HTTP answer proves it; only a
# transport failure means the tunnel is down.
try {
    Invoke-WebRequest -Proxy $proxyUrl -Uri 'https://api.anthropic.com/' -TimeoutSec 15 -UseBasicParsing | Out-Null
}
catch {
    # An HTTP status such as 404 arrives as a response and still proves the
    # tunnel; a transport failure carries none. Read the type rather than a
    # property, which strict mode would reject on the wrong exception.
    $answered = ($_.Exception -is [Net.WebException] -and $_.Exception.Response) -or
                $_.Exception.GetType().Name -eq 'HttpResponseException'
    if (-not $answered) {
        Write-Error "Anthropic is unreachable through the proxy."
        exit 1
    }
}

$env:TZ = $timezone
$env:HTTP_PROXY = $proxyUrl
$env:HTTPS_PROXY = $proxyUrl
$env:http_proxy = $proxyUrl
$env:https_proxy = $proxyUrl
Remove-Item Env:ALL_PROXY, Env:all_proxy, Env:NO_PROXY, Env:no_proxy -ErrorAction SilentlyContinue

& $realClaude @args
exit $LASTEXITCODE
'@

Set-Content -LiteralPath $wrapperCmd -Encoding ASCII -Value @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-wrapper.ps1" %*
exit /b %ERRORLEVEL%
'@

# The wrapper directory must come first: a later directory holding the real
# claude.exe would otherwise win the name.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$wrapperDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$wrapperDir;$userPath", 'User')
    Write-Output "Added $wrapperDir to your PATH. Open a new terminal for it to take effect."
}

if ((Test-Path -LiteralPath $claudeMdPath) -and -not (Test-Path -LiteralPath "$claudeMdPath.backup")) {
    Copy-Item -LiteralPath $claudeMdPath -Destination "$claudeMdPath.backup"
}

Set-Content -LiteralPath $claudeMdPath -Encoding UTF8 -Value @'
# Claude Code — Native Environment (Windows)

## Runtime
Claude Code runs natively on this machine. There is no container and no image:
the whole filesystem, every installed program, and the user's own environment
are directly available, and nothing written outside the project is ephemeral.

## Shell
Commands run through PowerShell, with Windows paths and Windows tooling. POSIX
utilities exist only where the user installed them (Git Bash, MSYS, WSL), so
check that one is present before depending on it.

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
- Ask before installing or removing programs, PowerShell modules, or Windows features.
- When shell commands are needed interactively (e.g. auth flows), suggest the user run `! <command>` in the prompt.
'@

Write-Output "Installed native Claude release: $realClaude"
Write-Output "Installed instructions: $claudeMdPath"
Write-Output "Installed native Claude wrapper: $wrapperCmd"
Write-Output "Kill switch: outbound firewall rule '$firewallRuleName'"
Write-Output "Proxy endpoint: ${proxyHost}:${proxyPort} (exit IP must be in DE)"
Write-Output "Run: claude"
