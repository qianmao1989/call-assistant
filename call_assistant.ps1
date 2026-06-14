# call_assistant.ps1 v5.0.0 — CC → 小助理 Doorbell Pattern
# GitHub: https://github.com/qianmao1989/call-assistant
# Requires: PowerShell 7+ (Python 3 optional — pipe server only)
#
# Doorbell Pattern:
#   Outbox (Set-Content) = PRIMARY message body
#   Gateway (stream:true) = DOORBELL only — "去看 cc_outbox.md"
#   Pipe (cc_push_server.py) = RECEIVE channel for 小助理's replies
#
# Usage:
#   .\call_assistant.ps1 "your message in English"       # write outbox + ring doorbell
#   .\call_assistant.ps1 -Init                           # pipe server init only (once per session)
#   .\call_assistant.ps1 "msg" -Timeout 60               # custom doorbell timeout
#   .\call_assistant.ps1 "msg" -Token "sk-..."           # explicit token
#   .\call_assistant.ps1 "msg" -Config "./custom.json"   # custom config

param(
    [Parameter(Mandatory=$false)]
    [string]$Message = "",

    [int]$Timeout = 0,

    [string]$Config = "",

    [string]$Token = "",

    [switch]$Init
)

$ErrorActionPreference = "Continue"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# ═══════════════════════════════════════════
# Step 0: Load config (all fields have built-in defaults)
# ═══════════════════════════════════════════

$defaultConfig = @{
    gateway = @{
        url = "http://localhost:18789"
        token_env = "GATEWAY_TOKEN"
        token = ""
        token_file = ""
        model = "openclaw/main"
        health_endpoint = "/health"
        chat_endpoint = "/v1/chat/completions"
    }
    pipe = @{
        enabled = $true
        server_script = "./shared/cc_push_server.py"
        pipe_name = "openclaw-cc-push"
        python = "python"
        startup_wait_sec = 3
    }
    fallback = @{
        outbox = "./shared/cc_outbox.md"
        timeout_sec = 60
        max_retries = 1
        retry_delay_sec = 2
    }
}

$cfg = $defaultConfig

if ($Config) {
    $configPath = $Config
} else {
    $configPath = Join-Path $SCRIPT_DIR ".call-assistant.json"
}

if (Test-Path $configPath) {
    try {
        $userCfg = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($section in @("gateway", "pipe", "fallback")) {
            if ($userCfg.$section) {
                foreach ($key in $userCfg.$section.PSObject.Properties.Name) {
                    if ($key.StartsWith('_')) { continue }    # skip _comment and metadata keys
                    $cfg.$section.$key = $userCfg.$section.$key
                }
            }
        }
    } catch {
        Write-Error "[call-assistant] Failed to parse config: $configPath — $($_.Exception.Message)"
        exit 1
    }
}

if ($Timeout -eq 0) { $Timeout = $cfg.fallback.timeout_sec }

# ═══════════════════════════════════════════
# Init-only mode: start pipe server, verify, exit
# ═══════════════════════════════════════════

