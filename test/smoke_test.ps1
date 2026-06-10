# smoke_test.ps1 — End-to-end test for call-assistant
param(
    [int]$Timeout = 30
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$MainScript = Join-Path $RootDir "call_assistant.ps1"
$Passed = 0
$Failed = 0

function Test-Step($name, $script) {
    Write-Output -NoNewline "  $name ... "
    try {
        & $script
        Write-Output "PASS"
        $global:Passed++
    } catch {
        Write-Output "FAIL: $($_.Exception.Message)"
        $global:Failed++
    }
}

Write-Output "═══════════════════════════════════"
Write-Output " call-assistant smoke test"
Write-Output "═══════════════════════════════════"
Write-Output ""

# Test 1: Main script exists
Test-Step "Main script present" { if (-not (Test-Path $MainScript)) { throw "call_assistant.ps1 not found" } }

# Test 2: Config exists
Test-Step "Config present" {
    $cfg = Join-Path $RootDir ".call-assistant.json"
    $example = Join-Path $RootDir ".call-assistant.json.example"
    if (-not (Test-Path $cfg) -and -not (Test-Path $example)) { throw "No config found" }
}

# Test 3: Python available
Test-Step "Python available" {
    try { $null = Get-Command python -ErrorAction Stop } catch {
        try { $null = Get-Command python3 -ErrorAction Stop } catch { throw "python not found" }
    }
}

# Test 4: Pipe server script exists
Test-Step "Pipe server script" {
    $pipeScript = Join-Path $RootDir "shared" "cc_push_server.py"
    if (-not (Test-Path $pipeScript)) { throw "cc_push_server.py not found" }
}

# Test 5: Gateway health (optional, may not be running)
Test-Step "Gateway health" {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:18789/health" -TimeoutSec 5
        if ($r.StatusCode -ne 200) { throw "status $($r.StatusCode)" }
    } catch { throw "Gateway not running at localhost:18789" }
}

# Test 6: GATEWAY_TOKEN set
Test-Step "GATEWAY_TOKEN" {
    $token = [Environment]::GetEnvironmentVariable("GATEWAY_TOKEN", "Process")
    if (-not $token) { throw "GATEWAY_TOKEN not set" }
}

# Test 7: Config parseable
Test-Step "Config valid JSON" {
    $cfgPath = Join-Path $RootDir ".call-assistant.json"
    if (Test-Path $cfgPath) {
        $null = Get-Content $cfgPath -Raw | ConvertFrom-Json
    } else {
        $null = Get-Content (Join-Path $RootDir ".call-assistant.json.example") -Raw | ConvertFrom-Json
    }
}

Write-Output ""
Write-Output "═══════════════════════════════════"
Write-Output " Results: $Passed passed, $Failed failed"
Write-Output "═══════════════════════════════════"

if ($Failed -gt 0) { exit 1 } else { exit 0 }
