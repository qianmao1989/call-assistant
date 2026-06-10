# install.ps1 — One-click setup for call-assistant
# Run: pwsh -File install.ps1
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Output "╔════════════════════════════════════════╗"
Write-Output "║  call-assistant v4.0 — installer       ║"
Write-Output "╚════════════════════════════════════════╝"

# ── Check PowerShell version ──
$psVer = $PSVersionTable.PSVersion
if ($psVer.Major -lt 7) {
    Write-Error "PowerShell 7+ required. Current: $psVer"
    Write-Output "Install: winget install Microsoft.PowerShell"
    exit 1
}
Write-Output "[OK] PowerShell $psVer"

# ── Check Python ──
$pyCmd = $null
try { $pyCmd = (Get-Command python -ErrorAction Stop).Source } catch {
    try { $pyCmd = (Get-Command python3 -ErrorAction Stop).Source } catch {}
}
if (-not $pyCmd) {
    Write-Error "Python 3 not found. Install from https://python.org"
    exit 1
}
Write-Output "[OK] Python: $pyCmd"

# ── Create config from example ──
$configPath = Join-Path $ScriptDir ".call-assistant.json"
$examplePath = Join-Path $ScriptDir ".call-assistant.json.example"

if (-not (Test-Path $configPath) -or $Force) {
    Copy-Item $examplePath $configPath -Force
    Write-Output "[OK] Config created: .call-assistant.json"
    Write-Output "     → Edit this file to match your setup"
} else {
    Write-Output "[OK] Config exists (use -Force to overwrite)"
}

# ── Check GATEWAY_TOKEN ──
$token = [Environment]::GetEnvironmentVariable("GATEWAY_TOKEN", "Process")
if (-not $token) { $token = [Environment]::GetEnvironmentVariable("GATEWAY_TOKEN", "Machine") }
if (-not $token) { $token = [Environment]::GetEnvironmentVariable("GATEWAY_TOKEN", "User") }

if (-not $token) {
    Write-Warning "[!!] GATEWAY_TOKEN not set"
    Write-Output ""
    Write-Output "  Set it now:"
    Write-Output '    [Environment]::SetEnvironmentVariable("GATEWAY_TOKEN", "your-token", "Machine")'
    Write-Output "  Then restart your terminal."
} else {
    Write-Output "[OK] GATEWAY_TOKEN detected"
}

# ── Done ──
Write-Output ""
Write-Output "Setup complete. Test with:"
Write-Output "  pwsh -File $ScriptDir\test\smoke_test.ps1"