if ($Init) {
    Write-Output "[CC] Pipe init mode — verifying pipe server..."

    if (-not $cfg.pipe.enabled) {
        Write-Output "[CC] Pipe disabled by config — nothing to init"
        exit 0
    }

    # Check pipe with CreateFile
    $pipeOk = $false
    try {
        $test = & $cfg.pipe.python -c @"
import win32pipe, win32file
try:
    h = win32file.CreateFile(r'$PIPE_NAME', win32file.GENERIC_READ, 0, None, win32file.OPEN_EXISTING, 0, None)
    h.Close()
    print('ok')
except: print('dead')
"@ 2>$null
        $pipeOk = ($test -eq 'ok')
    } catch {
        Write-Warning "[CC] Python '$($cfg.pipe.python)' not found"
    }

    if ($pipeOk) {
        Write-Output "[CC] Pipe server already running ✓"
        exit 0
    }

    # Try to start
    Write-Output "[CC] Pipe server not running, starting..."
    try {
        if (Test-Path $pipeScript) {
            $proc = Start-Process $cfg.pipe.python -ArgumentList $pipeScript -WindowStyle Hidden -PassThru
            Start-Sleep -Seconds $cfg.pipe.startup_wait_sec

            # Verify restart
            try {
                $test = & $cfg.pipe.python -c @"
import win32pipe, win32file
try:
    h = win32file.CreateFile(r'$PIPE_NAME', win32file.GENERIC_READ, 0, None, win32file.OPEN_EXISTING, 0, None)
    h.Close()
    print('ok')
except: print('dead')
"@ 2>$null
                $pipeOk = ($test -eq 'ok')
            } catch {}
        }
    } catch {
        Write-Error "[CC] Failed to start pipe server"
        exit 1
    }

    if ($pipeOk) {
        Write-Output "[CC] Pipe server started successfully ✓ (PID: $($proc.Id))"
        exit 0
    } else {
        Write-Error "[CC] Pipe server start failed — Python may be missing or pywin32 not installed"
        exit 1
    }
}

# ═══════════════════════════════════════════
# Validate: message required for non-init mode
# ═══════════════════════════════════════════

if (-not $Message) {
    Write-Error "[CC] Message required. Usage: .\call_assistant.ps1 'your message' or .\call_assistant.ps1 -Init"
    exit 1
}

# Resolve relative paths from script directory
$GATEWAY = $cfg.gateway.url.TrimEnd('/')
$pipeScript = $cfg.pipe.server_script
if (-not [System.IO.Path]::IsPathRooted($pipeScript)) {
    $pipeScript = Join-Path $SCRIPT_DIR $pipeScript
}
$OUTBOX = $cfg.fallback.outbox
if (-not [System.IO.Path]::IsPathRooted($OUTBOX)) {
    $OUTBOX = Join-Path $SCRIPT_DIR $OUTBOX
}
$PIPE_NAME = "\\.\pipe\$($cfg.pipe.pipe_name)"

# ═══════════════════════════════════════════
# Step 1: Resolve token
# Priority: CLI > config.token > config.token_file > openclaw.json auto-detect > env
# ═══════════════════════════════════════════

$TOKEN = ""

# 1) CLI parameter
if ($Token) { $TOKEN = $Token }

# 2) Config file: token field
if (-not $TOKEN -and $cfg.gateway.token) { $TOKEN = $cfg.gateway.token }

# 3) Config file: token_file field
if (-not $TOKEN -and $cfg.gateway.token_file) {
    try {
        $tf = $cfg.gateway.token_file
        if (-not [System.IO.Path]::IsPathRooted($tf)) { $tf = Join-Path $SCRIPT_DIR $tf }
        if (Test-Path $tf) { $TOKEN = (Get-Content $tf -Raw).Trim() }
    } catch {}
}

# 4) OpenClaw auto-detect (zero-config for OpenClaw users)
if (-not $TOKEN) {
    try {
        $oc = Get-Content "$env:USERPROFILE\.openclaw\openclaw.json" -Raw -ErrorAction Stop | ConvertFrom-Json
        $TOKEN = $oc.gateway.auth.token
    } catch {}
}

# 5) Environment variable
if (-not $TOKEN -and $cfg.gateway.token_env) {
    foreach ($scope in @("Process", "Machine", "User")) {
        try {
            $val = [Environment]::GetEnvironmentVariable($cfg.gateway.token_env, $scope)
            if ($val) { $TOKEN = $val; break }
        } catch {}
    }
}

if (-not $TOKEN) {
    Write-Output "[CC] No token found. Set via: -Token, .call-assistant.json, or ~/.openclaw/openclaw.json"
    exit 1
}

# ═══════════════════════════════════════════
# Step 2: Start pipe server (Python optional, CreateFile check)
# ═══════════════════════════════════════════

$pipeOk = $false

