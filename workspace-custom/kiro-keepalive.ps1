# Kiro Keepalive - Token check + API verify + JSON output
$ErrorActionPreference = "Continue"

$result = @{
    timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
    token_status = "unknown"
    token_expires_in_min = -1
    token_refresh = "skipped"
    api_check = "unknown"
}

# Step 1: Check token expiry
$credsFile = "C:\Users\zhuyulin\.aws\sso\cache\kiro-auth-token.json"
if (Test-Path $credsFile) {
    try {
        $creds = Get-Content $credsFile -Raw | ConvertFrom-Json
        $expiresAt = [DateTime]::Parse($creds.expiresAt).ToUniversalTime()
        $now = [DateTime]::UtcNow
        $remainMin = [math]::Round(($expiresAt - $now).TotalMinutes, 1)
        $result.token_expires_in_min = $remainMin
        if ($remainMin -le 0) {
            $result.token_status = "expired"
        }
        elseif ($remainMin -le 60) {
            $result.token_status = "expiring_soon"
        }
        else {
            $result.token_status = "valid"
        }
    }
    catch {
        $result.token_status = "parse_error"
        $result.token_error = $_.Exception.Message
    }
}
else {
    $result.token_status = "file_missing"
}

# Step 2: Proactive refresh if expiring
$needsRefresh = ($result.token_status -eq "expired") -or ($result.token_status -eq "expiring_soon")
if ($needsRefresh) {
    try {
        $job = Start-Job -ScriptBlock { python "D:\Kiro\testopenclaw\refresh_token.py" 2>&1 }
        $finished = Wait-Job $job -Timeout 20
        $refreshOut = if ($finished) { Receive-Job $job | Out-String } else { Remove-Job $job -Force; "TIMEOUT" }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        if ($refreshOut -match "SUCCESS") {
            $result.token_refresh = "ok"
            $creds2 = Get-Content $credsFile -Raw | ConvertFrom-Json
            $exp2 = [DateTime]::Parse($creds2.expiresAt).ToUniversalTime()
            $result.token_expires_in_min = [math]::Round(($exp2 - [DateTime]::UtcNow).TotalMinutes, 1)
            $result.token_status = "refreshed"
        }
        elseif ($refreshOut -match "TIMEOUT") {
            $result.token_refresh = "timeout"
            $result.token_error = "refresh_script_timeout_20s"
        }
        elseif ($refreshOut -match "invalid_grant") {
            $result.token_refresh = "revoked"
            $result.token_error = "need_relogin"
        }
        else {
            $result.token_refresh = "failed"
            $result.token_error = $refreshOut.Substring(0, [Math]::Min(150, $refreshOut.Length)).Trim()
        }
    }
    catch {
        $result.token_refresh = "error"
        $result.token_error = $_.Exception.Message
    }
}

# Step 3: API connectivity check
# 使用 openclaw.json 中配置的 API Key（kiro-gw provider）
$credsFile = "C:\Users\zhuyulin\.aws\sso\cache\kiro-auth-token.json"
$apiBase = if ($env:KIRO_API_BASE) { $env:KIRO_API_BASE.TrimEnd('/') } else { "http://127.0.0.1:9000" }

# 读取配置中的 API Key（kiro-gw provider）
$apiKey = $env:KIRO_PROXY_API_KEY
if (-not $apiKey) {
    try {
        $config = Get-Content "C:\Users\zhuyulin\.openclaw\openclaw.json" -Raw | ConvertFrom-Json
        $apiKey = $config.models.providers.'kiro-gw'.apiKey
    }
    catch {
        $result.api_config_error = $_.Exception.Message
    }
}

$healthStatus = 0
$modelsStatus = 0
$healthMs = 0
$modelsMs = 0
$healthError = $null
$modelsError = $null
for ($attempt = 1; $attempt -le 2; $attempt++) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $healthResponse = Invoke-WebRequest -Uri "$apiBase/health" -Method GET -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $healthStatus = [int]$healthResponse.StatusCode
        $healthError = $null
    }
    catch {
        $healthStatus = 0
        if ($_.Exception.Response) { try { $healthStatus = [int]$_.Exception.Response.StatusCode } catch {} }
        $healthError = $_.Exception.Message
    }
    $watch.Stop()
    $healthMs = $watch.ElapsedMilliseconds

    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $apiKey) { throw "missing_api_key" }
        $headers = @{ Authorization = "Bearer $apiKey" }
        $modelsResponse = Invoke-WebRequest -Uri "$apiBase/v1/models" -Method GET -Headers $headers -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $modelsStatus = [int]$modelsResponse.StatusCode
        $modelsError = $null
    }
    catch {
        $modelsStatus = 0
        if ($_.Exception.Response) { try { $modelsStatus = [int]$_.Exception.Response.StatusCode } catch {} }
        $modelsError = $_.Exception.Message
    }
    $watch.Stop()
    $modelsMs = $watch.ElapsedMilliseconds

    if (($healthStatus -eq 200) -and ($modelsStatus -eq 200)) { break }
    if ($attempt -lt 2) { Start-Sleep -Seconds 2 }
}

$result.api_health_status = $healthStatus
$result.api_models_status = $modelsStatus
$result.api_health_ms = $healthMs
$result.api_models_ms = $modelsMs
if (($healthStatus -eq 200) -and ($modelsStatus -eq 200)) {
    $result.api_check = "ok"
}
else {
    $result.api_check = "failed"
    $diagnostics = @()
    if ($healthError) { $diagnostics += "health=$healthError" }
    elseif ($healthStatus -ne 200) { $diagnostics += "health_status_$healthStatus" }
    if ($modelsError) { $diagnostics += "models=$modelsError" }
    elseif ($modelsStatus -ne 200) { $diagnostics += "models_status_$modelsStatus" }
    $result.api_error = $diagnostics -join "; "
}

# Step 4: Append to JSONL log (self-write, no BOM, robust)
$result.wechat_heartbeat = "n/a-delivery"
$jsonLine = $result | ConvertTo-Json -Compress
try {
    $logPath = "C:\Users\zhuyulin\.openclaw\workspace\logs\kiro-token.jsonl"
    $logDir = Split-Path $logPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($logPath, $jsonLine + "`n", $utf8NoBom)
}
catch {
    $result.log_write_error = $_.Exception.Message
}

# Step 5: Output JSON to stdout (agent reads this for summary)
$jsonLine | Write-Output

# Step 6: Non-zero exit on real anomaly so cron failureAlert can catch it
$tokenBad = @("expired", "parse_error", "file_missing") -contains $result.token_status
$refreshBad = @("failed", "revoked", "error", "timeout") -contains $result.token_refresh
$apiBad = ($result.api_check -ne "ok")
if ($tokenBad -or $refreshBad -or $apiBad) {
    exit 1
}
exit 0
