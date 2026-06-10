# call_assistant.ps1 v4.1 — CC ↔ AI Assistant Reliable Messaging
# GitHub: https://github.com/qianmao1989/call-assistant
# Requires: PowerShell 7+, Python 3, OpenClaw gateway running locally
#
# Usage:
#   .\call_assistant.ps1 "your message"
#   .\call_assistant.ps1 "long task" -Timeout 180

param(
    [Parameter(Mandatory=$true)]
    [string]$Message,
    [int]$Timeout = 120
)

$ErrorActionPreference = "Continue"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$GATEWAY = "http://localhost:18789"
$PIPE_SERVER = Join-Path $SCRIPT_DIR "shared/cc_push_server.py"
$PIPE_NAME = "\\.\pipe\openclaw-cc-push"
$OUTBOX = Join-Path $SCRIPT_DIR "shared/cc_outbox.md"

# ── Token: auto-read from openclaw.json ──
$TOKEN = $null
try {
    $oc = Get-Content "$env:USERPROFILE\.openclaw\openclaw.json" -Raw -ErrorAction Stop | ConvertFrom-Json
    $TOKEN = $oc.gateway.auth.token
} catch {}
if (-not $TOKEN) {
    Write-Output "[CC] Cannot read gateway token from openclaw.json"
    exit 1
}

# ── Prefix ──
$msg = $Message
if ($msg -notmatch '^\[CC\]') { $msg = "[CC] $msg" }

# ── Step 1: Pipe server check (CreateFile — not Get-Process CommandLine) ──
$pipeOk = $false
try {
    $test = python -c @"
import win32pipe, win32file
try:
    h = win32file.CreateFile(r'$PIPE_NAME', win32file.GENERIC_READ, 0, None, win32file.OPEN_EXISTING, 0, None)
    h.Close()
    print('ok')
except: print('dead')
"@ 2>$null
    $pipeOk = ($test -eq 'ok')
} catch {}

if (-not $pipeOk) {
    Write-Warning "Pipe dead, restarting..."
    $null = Start-Process python -ArgumentList $PIPE_SERVER -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2

    # Verify restart
    try {
        $test = python -c @"
import win32pipe, win32file
try:
    h = win32file.CreateFile(r'$PIPE_NAME', win32file.GENERIC_READ, 0, None, win32file.OPEN_EXISTING, 0, None)
    h.Close()
    print('ok')
except: print('dead')
"@ 2>$null
        $pipeOk = ($test -eq 'ok')
    } catch {}

    if (-not $pipeOk) {
        Write-Output "[CC] Pipe unreachable after restart — manual intervention needed"
        exit 1
    }
    Write-Output "[CC] Pipe server restarted OK"
}

# ── Step 2: Send (retry once) ──
$body = @{model='openclaw/main'; messages=@(@{role='user'; content=$msg}); stream=$true} | ConvertTo-Json -Depth 4 -Compress

$reply = ""
$ok = $false

for ($i = 1; $i -le 2; $i++) {
    try {
        $wr = Invoke-WebRequest -Uri "$GATEWAY/v1/chat/completions" -Method Post -Headers @{Authorization="Bearer $TOKEN"} -ContentType "application/json" -Body $body -TimeoutSec $Timeout -ErrorAction Stop
        foreach ($line in ($wr.Content -split "`n")) {
            if ($line -notmatch '^data: ') { continue }
            $data = $line.Substring(6)
            if ($data -eq '[DONE]') { break }
            try {
                $obj = $data | ConvertFrom-Json
                $dc = $obj.choices[0].delta
                if ($dc.content) { $reply += $dc.content }
            } catch {}
        }
        if ($reply.Length -gt 0) { $ok = $true; break }
        if ($i -lt 2) { Write-Warning "Attempt $i empty, retrying..." ; Start-Sleep -Seconds 2 }
    } catch {
        if ($i -lt 2) { Write-Warning "Attempt $i failed, retrying..." ; Start-Sleep -Seconds 2 }
    }
}

# ── Step 3: Output / Fallback ──
if ($ok) {
    Write-Output $reply
} else {
    Write-Warning "Gateway failed. Falling back to cc_outbox.md"
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $OUTBOX -Value "### [$ts] [CC]$([Environment]::NewLine)$Message$([Environment]::NewLine)" -Encoding UTF8
    Write-Output "FALLBACK: cc_outbox.md"
}