if (-not $cfg.pipe.enabled) {
    Write-Output "[CC] Pipe disabled by config — outbox-only mode"
} else {
    # Test pipe with CreateFile (more reliable than Get-Process CommandLine)
    try {
        $test = & $cfg.pipe.python -c @"
import win32pipe, win32file
try:
    h = win32file.CreateFile(r'$PIPE_NAME', win32file.GENERIC_READ, 0, None, win32file.OPEN_EXISTING, 0, None)
    h.Close()
    print('ok')
except: print('dead')
"@ 2>$null
        $pipeOk = ($test -eq 'ok')
    } catch {
        Write-Warning "[CC] Python '$($cfg.pipe.python)' not found — outbox-only mode"
        Write-Warning "[CC] Install Python or set pipe.enabled: false in .call-assistant.json"
    }

    if (-not $pipeOk -and $pipeOk -ne $true) {
        # Pipe not running — try to start it
        Write-Warning "[CC] Pipe not running, starting..."
        try {
            if (Test-Path $pipeScript) {
                $null = Start-Process $cfg.pipe.python -ArgumentList $pipeScript -WindowStyle Hidden -PassThru
                Start-Sleep -Seconds $cfg.pipe.startup_wait_sec

                # Verify restart
                try {
                    $test = & $cfg.pipe.python -c @"
import win32pipe, win32file
try:
    h = win32file.CreateFile(r'$PIPE_NAME', win32file.GENERIC_READ, 0, None, win32file.OPEN_EXISTING, 0, None)
    h.Close()
    print('ok')
except: print('dead')
"@ 2>$null
                    $pipeOk = ($test -eq 'ok')
                } catch {}
            }
        } catch {
            Write-Warning "[CC] Failed to start pipe server — outbox-only mode"
        }
    }
}

# ═══════════════════════════════════════════
# Step 3: Write outbox (primary), then notify via Gateway
# ═══════════════════════════════════════════

# Always WRITE (replace) full message to outbox first — single-message channel, not a log
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Set-Content -Path $OUTBOX -Value "### [$ts] [CC]$([Environment]::NewLine)$Message$([Environment]::NewLine)" -Encoding UTF8

# Gateway only sends a lightweight notification — no body content
$msg = "去看 cc_outbox.md"

$body = @{
    model = $cfg.gateway.model
    messages = @(@{ role = 'user'; content = $msg })
    stream = $true
} | ConvertTo-Json -Depth 4 -Compress

$reply = ""
$ok = $false
$maxRetries = $cfg.fallback.max_retries + 1

for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $wr = Invoke-WebRequest -Uri "$GATEWAY$($cfg.gateway.chat_endpoint)" `
            -Method Post `
            -Headers @{ Authorization = "Bearer $TOKEN" } `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec $Timeout `
            -ErrorAction Stop

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
        if ($i -lt $maxRetries) {
            Write-Warning "[CC] Attempt $i returned empty, retrying in $($cfg.fallback.retry_delay_sec)s..."
            Start-Sleep -Seconds $cfg.fallback.retry_delay_sec
        }
    } catch {
        # Fault classification: external errors → do NOT retry
        $errMsg = $_.Exception.Message
        if ($errMsg -match '401|403|503') {
            Write-Warning "[CC] External fault (Gateway $($matches[0])) — do NOT retry. Escalate to 小助理."
            break
        }
        if ($i -lt $maxRetries) {
            Write-Warning "[CC] Internal fault (Attempt $i: $errMsg), retrying..."
            Start-Sleep -Seconds $cfg.fallback.retry_delay_sec
        }
    }
}

# ═══════════════════════════════════════════
# Step 4: Report result
# ═══════════════════════════════════════════

if ($ok) {
    Write-Output $reply
} else {
    Write-Warning "[CC] Gateway doorbell failed — message already safe in cc_outbox.md"
    Write-Warning "[CC] 小助理 may still read outbox. If no reply in 30s, escalate to 乾茂."
}
