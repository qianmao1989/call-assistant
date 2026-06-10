# call_assistant.ps1 v4.0 — CC ↔ AI Assistant Reliable Messaging
# GitHub: https://github.com/qianmao1989/call-assistant
# Requires: PowerShell 7+, Python 3, OpenClaw/Hermes gateway running locally
#
# Usage:
#   .\call_assistant.ps1 "your message"                  # default timeout
#   .\call_assistant.ps1 "long task" -Timeout 180        # custom timeout
#   .\call_assistant.ps1 "msg" -Config "path/to/.call-assistant.json"

param(
    [Parameter(Mandatory=$true)]
    [string]$Message,

    [int]$Timeout = 0,

    [string]$Config = ""
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ═══════════════════════════════════════════
# Step 0: Load config
# ═══════════════════════════════════════════

$defaultConfig = @{
    gateway = @{
        url = "http://localhost:18789"
        token_env = "GATEWAY_TOKEN"
        model = "openclaw/main"
        health_endpoint = "/health"
        chat_endpoint = "/v1/chat/completions"
    }
    pipe = @{
        server_script = "./shared/cc_push_server.py"
        pipe_name = "openclaw-cc-push"
        python = "python"
        startup_wait_sec = 3
    }
    fallback = @{
        outbox = "./shared/cc_outbox.md"
        timeout_sec = 120
        max_retries = 1
        retry_delay_sec = 2
    }
}

$cfg = $defaultConfig

if ($Config) {
    $configPath = $Config
} else {
    $configPath = Join-Path $ScriptDir ".call-assistant.json"
}

if (Test-Path $configPath) {
    try {
        $userCfg = Get-Content $configPath -Raw | ConvertFrom-Json
        # Merge user config over defaults
        foreach ($section in @("gateway", "pipe", "fallback")) {
            if ($userCfg.$section) {
                foreach ($key in $userCfg.$section.PSObject.Properties.Name) {
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

# Resolve relative paths from script directory
$pipeScript = $cfg.pipe.server_script
if (-not [System.IO.Path]::IsPathRooted($pipeScript)) {
    $pipeScript = Join-Path $ScriptDir $pipeScript
}
$outbox = $cfg.fallback.outbox
if (-not [System.IO.Path]::IsPathRooted($outbox)) {
    $outbox = Join-Path $ScriptDir $outbox
}

# ═══════════════════════════════════════════
# Step 0.5: Validate environment
# ═══════════════════════════════════════════

$TOKEN = [Environment]::GetEnvironmentVariable($cfg.gateway.token_env, "Process")
if (-not $TOKEN) {
    $TOKEN = [Environment]::GetEnvironmentVariable($cfg.gateway.token_env, "Machine")
}
if (-not $TOKEN) {
    $TOKEN = [Environment]::GetEnvironmentVariable($cfg.gateway.token_env, "User")
}

if (-not $TOKEN) {
    Write-Error @"

[call-assistant] MISSING TOKEN
  Environment variable '$($cfg.gateway.token_env)' is not set.

  Fix:
    [System.Environment]::SetEnvironmentVariable('$($cfg.gateway.token_env)', 'your-token-here', 'Machine')
    # Then restart your terminal

  Or set it inline:
    `$env:$($cfg.gateway.token_env) = 'your-token-here'
"@
    exit 1
}

$GATEWAY = $cfg.gateway.url.TrimEnd('/')

# ═══════════════════════════════════════════
# Step 1: Gateway health check
# ═══════════════════════════════════════════

$healthOk = $false
try {
    $health = Invoke-WebRequest -Uri "$GATEWAY$($cfg.gateway.health_endpoint)" -TimeoutSec 5 -ErrorAction Stop
    if ($health.StatusCode -eq 200) { $healthOk = $true }
} catch {}

if (-not $healthOk) {
    Write-Error "[call-assistant] Gateway not reachable at $GATEWAY — is OpenClaw/Hermes running?"
    exit 1
}

# ═══════════════════════════════════════════
# Step 2: Start pipe server if needed
# ═══════════════════════════════════════════

$pipeFound = $false
try {
    $pyProcs = Get-Process python* -ErrorAction SilentlyContinue
    foreach ($p in $pyProcs) {
        if ($p.CommandLine -like '*cc_push_server*') { $pipeFound = $true; break }
    }
} catch {}

if (-not $pipeFound) {
    Write-Warning "[call-assistant] Starting pipe server..."
    if (-not (Test-Path $pipeScript)) {
        Write-Error "[call-assistant] Pipe server script not found: $pipeScript"
        exit 1
    }
    $null = Start-Process $cfg.pipe.python -ArgumentList $pipeScript -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds $cfg.pipe.startup_wait_sec

    # Verify startup
    $pipeFound2 = $false
    try {
        $pyProcs2 = Get-Process python* -ErrorAction SilentlyContinue
        foreach ($p in $pyProcs2) { if ($p.CommandLine -like '*cc_push_server*') { $pipeFound2 = $true; break } }
    } catch {}
    if (-not $pipeFound2) {
        Write-Warning "[call-assistant] Pipe server may not have started. Check: python $pipeScript"
    }
}

# ═══════════════════════════════════════════
# Step 3: Send message (with retry)
# ═══════════════════════════════════════════

# Ensure prefix (avoid glob character class trap)
$msg = $Message
if ($msg -notmatch '^\[CC\]') { $msg = "[CC] $msg" }

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
            Write-Warning "[call-assistant] Attempt $i returned empty, retrying in $($cfg.fallback.retry_delay_sec)s..."
            Start-Sleep -Seconds $cfg.fallback.retry_delay_sec
        }
    } catch {
        if ($i -lt $maxRetries) {
            Write-Warning "[call-assistant] Attempt $i failed ($($_.Exception.Message)), retrying..."
            Start-Sleep -Seconds $cfg.fallback.retry_delay_sec
        } else {
            Write-Warning "[call-assistant] All $maxRetries attempts failed: $($_.Exception.Message)"
        }
    }
}

# ═══════════════════════════════════════════
# Step 4: Output or fallback
# ═══════════════════════════════════════════

if ($ok) {
    Write-Output $reply
} else {
    Write-Warning "[call-assistant] Gateway unreachable, falling back to outbox: $outbox"
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $fallbackMsg = "### [$ts] $msg$([Environment]::NewLine)$Message$([Environment]::NewLine)"
    try {
        $outboxDir = Split-Path $outbox -Parent
        if (-not (Test-Path $outboxDir)) { New-Item -ItemType Directory -Force -Path $outboxDir | Out-Null }
        Add-Content -Path $outbox -Value $fallbackMsg -Encoding UTF8
        Write-Output "FALLBACK: Message written to $outbox — check for reply in 30-60s"
    } catch {
        Write-Error "[call-assistant] Failed to write outbox: $($_.Exception.Message)"
        exit 1
    }
}
