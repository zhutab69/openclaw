# OpenClaw Launcher v4
# 浼樺寲绛栫暐锛氶敊寮€鍚姩鍑忓皯 CPU 绔炰簤锛岃缁嗚繘搴﹀弽棣?

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = "OpenClaw Launcher"

$NODE = "D:\Kiro\testopenclaw\node-v22.22.1-win-x64\node.exe"
$OPENCLAW_MJS = "D:\Kiro\testopenclaw\node-v22.22.1-win-x64\node_modules\openclaw\openclaw.mjs"
# openclaw 包目录（供 Bot Review 扫描内置 skill 用，避免技能页只显示自定义 skill）
$OPENCLAW_PKG_DIR = Split-Path $OPENCLAW_MJS -Parent
$WORKDIR = "D:\Kiro\testopenclaw"
$OPENCLAW_CONFIG = "C:\Users\zhuyulin\.openclaw\openclaw.json"

# External web server projects (single source of truth: webservers.json)
# Both this launcher and the Multi-Agent dashboard read this file. Add projects there, no code change.
$WEBSERVERS_JSON = "$env:USERPROFILE\.openclaw\workspace\webservers.json"
$script:webServers = @()
$script:webProcs = @()
try {
    if (Test-Path $WEBSERVERS_JSON) {
        $wsCfg = Get-Content $WEBSERVERS_JSON -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($wsCfg.webservers) { $script:webServers = @($wsCfg.webservers) }
    }
} catch {}
$script:webPorts = @($script:webServers | ForEach-Object { $_.port } | Where-Object { $_ })

# Allow model prewarm at startup (populates in-memory registry, avoids 20-30s delay on first request)
# $env:OPENCLAW_SKIP_STARTUP_MODEL_PREWARM = "1"  # DISABLED - causes 20-30s cold start on first request

$script:perfStats = @{}

function Elapsed($start) { 
    $ms = [int]((Get-Date)-$start).TotalMilliseconds
    if ($ms -lt 1000) { return "${ms}ms" }
    return "$([math]::Round($ms/1000, 2))s"
}

function Wait-ForPort($port, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $port)
            $tcp.Close()
            return $true
        } catch { Start-Sleep -Milliseconds 300 }
    }
    return $false
}

function Wait-ForHealth($url, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-RestMethod -Uri $url -TimeoutSec 2 -ErrorAction Stop
            if ($r.status -eq "healthy") { return $true }
        } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

