# OpenClaw Launcher v4
# 浼樺寲绛栫暐锛氶敊寮€鍚姩鍑忓皯 CPU 绔炰簤锛岃缁嗚繘搴﹀弽棣?

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = "OpenClaw Launcher"

$NODE = "D:\Kiro\testopenclaw\node-v22.23.2-win-x64\node.exe"
$OPENCLAW_MJS = "D:\Kiro\testopenclaw\node-v22.23.2-win-x64\node_modules\openclaw\openclaw.mjs"
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

function Show-LaunchProgress {
    param(
        [int]$Percent,
        [string]$Status,
        [switch]$Complete,
        [switch]$Warning
    )

    $Percent = [math]::Max(0, [math]::Min(100, $Percent))
    $activity = "[3/5] Launch all services..."
    $indicator = if ($Complete) { if ($Warning) { "!" } else { "OK" } } else {
        $frames = @("|", "/", "-", "\")
        $frame = $frames[$script:launchSpinnerFrame % $frames.Count]
        $script:launchSpinnerFrame++
        $frame
    }

    # Kiro records carriage-return redraws as separate text fragments and renders
    # Write-Progress at the top of the window. On a real Windows console, reserve
    # the current row and repaint it through the screen-buffer API instead.
    try {
        if ($script:launchProgressConsoleMode -ne $false -and -not [Console]::IsOutputRedirected) {
            $width = [Console]::WindowWidth
            if ($width -lt 60) { throw "Console is too narrow for an inline progress row" }

            $barWidth = [math]::Min(30, [math]::Max(10, $width - 56))
            $filled = [int][math]::Round(($Percent / 100) * $barWidth)
            $bar = ("█" * $filled) + ("." * ($barWidth - $filled))
            $prefix = "[3/5] Launch: [$bar] $Percent% $indicator "
            $maxStatusLength = [math]::Max(0, $width - 1 - $prefix.Length)
            $shortStatus = [string]$Status
            if ($shortStatus.Length -gt $maxStatusLength) {
                $shortStatus = if ($maxStatusLength -gt 3) {
                    $shortStatus.Substring(0, $maxStatusLength - 3) + "..."
                } else {
                    $shortStatus.Substring(0, $maxStatusLength)
                }
            }
            $line = ($prefix + $shortStatus)
            if ($line.Length -gt $width - 1) { $line = $line.Substring(0, $width - 1) }
            $line = $line.PadRight($width - 1)

            if (-not $script:launchProgressConsoleActive) {
                $script:launchProgressConsoleRow = [Console]::CursorTop
                [Console]::Write($line)
                $script:launchProgressConsoleActive = $true
            } else {
                $restoreLeft = [Console]::CursorLeft
                $restoreTop = [Console]::CursorTop
                [Console]::SetCursorPosition(0, $script:launchProgressConsoleRow)
                [Console]::Write($line)
                if ($Complete) {
                    $nextRow = [math]::Min($script:launchProgressConsoleRow + 1, [Console]::BufferHeight - 1)
                    [Console]::SetCursorPosition(0, $nextRow)
                    $script:launchProgressConsoleActive = $false
                } else {
                    [Console]::SetCursorPosition($restoreLeft, $restoreTop)
                }
            }

            if ($Complete -and $script:launchProgressConsoleActive) {
                $nextRow = [math]::Min($script:launchProgressConsoleRow + 1, [Console]::BufferHeight - 1)
                [Console]::SetCursorPosition(0, $nextRow)
                $script:launchProgressConsoleActive = $false
            }
            return
        }
    } catch {
        # Fall through once to durable text-only status when the host exposes no
        # Windows console screen buffer (for example, redirected output).
        $script:launchProgressConsoleMode = $false
        $script:launchProgressConsoleActive = $false
    }

    if (-not $script:launchProgressStarted) {
        Write-Host "$activity starting"
        $script:launchProgressStarted = $true
    }
    if ($Complete) {
        $bar = "█" * 30
        Write-Host "$activity [$bar] $Percent% $indicator $Status"
        $script:launchProgressStarted = $false
    }
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

# Sub-agent gateways expose a lightweight, unauthenticated liveness endpoint.
# Do not use `openclaw --profile ... health` here: OPENCLAW_GATEWAY_PORT can
# redirect it to the main gateway, and auth.mode=none still requires a device
# identity for WebSocket RPC in OpenClaw 2026.5.7.
function Test-SubAgentHealth($port) {
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2 -ErrorAction Stop
        return ($health.ok -eq $true -and $health.status -in @("live", "healthy"))
    } catch {
        return $false
    }
}

function Wait-ForSubAgentHealth($port, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-SubAgentHealth $port) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Test-OpenClawConfig {
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $NODE
        $psi.Arguments = "`"$OPENCLAW_MJS`" config validate"
        $psi.WorkingDirectory = $WORKDIR
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(20000)) {
            $proc.Kill()
            $proc.WaitForExit(2000) | Out-Null
            return [pscustomobject]@{ Ok = $false; Message = "config validation timed out" }
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        $message = if ($stderr) { $stderr } else { $stdout }
        return [pscustomobject]@{ Ok = ($proc.ExitCode -eq 0); Message = $message }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message }
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Test-OpenClawReady($profile = "", $requireChannels = $false) {
    $proc = $null
    try {
        $profileArgs = if ($profile) { "--profile `"$profile`" " } else { "" }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $NODE
        $psi.Arguments = "`"$OPENCLAW_MJS`" ${profileArgs}health --json"
        $psi.WorkingDirectory = $WORKDIR
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(12000)) {
            $proc.Kill()
            $proc.WaitForExit(2000) | Out-Null
            return $false
        }
        $output = $stdoutTask.GetAwaiter().GetResult().Trim()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ($proc.ExitCode -ne 0) { return $false }
        $jsonStart = $output.IndexOf('{')
        if ($jsonStart -gt 0) { $output = $output.Substring($jsonStart) }
        $health = $output | ConvertFrom-Json
        if (-not $health.ok) { return $false }
        if ($requireChannels -and $health.channels) {
            foreach ($channel in $health.channels.PSObject.Properties) {
                $status = $channel.Value
                if ($status.enabled -and $status.configured -and -not $status.running) { return $false }
            }
        }
        return $true
    } catch {
        return $false
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Wait-ForOpenClawReady($profile = "", $timeoutSec = 60, $requireChannels = $false) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-OpenClawReady $profile $requireChannels) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

function Start-MainGateway {
    # Start node.exe itself in its own visible console. Do not use a cmd.exe
    # wrapper: the watchdog must retain the actual Gateway process PID.
    $previousDisableBonjour = $env:OPENCLAW_DISABLE_BONJOUR
    $env:OPENCLAW_DISABLE_BONJOUR = "1"
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $NODE
        $psi.Arguments = "`"$OPENCLAW_MJS`" gateway --force"
        $psi.WorkingDirectory = $WORKDIR
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
        return [System.Diagnostics.Process]::Start($psi)
    } finally {
        if ($null -eq $previousDisableBonjour) {
            Remove-Item Env:OPENCLAW_DISABLE_BONJOUR -ErrorAction SilentlyContinue
        } else {
            $env:OPENCLAW_DISABLE_BONJOUR = $previousDisableBonjour
        }
    }
}

