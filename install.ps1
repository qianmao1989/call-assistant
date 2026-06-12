# install.ps1 — One-click setup for call-assistant
# Run: pwsh -File install.ps1
param(
    [switch]$Force,
    [switch]$NoPython
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Output "╔════════════════════════════════════════╗"
Write-Output "║  call-assistant v4.1 — installer       ║"
Write-Output "╚════════════════════════════════════════╝"

# ── Check PowerShell version ──
$psVer = $PSVersionTable.PSVersion
if ($psVer.Major -lt 7) {
    Write-Error "PowerShell 7+ required. Current: $psVer"
    Write-Output "Install: winget install Microsoft.PowerShell"
    exit 1
}
Write-Output "[OK] PowerShell $psVer"

# ── Check Python (optional) ──
$pyCmd = $null
$hasPython = $false
if (-not $NoPython) {
    try { $pyCmd = (Get-Command python -ErrorAction Stop).Source } catch {
        try { $pyCmd = (Get-Command python3 -ErrorAction Stop).Source } catch {}
    }
    if ($pyCmd) {
        $hasPython = $true
        Write-Output "[OK] Python: $pyCmd"
    } else {
        Write-Warning "[!!] Python 3 not found — pipe server disabled (outbox-only mode)"
        Write-Output "     Install from https://python.org for real-time pipe replies"
        Write-Output "     Or use -NoPython to skip this warning"
    }
} else {
    Write-Output "[SKIP] Python check skipped (-NoPython) — outbox-only mode"
}

# ── Create config from example ──
$configPath = Join-Path $ScriptDir ".call-assistant.json"
$examplePath = Join-Path $ScriptDir ".call-assistant.json.example"

if (-not (Test-Path $configPath) -or $Force) {
    Copy-Item $examplePath $configPath -Force
    Write-Output "[OK] Config created: .call-assistant.json"
    Write-Output "     → Edit token if not using OpenClaw"
} else {
    Write-Output "[OK] Config exists (use -Force to overwrite)"
}

# ── Check token sources ──
$tokenFound = $false

# 1) .call-assistant.json
if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($cfg.gateway.token) { $tokenFound = $true; Write-Output "[OK] Token: .call-assistant.json" }
    } catch {}
}

# 2) openclaw.json auto-detect
if (-not $tokenFound) {
    try {
        $oc = Get-Content "$env:USERPROFILE\.openclaw\openclaw.json" -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($oc.gateway.auth.token) { $tokenFound = $true; Write-Output "[OK] Token: openclaw.json (auto-detected)" }
    } catch {}
}

# 3) Environment variable
if (-not $tokenFound) {
    $tok = [Environment]::GetEnvironmentVariable("GATEWAY_TOKEN", "Process")
    if (-not $tok) { $tok = [Environment]::GetEnvironmentVariable("GATEWAY_TOKEN", "Machine") }
    if (-not $tok) { $tok = [Environment]::GetEnvironmentVariable("GATEWAY_TOKEN", "User") }
    if ($tok) { $tokenFound = $true; Write-Output "[OK] Token: GATEWAY_TOKEN env" }
}

if (-not $tokenFound) {
    Write-Warning "[!!] No token detected"
    Write-Output "  Token auto-detected from openclaw.json (OpenClaw users: no action needed)"
    Write-Output "  Others: edit .call-assistant.json and set gateway.token or gateway.token_file"
}

# ── Done ──
Write-Output ""
Write-Output "Setup complete."
if (-not $hasPython -and -not $NoPython) {
    Write-Output "  Note: Python is optional. Without it, replies arrive via outbox (not real-time pipe)."
}
Write-Output "  Test: pwsh -File $ScriptDir\test\smoke_test.ps1"