function Cleanup {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  Stopping all services..." -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Memory flush: save active session summary to daily memory before shutdown
    try {
        $flushResult = python "D:\Kiro\testopenclaw\memory_flush.py" 2>&1
        if ($flushResult) { Write-Host "  $flushResult" -ForegroundColor DarkGray }
    } catch {}
    
    if ($script:p1 -and !$script:p1.HasExited) { 
        # Kill Kiro Gateway and all its child worker processes
        cmd /c "taskkill /F /T /PID $($script:p1.Id) >nul 2>&1"
        Start-Sleep -Milliseconds 500
    }
    if ($script:p2 -and !$script:p2.HasExited) { $script:p2.Kill() }
    if ($script:pMultiAgent -and !$script:pMultiAgent.HasExited) { $script:pMultiAgent.Kill() }
    if ($script:pBot -and !$script:pBot.HasExited) { $script:pBot.Kill() }
    
    if ($script:webProcs) {
        foreach ($proc in $script:webProcs) {
            if ($proc -and !$proc.HasExited) {
                cmd /c "taskkill /F /T /PID $($proc.Id) >nul 2>&1"
            }
        }
    }
    
    if ($script:subCmdProcs) {
        foreach ($proc in $script:subCmdProcs) {
            if ($proc -and !$proc.HasExited) {
                cmd /c "taskkill /F /T /PID $($proc.Id) >nul 2>&1"
            }
        }
    }
    
    $targetPorts = @(18789, 8899, 8900, 9000) + ($script:agentPorts.Values | Where-Object { $_ }) + $script:webPorts
    $lines = cmd /c "netstat -ano 2>nul"
    foreach ($line in $lines) {
        if ($line -notmatch "LISTENING") { continue }
        foreach ($port in $targetPorts) {
            if ($line -match ":${port}\s" -and $line -match '\s(\d+)\s*$') {
                Stop-Process -Id $Matches[1] -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    $lockDir = "$env:TEMP\openclaw"
    if (Test-Path $lockDir) {
        Get-ChildItem $lockDir -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    }
    
    cmd /c "mcporter daemon stop 2>nul" | Out-Null
    Write-Host "  All services stopped." -ForegroundColor Green
}

# ============================================
# Banner + Version Info
# ============================================
$nodeVer = (& $NODE --version 2>$null).Trim()
$npmVer = (& $NODE -e "console.log(require('child_process').execSync('npm -v').toString().trim())" 2>$null).Trim()
$pythonVer = (python -V 2>&1 | Out-String).Trim() -replace '^Python\s+', ''
$nextVer = (& $NODE -e "console.log(require('D:/Kiro/testopenclaw/OpenClaw-bot-review/node_modules/next/package.json').version)" 2>$null).Trim()
$openclawVer = (& $NODE -e "console.log(require('D:/Kiro/testopenclaw/node-v22.22.1-win-x64/node_modules/openclaw/package.json').version)" 2>$null).Trim()
$mcporterVer = (& $NODE -e "try{console.log(require('D:/Kiro/testopenclaw/node-v22.22.1-win-x64/node_modules/mcporter/package.json').version)}catch(e){console.log('N/A')}" 2>$null).Trim()

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OpenClaw Launcher v4" -ForegroundColor White
Write-Host "  Node $nodeVer / npm $npmVer / Python $pythonVer" -ForegroundColor Gray
Write-Host "  OpenClaw $openclawVer / Next.js $nextVer" -ForegroundColor Gray
Write-Host "  mcporter $mcporterVer" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan

$launchStart = Get-Date

# ============================================
# [1/5] Config + Cleanup
# ============================================
$t0 = Get-Date
Write-Host ""
Write-Host "[1/5] Config + Cleanup..." -NoNewline

$subAgents = @()
$script:agentPorts = @{}

try {
    $config = Get-Content $OPENCLAW_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($agent in $config.agents.list) {
        if ($agent.id -ne "main") {
            # Read profile from agent-profiles.json
            $profilesFile = "C:\Users\zhuyulin\.openclaw\agent-profiles.json"
            $profileMap = @{}
            if (Test-Path $profilesFile) { $profileMap = Get-Content $profilesFile -Raw -Encoding UTF8 | ConvertFrom-Json }
            $profileName = if ($profileMap.($agent.id)) { $profileMap.($agent.id) } else { $agent.id -replace '-agent$', '' }
            $subAgents += @{ id = $agent.id; profile = $profileName }
            $profileCfg = "C:\Users\zhuyulin\.openclaw-$profileName\openclaw.json"
            try {
                if (Test-Path $profileCfg) {
                    $cfg = Get-Content $profileCfg -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($cfg.gateway.port) { $script:agentPorts[$agent.id] = $cfg.gateway.port }
                }
            } catch {}
        }
    }
} catch {
    $subAgents = @(
        @{ id = "writer-agent"; profile = "writer" },
        @{ id = "coder-agent";  profile = "coder" },
        @{ id = "info-agent";   profile = "info" },
        @{ id = "image-agent";  profile = "image" }
    )
}

# Cleanup stale processes
$targetPorts = @(18789, 8899, 8900, 9000) + ($script:agentPorts.Values | Where-Object { $_ }) + $script:webPorts
$pidsToKill = @()
$lines = cmd /c "netstat -ano 2>nul"
foreach ($line in $lines) {
    if ($line -notmatch "LISTENING") { continue }
    foreach ($port in $targetPorts) {
        if ($line -match ":${port}\s" -and $line -match '\s(\d+)\s*$') {
            $pidsToKill += $Matches[1]
        }
    }
}
$pidsToKill = $pidsToKill | Sort-Object -Unique
if ($pidsToKill.Count -gt 0) {
    foreach ($procId in $pidsToKill) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

$lockDir = "$env:TEMP\openclaw"
if (Test-Path $lockDir) {
    Get-ChildItem $lockDir -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

$portList = ($script:agentPorts.Values | Sort-Object) -join ", "
Write-Host " $($subAgents.Count) agents (ports: $portList) ($(Elapsed $t0))" -ForegroundColor Green
$script:perfStats["init"] = (Get-Date) - $t0

# ============================================
# [2/5] Kiro Gateway (must be ready before OpenClaw)
# ============================================
$t0 = Get-Date
Write-Host "[2/5] Kiro Gateway..." -NoNewline

# Refresh Kiro auth token before starting Gateway
try {
    $refreshResult = python "D:\Kiro\testopenclaw\refresh_token.py" 2>&1
    if ($refreshResult -match "Refresh SUCCESS") {
        Write-Host " token refreshed..." -NoNewline -ForegroundColor DarkGray
    }
} catch {}

$psi1 = New-Object System.Diagnostics.ProcessStartInfo
$psi1.FileName = "python"
$psi1.Arguments = "main.py --port 9000"
$psi1.WorkingDirectory = "D:\Kiro\testopenclaw\kiro-gateway"
$psi1.UseShellExecute = $false
$psi1.CreateNoWindow = $true
$script:p1 = [System.Diagnostics.Process]::Start($psi1)

if (Wait-ForHealth "http://127.0.0.1:9000/health" 30) {
    Write-Host " ready ($(Elapsed $t0))" -ForegroundColor Green
} else {
    Write-Host " timeout! ($(Elapsed $t0))" -ForegroundColor Red
}
$script:perfStats["kiro"] = (Get-Date) - $t0

# ============================================
# [3/6] Sync Models + Main Gateway
# ============================================
$t0 = Get-Date
Write-Host "[3/5] Launch all services..." -NoNewline

# Sync models (fast, ~1s)
try {
    $result = python "D:\Kiro\testopenclaw\sync_models.py" 2>&1
    $lines = @($result)
    foreach ($line in $lines) {
        if ($line -match "^OK:(\d+):([^:]+):(.*)$") {
            $script:gwToken = $Matches[3]
            $modelCount = $Matches[1]
            break
        }
    }
} catch {}

# Always read token from config (needed for auth.mode=token)
if (-not $script:gwToken -or $script:gwToken -eq "no_change") {
    try {
        $cfg = Get-Content $OPENCLAW_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:gwToken = $cfg.gateway.auth.token
    } catch {}
}

# Start ALL services in parallel (no waiting between them)
# Main Gateway
$psi2 = New-Object System.Diagnostics.ProcessStartInfo
$psi2.FileName = "cmd.exe"
$psi2.Arguments = "/k set OPENCLAW_DISABLE_BONJOUR=1 && `"$NODE`" `"$OPENCLAW_MJS`" gateway --force"
$psi2.WorkingDirectory = $WORKDIR
$psi2.UseShellExecute = $true
$psi2.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
$script:p2 = [System.Diagnostics.Process]::Start($psi2)

# Wait for Main Gateway to be ready before starting sub-agents
# This avoids cold-start race conditions (wecom/weixin channel init + sub-agent CPU spike)
if (Wait-ForPort 18789 45) {
    Start-Sleep -Milliseconds 3000  # Extra 3s for channels to fully initialize
}

# Sub-Agents (stagger 2s to reduce CPU spike during main gateway channel init)
$script:subCmdProcs = @()
foreach ($agent in $subAgents) {
    $cmdArgs = "/k title $($agent.id) && set OPENCLAW_DISABLE_BONJOUR=1 && `"$NODE`" `"$OPENCLAW_MJS`" --profile $($agent.profile) gateway --force"
    $proc = Start-Process "cmd.exe" -ArgumentList $cmdArgs -WorkingDirectory $WORKDIR -WindowStyle Minimized -PassThru
    $script:subCmdProcs += $proc
    Start-Sleep -Milliseconds 2000
}

# Multi-Agent + Bot Review (lightweight)
$psiMA = New-Object System.Diagnostics.ProcessStartInfo
$psiMA.FileName = $NODE
$psiMA.Arguments = "`"$env:USERPROFILE\.openclaw\workspace\dashboard-server.cjs`""
$psiMA.WorkingDirectory = "$env:USERPROFILE\.openclaw\workspace"
$psiMA.UseShellExecute = $false
$psiMA.CreateNoWindow = $true
$script:pMultiAgent = [System.Diagnostics.Process]::Start($psiMA)

$psiBot = New-Object System.Diagnostics.ProcessStartInfo
$psiBot.FileName = "cmd.exe"
$psiBot.Arguments = "/c set PORT=8900&& set HOSTNAME=127.0.0.1&& set OPENCLAW_HOME=$env:USERPROFILE\.openclaw&& set OPENCLAW_PACKAGE_DIR=$OPENCLAW_PKG_DIR&& set OPENCLAW_ALLOW_UNAUTHENTICATED_LOCAL_OPERATOR_UI=true&& set NODE_ENV=production&& `"$NODE`" `"D:\Kiro\testopenclaw\OpenClaw-bot-review\.next\standalone\server.js`""
$psiBot.WorkingDirectory = "D:\Kiro\testopenclaw\OpenClaw-bot-review\.next\standalone"
$psiBot.UseShellExecute = $false
$psiBot.CreateNoWindow = $true
$script:pBot = [System.Diagnostics.Process]::Start($psiBot)

# External web server projects (from webservers.json): rental 8901, spider-monitor 8902, ...
$script:webProcs = @()
foreach ($ws in $script:webServers) {
    try {
        # 防御：启动前释放该端口，避免上次未正常关闭导致的残留占用
        $wsLines = cmd /c "netstat -ano 2>nul"
        foreach ($wsLine in $wsLines) {
            if ($wsLine -match "LISTENING" -and $wsLine -match ":$($ws.port)\s" -and $wsLine -match '\s(\d+)\s*$') {
                Stop-Process -Id $Matches[1] -Force -ErrorAction SilentlyContinue
            }
        }
        $psiWs = New-Object System.Diagnostics.ProcessStartInfo
        $psiWs.FileName = $NODE
        $psiWs.Arguments = "`"$($ws.script)`""
        $psiWs.WorkingDirectory = $ws.cwd
        $psiWs.UseShellExecute = $false
        $psiWs.CreateNoWindow = $true
        $psiWs.EnvironmentVariables["PORT"] = "$($ws.port)"
        $script:webProcs += [System.Diagnostics.Process]::Start($psiWs)
    } catch {}
}

# mcporter daemon
try {
    $daemonStatus = cmd /c "mcporter daemon status 2>&1"
    if ($daemonStatus -notmatch "pid \d+") {
        cmd /c "mcporter daemon start 2>nul" | Out-Null
    }
} catch {}

Write-Host " $modelCount models, all launched ($(Elapsed $t0))" -ForegroundColor Green
$script:perfStats["launch"] = (Get-Date) - $t0

# ============================================
# [4/6] Wait for all services (with retry for Main Gateway)
# ============================================
$t0 = Get-Date
Write-Host "[4/5] Waiting for services..." -NoNewline

$allPorts = @(18789, 8899, 8900)
$portNames = @{ 18789 = "Main Gateway"; 8899 = "Multi-Agent"; 8900 = "Bot Review" }
foreach ($agent in $subAgents) {
    $port = $script:agentPorts[$agent.id]
    if ($port) {
        $allPorts += $port
        $name = ($agent.id -replace '-agent$', '')
        $portNames[$port] = $name.Substring(0,1).ToUpper() + $name.Substring(1)
    }
}
foreach ($ws in $script:webServers) {
    if ($ws.port) { $allPorts += $ws.port; $portNames[$ws.port] = $ws.name }
}

$totalPorts = $allPorts.Count
$deadline = (Get-Date).AddSeconds(60)
$pendingPorts = [System.Collections.Generic.List[int]]::new()
foreach ($p in $allPorts) { $pendingPorts.Add($p) }
$mainRetries = 0
$doneCount = 0

# Progress bar animation
Write-Host ""
$barWidth = 30
function Show-Progress($done, $total) {
    $pct = [math]::Round(($done / $total) * 100)
    $filled = [math]::Round(($done / $total) * $barWidth)
    $empty = $barWidth - $filled
    $bar = ("=" * $filled) + ("." * $empty)
    Write-Host "`r  [$bar] $pct%" -NoNewline
}

Show-Progress 0 $totalPorts

while ($pendingPorts.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $readyPorts = @()
    foreach ($port in $pendingPorts) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $port)
            $tcp.Close()
            $readyPorts += $port
            $doneCount++
            Show-Progress $doneCount $totalPorts
        } catch {}
    }
    foreach ($port in $readyPorts) { $pendingPorts.Remove($port) | Out-Null }
    
    # Main Gateway crash detection + auto-restart
    if ($pendingPorts.Contains(18789) -and $script:p2.HasExited -and $mainRetries -lt 3) {
        $mainRetries++
        Write-Host "  [RETRY $mainRetries/3] Main Gateway crashed (exit=$($script:p2.ExitCode))" -ForegroundColor Red
        # Show error from stability bundle
        $stabFile = Get-ChildItem "C:\Users\zhuyulin\.openclaw\logs\stability" -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($stabFile) {
            try {
                $stabData = Get-Content $stabFile.FullName -Raw | ConvertFrom-Json
                $errMsg = $stabData.error.message
                if ($errMsg) { Write-Host "    Error: $($errMsg.Substring(0, [Math]::Min(100, $errMsg.Length)))" -ForegroundColor Red }
            } catch {}
        }
        # Clean locks and restart
        Get-ChildItem "$env:TEMP\openclaw" -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        $script:p2 = [System.Diagnostics.Process]::Start($psi2)
    }
    
    if ($pendingPorts.Count -gt 0) { Start-Sleep -Milliseconds 500 }
}

if ($pendingPorts.Count -gt 0) {
    Write-Host ""
    foreach ($port in $pendingPorts) {
        Write-Host "  [FAIL] $($portNames[$port]) ($port)" -ForegroundColor Red
    }
} else {
    Write-Host ""
    # Show all services aligned
    $maxNameLen = ($portNames.Values | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    foreach ($port in $allPorts) {
        $name = $portNames[$port]
        $pad = " " * ($maxNameLen - $name.Length)
        Write-Host "  [OK] $name$pad  :$port" -ForegroundColor Green
    }
}
$script:perfStats["wait"] = (Get-Date) - $t0

# ============================================
# Warm-up: trigger model-resolution + auth cache population
# This ensures the first user interaction is fast (avoids 14-18s cold start)
if (-not $pendingPorts.Contains(18789)) {
    Write-Host "  [WARMUP] Triggering model cache..." -NoNewline -ForegroundColor DarkGray
    try {
        $warmupBody = '{"model":"claude-sonnet-4.5","messages":[{"role":"user","content":"ping"}],"max_tokens":1}'
        $warmupHeaders = @{
            "Authorization" = "Bearer my-super-secret-password-123"
            "Content-Type" = "application/json"
        }
        # Fire-and-forget via background job (don't block startup)
        Start-Job -ScriptBlock {
            param($body, $headers)
            try {
                Invoke-RestMethod -Uri "http://127.0.0.1:9000/v1/chat/completions" -Method POST -Headers $headers -Body $body -TimeoutSec 30 -ErrorAction Stop | Out-Null
            } catch {}
        } -ArgumentList $warmupBody, $warmupHeaders | Out-Null
        Write-Host " sent" -ForegroundColor DarkGray
    } catch {}
}

# [6/6] Open browsers + Done
# ============================================
$t0 = Get-Date
Write-Host "[5/5] Opening browsers..." -NoNewline

try {
    $gwUrl = if ($script:gwToken -and $script:gwToken -ne "no_change") { "http://127.0.0.1:18789/?token=$($script:gwToken)" } else { "http://127.0.0.1:18789/" }
    $openUrls = @($gwUrl, "http://127.0.0.1:8899/", "http://127.0.0.1:8900/")
    $openUrls += @($script:webServers | ForEach-Object { $_.url } | Where-Object { $_ })

    # Open ALL tabs in ONE default-browser invocation (avoids cold-start tab race / blank tabs)
    $browserExe = $null
    try {
        $progId = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" -ErrorAction Stop).ProgId
        $openCmd = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$progId\shell\open\command" -ErrorAction Stop)."(default)"
        if ($openCmd -match '"([^"]+\.exe)"') { $browserExe = $Matches[1] }
        elseif ($openCmd -match '^\s*([^"\s]+\.exe)') { $browserExe = $Matches[1] }
    } catch {}

    if ($browserExe -and (Test-Path $browserExe)) {
        Start-Process -FilePath $browserExe -ArgumentList $openUrls -ErrorAction SilentlyContinue
    } else {
        # Fallback: open one by one with spacing
        foreach ($u in $openUrls) { cmd /c start "" "$u" 2>$null; Start-Sleep -Milliseconds 800 }
    }
    Write-Host " done ($(Elapsed $t0))" -ForegroundColor Green
} catch {
    Write-Host " partial ($(Elapsed $t0))" -ForegroundColor Yellow
}
$script:perfStats["browsers"] = (Get-Date) - $t0

# ============================================
# Summary
# ============================================
$totalSec = [math]::Round(((Get-Date) - $launchStart).TotalSeconds, 1)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  All services running! (${totalSec}s)" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

function FmtMs($ms) { if ($ms -lt 1000) { "${ms}ms" } else { "$([math]::Round($ms/1000,2))s" } }

Write-Host "  Init:        $(FmtMs ([int]$script:perfStats['init'].TotalMilliseconds))" -ForegroundColor Gray
Write-Host "  Kiro GW:     $(FmtMs ([int]$script:perfStats['kiro'].TotalMilliseconds))" -ForegroundColor Gray
Write-Host "  Launch All:  $(FmtMs ([int]$script:perfStats['launch'].TotalMilliseconds))" -ForegroundColor Gray
Write-Host "  Wait Ready:  $(FmtMs ([int]$script:perfStats['wait'].TotalMilliseconds))" -ForegroundColor Gray
Write-Host "  Browsers:    $(FmtMs ([int]$script:perfStats['browsers'].TotalMilliseconds))" -ForegroundColor Gray
Write-Host ""
Write-Host "  Main Dashboard: http://127.0.0.1:18789/" -ForegroundColor Cyan
Write-Host "  Multi-Agent:    http://127.0.0.1:8899" -ForegroundColor Cyan
Write-Host "  Bot Review:     http://127.0.0.1:8900" -ForegroundColor Cyan
foreach ($ws in $script:webServers) { Write-Host "  $($ws.name): $($ws.url)" -ForegroundColor Cyan }
Write-Host ""
Write-Host "  Press any key to stop all services" -ForegroundColor DarkGray
Write-Host ""

# ============================================
# Watchdog loop
# ============================================
$checkCount = 0
$kiroFailCount = 0
$mainFailCount = 0
$upstreamFailCount = 0
$lastUpstreamOk = $true
$watchdogStartTime = Get-Date
while ($true) {
    if ([Console]::KeyAvailable) { 
        $null = [Console]::ReadKey($true)
        break 
    }
    
    $checkCount++
    
    # Fast crash detection: check every 2s if Main Gateway process has exited
    if ($script:p2 -and $script:p2.HasExited -and ((Get-Date) - $watchdogStartTime).TotalSeconds -gt 90) {
        $mainFailCount = 99  # Trigger immediate restart
    }
    
    if ($checkCount % 15 -eq 0 -and ((Get-Date) - $watchdogStartTime).TotalSeconds -gt 90) {
        # Check Kiro Gateway (health endpoint, not just TCP)
        $kiroOk = $false
        try {
            $r = Invoke-RestMethod -Uri "http://127.0.0.1:9000/health" -TimeoutSec 3 -ErrorAction Stop
            if ($r.status -eq "healthy") { $kiroOk = $true; $kiroFailCount = 0 }
        } catch {}
        
        if (-not $kiroOk) {
            $kiroFailCount++
            if ($kiroFailCount -ge 2) {
                Write-Host ""
                Write-Host "  ┌─────────────────────────────────────────────────" -ForegroundColor DarkYellow
                Write-Host "  │ " -NoNewline -ForegroundColor DarkYellow
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] " -NoNewline -ForegroundColor Gray
                Write-Host "KIRO GATEWAY " -NoNewline -ForegroundColor Yellow
                Write-Host "DOWN ($kiroFailCount failures)" -ForegroundColor White
                Write-Host "  │ " -NoNewline -ForegroundColor DarkYellow
                Write-Host "[1/3] Stopping old process..." -NoNewline -ForegroundColor Yellow
                if ($script:p1 -and !$script:p1.HasExited) { $script:p1.Kill(); Start-Sleep -Milliseconds 1000 }
                Write-Host " done" -ForegroundColor DarkGray
                Write-Host "  │ " -NoNewline -ForegroundColor DarkYellow
                Write-Host "[2/3] Starting new instance..." -NoNewline -ForegroundColor Yellow
                $psi1r = New-Object System.Diagnostics.ProcessStartInfo
                $psi1r.FileName = "python"; $psi1r.Arguments = "main.py --port 9000"
                $psi1r.WorkingDirectory = "D:\Kiro\testopenclaw\kiro-gateway"
                $psi1r.UseShellExecute = $false; $psi1r.CreateNoWindow = $true
                $script:p1 = [System.Diagnostics.Process]::Start($psi1r)
                Write-Host " pid=$($script:p1.Id)" -ForegroundColor DarkGray
                Write-Host "  │ " -NoNewline -ForegroundColor DarkYellow
                Write-Host "[3/3] Waiting for health..." -NoNewline -ForegroundColor Yellow
                if (Wait-ForHealth "http://127.0.0.1:9000/health" 30) {
                    Write-Host " OK" -ForegroundColor Green
                    Write-Host "  │ " -NoNewline -ForegroundColor DarkYellow
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Recovered" -ForegroundColor Green
                    $kiroFailCount = 0
                } else {
                    Write-Host " FAILED" -ForegroundColor Red
                    Write-Host "  │ " -NoNewline -ForegroundColor DarkYellow
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Restart failed!" -ForegroundColor Red
                }
                Write-Host "  └─────────────────────────────────────────────────" -ForegroundColor DarkYellow
                Write-Host ""
            }
        }
        
        # Check Kiro API upstream connectivity (only if gateway is healthy)
        if ($kiroOk) {
            $upstreamOk = $false
            try {
                $body = '{"model":"claude-sonnet-4.5","messages":[{"role":"user","content":"ping"}],"max_tokens":1}'
                $headers = @{"Authorization"="Bearer my-super-secret-password-123"; "Content-Type"="application/json"}
                $ur = Invoke-RestMethod -Uri "http://127.0.0.1:9000/v1/chat/completions" -Method POST -Headers $headers -Body $body -TimeoutSec 15 -ErrorAction Stop
                $upstreamOk = $true
                $upstreamFailCount = 0
                if (-not $lastUpstreamOk) {
                    Write-Host "  ┌─────────────────────────────────────────────────" -ForegroundColor Green
                    Write-Host "  │ [$(Get-Date -Format 'HH:mm:ss')] NETWORK: Kiro API recovered" -ForegroundColor Green
                    Write-Host "  └─────────────────────────────────────────────────" -ForegroundColor Green
                    Write-Host ""
                    $lastUpstreamOk = $true
                }
            } catch {
                $upstreamFailCount++
                if ($upstreamFailCount -ge 2 -and $lastUpstreamOk) {
                    Write-Host ""
                    Write-Host "  ┌─────────────────────────────────────────────────" -ForegroundColor DarkYellow
                    Write-Host "  │ [$(Get-Date -Format 'HH:mm:ss')] NETWORK: Kiro API unreachable ($upstreamFailCount failures)" -ForegroundColor Yellow
                    Write-Host "  └─────────────────────────────────────────────────" -ForegroundColor DarkYellow
                    $lastUpstreamOk = $false
                }
                # After 5 consecutive failures, try restarting Kiro Gateway (token refresh)
                if ($upstreamFailCount -eq 5) {
                    Write-Host ""
                    Write-Host "  ┌─────────────────────────────────────────────────" -ForegroundColor Magenta
                    Write-Host "  │ " -NoNewline -ForegroundColor Magenta
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] " -NoNewline -ForegroundColor Gray
                    Write-Host "TOKEN REFRESH " -NoNewline -ForegroundColor Magenta
                    Write-Host "API unreachable 5x" -ForegroundColor White
                    Write-Host "  │ " -NoNewline -ForegroundColor Magenta
                    Write-Host "[1/3] Stopping Kiro Gateway..." -NoNewline -ForegroundColor Magenta
                    if ($script:p1 -and !$script:p1.HasExited) { $script:p1.Kill(); Start-Sleep -Milliseconds 1000 }
                    Write-Host " done" -ForegroundColor DarkGray
                    Write-Host "  │ " -NoNewline -ForegroundColor Magenta
                    Write-Host "[2/3] Starting fresh instance..." -NoNewline -ForegroundColor Magenta
                    $psi1r = New-Object System.Diagnostics.ProcessStartInfo
                    $psi1r.FileName = "python"; $psi1r.Arguments = "main.py --port 9000"
                    $psi1r.WorkingDirectory = "D:\Kiro\testopenclaw\kiro-gateway"
                    $psi1r.UseShellExecute = $false; $psi1r.CreateNoWindow = $true
                    $script:p1 = [System.Diagnostics.Process]::Start($psi1r)
                    Write-Host " pid=$($script:p1.Id)" -ForegroundColor DarkGray
                    Write-Host "  │ " -NoNewline -ForegroundColor Magenta
                    Write-Host "[3/3] Waiting for health..." -NoNewline -ForegroundColor Magenta
                    Wait-ForHealth "http://127.0.0.1:9000/health" 30 | Out-Null
                    Write-Host " done" -ForegroundColor Green
                    Write-Host "  └─────────────────────────────────────────────────" -ForegroundColor Magenta
                    Write-Host ""
                }
            }
        }
        
        # Check Main Gateway (only restart if process actually crashed, not just busy)
        $mainOk = $false
        if ($script:p2 -and $script:p2.HasExited) {
            # Process actually crashed - definitely need restart
            $mainFailCount = 99
        } else {
            # Process running - check TCP with longer timeout
            try { 
                $tcp = New-Object System.Net.Sockets.TcpClient
                $tcp.Connect("127.0.0.1", 18789)
                $tcp.Close()
                $mainOk = $true
                $mainFailCount = 0
            } catch {
                $mainFailCount++
            }
        }
        
        if (-not $mainOk -and $mainFailCount -ge 5) {
            Write-Host ""
            Write-Host "  ┌─────────────────────────────────────────────────" -ForegroundColor Red
            Write-Host "  │ " -NoNewline -ForegroundColor Red
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] " -NoNewline -ForegroundColor Gray
            Write-Host "MAIN GATEWAY " -NoNewline -ForegroundColor Red
            Write-Host "DOWN ($mainFailCount failures)" -ForegroundColor White
            Write-Host "  │ " -NoNewline -ForegroundColor Red
            Write-Host "[1/4] Stopping old process..." -NoNewline -ForegroundColor Red
            if ($script:p2 -and !$script:p2.HasExited) { $script:p2.Kill(); Start-Sleep -Milliseconds 500 }
            Write-Host " done" -ForegroundColor DarkGray
            Write-Host "  │ " -NoNewline -ForegroundColor Red
            Write-Host "[2/4] Cleaning locks..." -NoNewline -ForegroundColor Red
            $lockDir = "$env:TEMP\openclaw"
            if (Test-Path $lockDir) {
                Get-ChildItem $lockDir -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
            }
            Write-Host " done" -ForegroundColor DarkGray
            Write-Host "  │ " -NoNewline -ForegroundColor Red
            Write-Host "[3/4] Starting new instance..." -NoNewline -ForegroundColor Red
            $psi2r = New-Object System.Diagnostics.ProcessStartInfo
            $psi2r.FileName = "cmd.exe"
            $psi2r.Arguments = "/k set OPENCLAW_DISABLE_BONJOUR=1 && `"$NODE`" `"$OPENCLAW_MJS`" gateway --force"
            $psi2r.WorkingDirectory = $WORKDIR
            $psi2r.UseShellExecute = $true
            $psi2r.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
            $script:p2 = [System.Diagnostics.Process]::Start($psi2r)
            Write-Host " pid=$($script:p2.Id)" -ForegroundColor DarkGray
            Write-Host "  │ " -NoNewline -ForegroundColor Red
            Write-Host "[4/4] Waiting for port 18789..." -NoNewline -ForegroundColor Red
            if (Wait-ForPort 18789 45) {
                Write-Host " OK" -ForegroundColor Green
                Write-Host "  │ " -NoNewline -ForegroundColor Red
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Recovered" -ForegroundColor Green
                $mainFailCount = 0
                if ($script:gwToken -and $script:gwToken -ne "no_change") { 
                    cmd /c start "" "http://127.0.0.1:18789/?token=$($script:gwToken)" 2>$null
                }
            } else { 
                Write-Host " FAILED" -ForegroundColor Red
                Write-Host "  │ " -NoNewline -ForegroundColor Red
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Restart failed!" -ForegroundColor Red
            }
            Write-Host "  └─────────────────────────────────────────────────" -ForegroundColor Red
            Write-Host ""
        }
    }
    
    # Main Gateway crash restart (also triggered by fast crash detection outside the 30s check)
    if ($mainFailCount -ge 5 -and ($checkCount % 15 -ne 0)) {
        Write-Host ""
        Write-Host "  ┌─────────────────────────────────────────────────" -ForegroundColor Red
        Write-Host "  │ " -NoNewline -ForegroundColor Red
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] " -NoNewline -ForegroundColor Gray
        Write-Host "MAIN GATEWAY " -NoNewline -ForegroundColor Red
        Write-Host "CRASHED (fast detect)" -ForegroundColor White
        Write-Host "  │ " -NoNewline -ForegroundColor Red
        Write-Host "[1/3] Cleaning locks..." -NoNewline -ForegroundColor Red
        $lockDir = "$env:TEMP\openclaw"
        if (Test-Path $lockDir) {
            Get-ChildItem $lockDir -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        }
        Write-Host " done" -ForegroundColor DarkGray
        Write-Host "  │ " -NoNewline -ForegroundColor Red
        Write-Host "[2/3] Starting new instance..." -NoNewline -ForegroundColor Red
        $psi2r = New-Object System.Diagnostics.ProcessStartInfo
        $psi2r.FileName = "cmd.exe"
        $psi2r.Arguments = "/k set OPENCLAW_DISABLE_BONJOUR=1 && `"$NODE`" `"$OPENCLAW_MJS`" gateway --force"
        $psi2r.WorkingDirectory = $WORKDIR
        $psi2r.UseShellExecute = $true
        $psi2r.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
        $script:p2 = [System.Diagnostics.Process]::Start($psi2r)
        Write-Host " pid=$($script:p2.Id)" -ForegroundColor DarkGray
        Write-Host "  │ " -NoNewline -ForegroundColor Red
        Write-Host "[3/3] Waiting for port 18789..." -NoNewline -ForegroundColor Red
        if (Wait-ForPort 18789 45) {
            Write-Host " OK" -ForegroundColor Green
            Write-Host "  │ " -NoNewline -ForegroundColor Red
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Recovered" -ForegroundColor Green
            $mainFailCount = 0
            if ($script:gwToken -and $script:gwToken -ne "no_change") { 
                cmd /c start "" "http://127.0.0.1:18789/?token=$($script:gwToken)" 2>$null
            }
        } else { 
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host "  │ " -NoNewline -ForegroundColor Red
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Restart failed!" -ForegroundColor Red
        }
        Write-Host "  └─────────────────────────────────────────────────" -ForegroundColor Red
        Write-Host ""
    }
    
    Start-Sleep 2
}

Cleanup