function Start-SubAgentGateway($agent, [switch]$Background) {
    # Keep the tracked process as node.exe itself. A cmd.exe wrapper can exit
    # independently and previously made the watchdog report a false DOWN state.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $NODE
    $psi.Arguments = "`"$OPENCLAW_MJS`" --profile `"$($agent.profile)`" gateway --force"
    $psi.WorkingDirectory = $WORKDIR
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["OPENCLAW_DISABLE_BONJOUR"] = "1"
    $process = [System.Diagnostics.Process]::Start($psi)

    # Spread only initial profile starts. The dynamic agent list remains the
    # source of truth; recovery restarts are not intentionally delayed.
    if (-not $Background -and $script:subAgentStartStaggerMs -gt 0) {
        Start-Sleep -Milliseconds $script:subAgentStartStaggerMs
    }
    return $process
}

function Stop-SubAgentProcessTree($process) {
    try {
        if ($process -and -not $process.HasExited) {
            cmd /c "taskkill /F /T /PID $($process.Id) >nul 2>&1"
            return $true
        }
    } catch {}
    return $false
}

function Get-KiroProbeConfig {
    try {
        $cfg = Get-Content $OPENCLAW_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
        $availableModels = @(
            $cfg.agents.defaults.models.PSObject.Properties | ForEach-Object { $_.Name }
        )
        $mainAgent = @($cfg.agents.list | Where-Object { $_.id -eq "main" }) | Select-Object -First 1
        $candidates = @($mainAgent.model, $cfg.agents.defaults.model.primary)
        $modelRef = $null
        foreach ($candidate in $candidates) {
            if ($candidate -and ($availableModels.Count -eq 0 -or $availableModels -contains [string]$candidate)) {
                $modelRef = [string]$candidate
                break
            }
        }
        if (-not $modelRef -and $availableModels.Count -gt 0) { $modelRef = [string]$availableModels[0] }
        if (-not $modelRef) { throw "No probe model is configured" }

        $modelParts = $modelRef -split '/', 2
        if ($modelParts.Count -eq 2) {
            $providerId = $modelParts[0]
            $modelId = $modelParts[1]
        } else {
            $providerId = @($cfg.models.providers.PSObject.Properties | ForEach-Object { $_.Name })[0]
            $modelId = $modelRef
        }
        $providerProperty = $cfg.models.providers.PSObject.Properties |
            Where-Object { $_.Name -eq $providerId } | Select-Object -First 1
        if (-not $providerProperty) { throw "Provider '$providerId' is not configured" }
        $provider = $providerProperty.Value
        $baseUrl = ([string]$provider.baseUrl).TrimEnd('/')
        if (-not $baseUrl) { throw "Provider '$providerId' has no baseUrl" }

        return [pscustomobject]@{
            Model = $modelId
            Uri = "$baseUrl/chat/completions"
            ApiKey = [string]$provider.apiKey
        }
    } catch {
        Write-Host "  [WARN] Kiro probe config unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
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
    
    # Stop both initial windowed cmd wrappers and the current background Node roots.
    $subAgentProcesses = @()
    if ($script:subCmdProcs) { $subAgentProcesses += @($script:subCmdProcs) }
    if ($script:subAgentStates) {
        $subAgentProcesses += @($script:subAgentStates.Values | ForEach-Object { $_.Process })
    }
    $seenSubAgentPids = @{}
    foreach ($proc in $subAgentProcesses) {
        try {
            if ($proc -and -not $proc.HasExited -and -not $seenSubAgentPids.ContainsKey($proc.Id)) {
                $seenSubAgentPids[$proc.Id] = $true
                Stop-SubAgentProcessTree $proc | Out-Null
            }
        } catch {}
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
function Get-CommandOutputOrFallback {
    param(
        [string]$FilePath,
        [string[]]$CommandArgs,
        [string]$Fallback = "N/A",
        [switch]$IncludeStdErr
    )

    try {
        if ($IncludeStdErr) {
            $output = & $FilePath @CommandArgs 2>&1
        } else {
            $output = & $FilePath @CommandArgs 2>$null
        }
        $exitCode = $LASTEXITCODE
        $text = ($output | Out-String).Trim()
        # Version probes are informational; never leak a failed probe as the
        # launcher process exit code.
        $global:LASTEXITCODE = 0
        if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
            return $Fallback
        }
        return $text
    } catch {
        $global:LASTEXITCODE = 0
        return $Fallback
    }
}

$nodeVer = Get-CommandOutputOrFallback -FilePath $NODE -CommandArgs @("--version")
$npmVer = Get-CommandOutputOrFallback -FilePath $NODE -CommandArgs @("-e", "console.log(require('child_process').execSync('npm -v').toString().trim())")
$pythonVer = (Get-CommandOutputOrFallback -FilePath "python" -CommandArgs @("-V") -IncludeStdErr) -replace '^Python\s+', ''
$nextVer = Get-CommandOutputOrFallback -FilePath $NODE -CommandArgs @("-e", "console.log(require('D:/Kiro/testopenclaw/OpenClaw-bot-review/node_modules/next/package.json').version)")
$openclawVer = Get-CommandOutputOrFallback -FilePath $NODE -CommandArgs @("-e", "console.log(require('D:/Kiro/testopenclaw/node-v22.23.2-win-x64/node_modules/openclaw/package.json').version)")
$mcporterVer = Get-CommandOutputOrFallback -FilePath $NODE -CommandArgs @("-e", "try{console.log(require('D:/Kiro/testopenclaw/node-v22.23.2-win-x64/node_modules/mcporter/package.json').version)}catch(e){console.log('N/A')}")
$global:LASTEXITCODE = 0

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

$configValidation = Test-OpenClawConfig
if (-not $configValidation.Ok) {
    Write-Host " failed" -ForegroundColor Red
    Write-Host "  OpenClaw config validation failed before cleanup:" -ForegroundColor Red
    $validationMessage = [string]$configValidation.Message
    if ($validationMessage.Length -gt 600) { $validationMessage = $validationMessage.Substring(0, 600) + "..." }
    Write-Host "  $validationMessage" -ForegroundColor Yellow
    exit 1
}

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
    Write-Host " failed" -ForegroundColor Red
    Write-Host "  openclaw.json could not be loaded: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Fix the configuration before starting; no hard-coded agent fallback will be used." -ForegroundColor Yellow
    exit 1
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
$script:launchSpinnerFrame = 0
$script:launchProgressLastLength = 0
Show-LaunchProgress 0 "Synchronizing model metadata..."

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
Show-LaunchProgress 12 "Model metadata synchronized ($modelCount models)..."

# Always read token from config (needed for auth.mode=token)
if (-not $script:gwToken -or $script:gwToken -eq "no_change") {
    try {
        $cfg = Get-Content $OPENCLAW_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:gwToken = $cfg.gateway.auth.token
    } catch {}
}

# Start the real Node process directly so readiness and crash detection do not
# depend on a transient cmd.exe wrapper.
$script:p2 = Start-MainGateway

# Gate sub-agent startup on core RPC readiness. Channel authentication is observed
# separately so a slow external network cannot block otherwise healthy gateways.
$script:mainReady = $false
$mainPortReady = $false
$mainPortStart = Get-Date
$mainPortDeadline = $mainPortStart.AddSeconds(45)
while ((Get-Date) -lt $mainPortDeadline -and -not $mainPortReady) {
    $elapsedPercent = [math]::Min(15, [math]::Floor((((Get-Date) - $mainPortStart).TotalSeconds / 45) * 15))
    Show-LaunchProgress (15 + $elapsedPercent) "Waiting for Main Gateway port..."
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", 18789)
        $tcp.Close()
        $mainPortReady = $true
    } catch { Start-Sleep -Milliseconds 300 }
}
if ($mainPortReady) {
    $rpcDeadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $rpcDeadline -and -not $script:mainReady) {
        Show-LaunchProgress 32 "Waiting for Main Gateway RPC..."
        $script:mainReady = Test-OpenClawReady "" $false
        if (-not $script:mainReady) { Start-Sleep -Milliseconds 500 }
    }
}
if ($script:mainReady) {
    # Prime the Gateway's model registry while the existing 20-second stability
    # window is already in progress. The CLI resolves its authentication from the
    # dynamic main configuration; no agent, model, or port list is hard-coded.
    $modelPrewarmJob = $null
    try {
        $modelPrewarmJob = Start-Job -ScriptBlock {
            param($nodeExe, $openclawMjs)
            try {
                & $nodeExe $openclawMjs gateway call models.list --json --timeout 12000 2>$null | Out-Null
            } catch {}
        } -ArgumentList $NODE, $OPENCLAW_MJS
    } catch {}

    $channelStatus = if (Test-OpenClawReady "" $true) { "Main Gateway RPC ready" } else { "Main RPC ready; channels pending" }
    $stabilizeDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $stabilizeDeadline) {
        $remaining = [math]::Ceiling(($stabilizeDeadline - (Get-Date)).TotalSeconds)
        $percent = 50 + [math]::Floor(((20 - $remaining) / 20) * 10)
        $prewarmStatus = if ($modelPrewarmJob -and $modelPrewarmJob.State -eq "Running") { "model catalog warming" } else { "model catalog warmed" }
        Show-LaunchProgress $percent "$channelStatus; $prewarmStatus; stabilizing (${remaining}s)..."
        Start-Sleep -Milliseconds 500
    }

    # The warm-up is bounded to 12 seconds. Do not wait beyond the existing
    # stability period or leave completed PowerShell jobs in the launcher.
    if ($modelPrewarmJob -and $modelPrewarmJob.State -in @("Completed", "Failed", "Stopped")) {
        Receive-Job $modelPrewarmJob -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $modelPrewarmJob -Force -ErrorAction SilentlyContinue
    }
} else {
    Show-LaunchProgress 60 "Main Gateway readiness timed out..."
}

# Start all sub-agent gateways first, then check their HTTP liveness in parallel
# under one shared deadline. This avoids four serial 45-second RPC timeouts.
$script:subCmdProcs = @()
# Do not start every profile at the same instant: each one loads plugins and
# model configuration. This is independent of the number of configured agents.
$script:subAgentStartStaggerMs = 2000
$script:subAgentStates = @{}
$pendingSubAgentIds = @{}
$subAgentTotal = $subAgents.Count
$subAgentStarted = 0
foreach ($agent in $subAgents) {
    $subAgentStarted++
    Show-LaunchProgress 62 "Starting $($agent.id) ($subAgentStarted/$subAgentTotal)..."
    $port = $script:agentPorts[$agent.id]
    $proc = $null
    if ($script:mainReady) {
        try {
            $proc = Start-SubAgentGateway $agent
            if ($proc) { $script:subCmdProcs += $proc }
        } catch {}
    }
    $script:subAgentStates[$agent.id] = [pscustomobject]@{
        Agent = $agent
        Port = $port
        Process = $proc
        Background = $false
        FailCount = 0
        LastRestart = (Get-Date)
        WasDown = $true
    }
    $pendingSubAgentIds[$agent.id] = $true
}

$subAgentDeadline = (Get-Date).AddSeconds(45)
while ($pendingSubAgentIds.Count -gt 0 -and (Get-Date) -lt $subAgentDeadline) {
    foreach ($agent in $subAgents) {
        if (-not $pendingSubAgentIds.ContainsKey($agent.id)) { continue }
        $state = $script:subAgentStates[$agent.id]
        if ($state.Process -and (Test-SubAgentHealth $state.Port)) {
            $state.WasDown = $false
            $pendingSubAgentIds.Remove($agent.id)
            $readyCount = $subAgentTotal - $pendingSubAgentIds.Count
            $percent = 65 + [math]::Floor(($readyCount / [math]::Max(1, $subAgentTotal)) * 20)
            Show-LaunchProgress $percent "$($agent.id) ready ($readyCount/$subAgentTotal)..."
        }
    }
    if ($pendingSubAgentIds.Count -gt 0) {
        $readyCount = $subAgentTotal - $pendingSubAgentIds.Count
        Show-LaunchProgress (65 + [math]::Floor(($readyCount / [math]::Max(1, $subAgentTotal)) * 20)) "Waiting for sub-agent health ($readyCount/$subAgentTotal)..."
        Start-Sleep -Milliseconds 500
    }
}
foreach ($agent in $subAgents) {
    if ($pendingSubAgentIds.ContainsKey($agent.id)) {
        Show-LaunchProgress 85 "$($agent.id) did not report ready..."
    }
}

Show-LaunchProgress 86 "Starting Multi-Agent Dashboard..."
# Multi-Agent + Bot Review (lightweight)
$psiMA = New-Object System.Diagnostics.ProcessStartInfo
$psiMA.FileName = $NODE
$psiMA.Arguments = "`"$env:USERPROFILE\.openclaw\workspace\dashboard-server.cjs`""
$psiMA.WorkingDirectory = "$env:USERPROFILE\.openclaw\workspace"
$psiMA.UseShellExecute = $false
$psiMA.CreateNoWindow = $true
$script:pMultiAgent = [System.Diagnostics.Process]::Start($psiMA)

Show-LaunchProgress 89 "Starting Bot Review..."
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
    Show-LaunchProgress 92 "Starting $($ws.name)..."
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

Show-LaunchProgress 96 "Starting mcporter daemon..."
# mcporter daemon
try {
    $daemonStatus = cmd /c "mcporter daemon status 2>&1"
    if ($daemonStatus -notmatch "pid \d+") {
        cmd /c "mcporter daemon start 2>nul" | Out-Null
    }
} catch {}

$launchReadinessFailures = (-not $script:mainReady) -or @(
    $script:subAgentStates.Values | Where-Object { $_.WasDown }
).Count -gt 0
if ($launchReadinessFailures) {
    Show-LaunchProgress 100 "$modelCount models, launch completed with readiness failures ($(Elapsed $t0))" -Complete -Warning
} else {
    Show-LaunchProgress 100 "$modelCount models, all gateways RPC-ready ($(Elapsed $t0))" -Complete
}
$script:perfStats["launch"] = (Get-Date) - $t0

# ============================================
# [4/6] Wait for all services (with retry for Main Gateway)
# ============================================
$t0 = Get-Date
Write-Host "[4/5] Waiting for services..."

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

$deadline = (Get-Date).AddSeconds(60)
$pendingPorts = [System.Collections.Generic.List[int]]::new()
foreach ($p in $allPorts) { $pendingPorts.Add($p) }
$mainRetries = 0
$maxNameLen = ($portNames.Values | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum

while ($pendingPorts.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $readyPorts = @()
    foreach ($port in $pendingPorts) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $port)
            $tcp.Close()
            $readyPorts += $port
            $name = $portNames[$port]
            $pad = " " * ($maxNameLen - $name.Length)
            Write-Host "  [OK] $name$pad  :$port" -ForegroundColor Green
        } catch {}
    }
    foreach ($port in $readyPorts) { $pendingPorts.Remove($port) | Out-Null }
    
    # Main Gateway crash detection + auto-restart
    if ($pendingPorts.Contains(18789) -and $script:p2.HasExited -and $mainRetries -lt 3) {
        $mainRetries++
        $retryStatus = "Restarting Main Gateway (retry $mainRetries/3)"
        # Include the latest stability error in the same status line when available.
        $stabFile = Get-ChildItem "C:\Users\zhuyulin\.openclaw\logs\stability" -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($stabFile) {
            try {
                $stabData = Get-Content $stabFile.FullName -Raw | ConvertFrom-Json
                $errMsg = [string]$stabData.error.message
                if ($errMsg) { $retryStatus += ": " + $errMsg.Substring(0, [Math]::Min(80, $errMsg.Length)) }
            } catch {}
        }
        Write-Host "  [RETRY $mainRetries/3] $retryStatus" -ForegroundColor Yellow
        # Clean locks and restart
        Get-ChildItem "$env:TEMP\openclaw" -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        $script:p2 = Start-MainGateway
    }
    
    if ($pendingPorts.Count -gt 0) { Start-Sleep -Milliseconds 500 }
}

if ($pendingPorts.Count -gt 0) {
    foreach ($port in $pendingPorts) {
        Write-Host "  [FAIL] $($portNames[$port]) :$port" -ForegroundColor Red
    }
}
$script:perfStats["wait"] = (Get-Date) - $t0

# ============================================
# Warm-up: trigger model-resolution + auth cache population
# This ensures the first user interaction is fast (avoids 14-18s cold start)
if (-not $pendingPorts.Contains(18789)) {
    Write-Host "  [WARMUP] Triggering model cache..." -NoNewline -ForegroundColor DarkGray
    $warmupProbe = Get-KiroProbeConfig
    if ($warmupProbe) {
        $warmupBody = @{
            model = $warmupProbe.Model
            messages = @(@{ role = "user"; content = "ping" })
            max_tokens = 1
        } | ConvertTo-Json -Depth 4 -Compress
        $warmupHeaders = @{ "Content-Type" = "application/json" }
        if ($warmupProbe.ApiKey) { $warmupHeaders["Authorization"] = "Bearer $($warmupProbe.ApiKey)" }
        # Fire-and-forget via background job (don't block startup)
        Start-Job -ScriptBlock {
            param($uri, $body, $headers)
            try {
                Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body -TimeoutSec 30 -ErrorAction Stop | Out-Null
            } catch {}
        } -ArgumentList $warmupProbe.Uri, $warmupBody, $warmupHeaders | Out-Null
        Write-Host " queued ($($warmupProbe.Model))" -ForegroundColor DarkGray
    } else {
        Write-Host " skipped" -ForegroundColor Yellow
    }
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
if ($pendingPorts.Count -eq 0) {
    Write-Host "  All services running! (${totalSec}s)" -ForegroundColor Green
} else {
    Write-Host "  Startup completed with $($pendingPorts.Count) service failure(s) (${totalSec}s)" -ForegroundColor Yellow
}
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
        
        # Check real Kiro API upstream less frequently than local health checks.
        # A healthy local gateway is never restarted solely because an upstream request failed.
        if ($kiroOk -and $checkCount % 150 -eq 0) {
            $probe = Get-KiroProbeConfig
            if ($probe) {
                try {
                    $body = @{
                        model = $probe.Model
                        messages = @(@{ role = "user"; content = "ping" })
                        max_tokens = 1
                    } | ConvertTo-Json -Depth 4 -Compress
                    $headers = @{ "Content-Type" = "application/json" }
                    if ($probe.ApiKey) { $headers["Authorization"] = "Bearer $($probe.ApiKey)" }
                    Invoke-RestMethod -Uri $probe.Uri -Method POST -Headers $headers -Body $body -TimeoutSec 30 -ErrorAction Stop | Out-Null
                    $upstreamFailCount = 0
                    if (-not $lastUpstreamOk) {
                        Write-Host "  ┌─────────────────────────────────────────────────" -ForegroundColor Green
                        Write-Host "  │ [$(Get-Date -Format 'HH:mm:ss')] Kiro API recovered ($($probe.Model))" -ForegroundColor Green
                        Write-Host "  └─────────────────────────────────────────────────" -ForegroundColor Green
                        Write-Host ""
                    }
                    $lastUpstreamOk = $true
                } catch {
                    $probeError = $_
                    $statusCode = 0
                    try {
                        if ($probeError.Exception.Response) {
                            $statusCode = [int]$probeError.Exception.Response.StatusCode
                        }
                    } catch {}

                    $isConnectivityFailure = ($statusCode -eq 0 -or $statusCode -ge 500)
                    if ($isConnectivityFailure) { $upstreamFailCount++ } else { $upstreamFailCount = 0 }

                    if ($statusCode -eq 400) {
                        $failureType = "REQUEST/MODEL INVALID"
                    } elseif ($statusCode -eq 401 -or $statusCode -eq 403) {
                        $failureType = "AUTHENTICATION FAILED"
                    } elseif ($statusCode -eq 429) {
                        $failureType = "RATE LIMITED"
                    } elseif ($statusCode -ge 500) {
                        $failureType = "UPSTREAM HTTP $statusCode"
                    } elseif ($statusCode -gt 0) {
                        $failureType = "HTTP $statusCode"
                    } else {
                        $failureType = "NETWORK/TIMEOUT"
                    }

                    $detail = [string]$probeError.Exception.Message
                    if ($detail.Length -gt 140) { $detail = $detail.Substring(0, 140) + "..." }
                    Write-Host ""
                    Write-Host "  ┌─────────────────────────────────────────────────" -ForegroundColor DarkYellow
                    Write-Host "  │ [$(Get-Date -Format 'HH:mm:ss')] KIRO API: $failureType" -ForegroundColor Yellow
                    Write-Host "  │ Model: $($probe.Model)" -ForegroundColor Gray
                    Write-Host "  │ $detail" -ForegroundColor DarkGray
                    if ($statusCode -eq 401 -or $statusCode -eq 403) {
                        Write-Host "  │ Gateway internal token refresh remains active; healthy process not restarted." -ForegroundColor Magenta
                    } elseif ($isConnectivityFailure) {
                        Write-Host "  │ Upstream failure count: $upstreamFailCount; healthy local gateway not restarted." -ForegroundColor Gray
                    }
                    Write-Host "  └─────────────────────────────────────────────────" -ForegroundColor DarkYellow
                    Write-Host ""
                    $lastUpstreamOk = $false
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
            $script:p2 = Start-MainGateway
            Write-Host " pid=$($script:p2.Id)" -ForegroundColor DarkGray
            Write-Host "  │ " -NoNewline -ForegroundColor Red
            Write-Host "[4/4] Waiting for core RPC readiness..." -NoNewline -ForegroundColor Red
            if (Wait-ForOpenClawReady "" 90 $false) {
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

        # Sub-agent auto-restart is intentionally not performed here. Sub-agent
        # state is still tracked so Cleanup can stop those processes on exit,
        # but a stopped sub-agent is left stopped until the launcher is rerun.

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
        $script:p2 = Start-MainGateway
        Write-Host " pid=$($script:p2.Id)" -ForegroundColor DarkGray
        Write-Host "  │ " -NoNewline -ForegroundColor Red
        Write-Host "[3/3] Waiting for core RPC readiness..." -NoNewline -ForegroundColor Red
        if (Wait-ForOpenClawReady "" 90 $false) {
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
$global:LASTEXITCODE = 0
exit 0


