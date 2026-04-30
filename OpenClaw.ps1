# OpenClaw Launcher v3
# 优化策略：最大化并行，减少串行等待

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = "OpenClaw Launcher"

$NODE = "D:\Kiro\testopenclaw\node-v22.22.1-win-x64\node.exe"
$OPENCLAW_MJS = "D:\Kiro\testopenclaw\node-v22.22.1-win-x64\node_modules\openclaw\openclaw.mjs"
$WORKDIR = "D:\Kiro\testopenclaw"
$OPENCLAW_CONFIG = "C:\Users\zhuyulin\.openclaw\openclaw.json"

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
        } catch { Start-Sleep -Milliseconds 200 }
    }
    return $false
}

function Cleanup {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  Stopping all services..." -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    
    if ($script:p1 -and !$script:p1.HasExited) { $script:p1.Kill() }
    if ($script:p2 -and !$script:p2.HasExited) { $script:p2.Kill() }
    if ($script:pMultiAgent -and !$script:pMultiAgent.HasExited) { $script:pMultiAgent.Kill() }
    if ($script:pBot -and !$script:pBot.HasExited) { $script:pBot.Kill() }
    
    if ($script:subCmdProcs) {
        foreach ($proc in $script:subCmdProcs) {
            if ($proc -and !$proc.HasExited) {
                cmd /c "taskkill /F /T /PID $($proc.Id) >nul 2>&1"
            }
        }
    }
    
    $targetPorts = @(18789, 8899, 8900, 9000) + ($script:agentPorts.Values | Where-Object { $_ })
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
    
    Write-Host "  All services stopped." -ForegroundColor Green
}

# ============================================
# 版本信息
# ============================================
$nodeVer = (& $NODE --version 2>$null).Trim()
$pythonVer = (python -V 2>&1 | Out-String).Trim() -replace '^Python\s+', ''
$nextVer = (& $NODE -e "console.log(require('D:/Kiro/testopenclaw/OpenClaw-bot-review/node_modules/next/package.json').version)" 2>$null).Trim()
$openclawVer = (& $NODE -e "console.log(require('D:/Kiro/testopenclaw/node-v22.22.1-win-x64/node_modules/openclaw/package.json').version)" 2>$null).Trim()

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OpenClaw Launcher" -ForegroundColor White
Write-Host "  Node $nodeVer / Python $pythonVer" -ForegroundColor Gray
Write-Host "  Next.js $nextVer / OpenClaw $openclawVer" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan

$launchStart = Get-Date

# ============================================
# [1/6] 读取配置 + 清理残留（并行）
# ============================================
$t0 = Get-Date
Write-Host ""
Write-Host "[1/6] Config + Cleanup..." -NoNewline

# 读取配置
$subAgents = @()
$script:agentPorts = @{}

try {
    $config = Get-Content $OPENCLAW_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($agent in $config.agents.list) {
        if ($agent.id -ne "main") {
            $profileName = $agent.id -replace '-agent$', ''
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

# 清理残留进程
$targetPorts = @(18789, 8899, 8900, 9000) + ($script:agentPorts.Values | Where-Object { $_ })
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
# [2/6] 启动 Kiro Gateway + Multi-Agent + Bot Review（并行）
# Multi-Agent 和 Bot Review 不依赖 Kiro，可以同时启动
# ============================================
$t0 = Get-Date
Write-Host "[2/6] Kiro + Multi-Agent + Bot Review..." -NoNewline

# Kiro Gateway
$psi1 = New-Object System.Diagnostics.ProcessStartInfo
$psi1.FileName = "python"
$psi1.Arguments = "main.py --port 9000"
$psi1.WorkingDirectory = "D:\Kiro\testopenclaw\kiro-gateway"
$psi1.UseShellExecute = $false
$psi1.CreateNoWindow = $true
$script:p1 = [System.Diagnostics.Process]::Start($psi1)

# Multi-Agent（8899）- 不依赖 Kiro，立即启动
$psiMA = New-Object System.Diagnostics.ProcessStartInfo
$psiMA.FileName = $NODE
$psiMA.Arguments = "`"$env:USERPROFILE\.openclaw\workspace\dashboard-server.js`""
$psiMA.WorkingDirectory = "$env:USERPROFILE\.openclaw\workspace"
$psiMA.UseShellExecute = $false
$psiMA.CreateNoWindow = $true
$script:pMultiAgent = [System.Diagnostics.Process]::Start($psiMA)

# Bot Review（8900）- 不依赖 Kiro，立即启动
$psiBot = New-Object System.Diagnostics.ProcessStartInfo
$psiBot.FileName = "cmd.exe"
$psiBot.Arguments = "/c set PORT=8900&& set OPENCLAW_HOME=$env:USERPROFILE\.openclaw&& set NODE_ENV=production&& `"$NODE`" `"D:\Kiro\testopenclaw\OpenClaw-bot-review\.next\standalone\server.js`""
$psiBot.WorkingDirectory = "D:\Kiro\testopenclaw\OpenClaw-bot-review\.next\standalone"
$psiBot.UseShellExecute = $false
$psiBot.CreateNoWindow = $true
$script:pBot = [System.Diagnostics.Process]::Start($psiBot)

Write-Host " started" -ForegroundColor Yellow -NoNewline

# 等待 Kiro Gateway 就绪（Multi-Agent 和 Bot Review 在后台启动中）
if (Wait-ForPort 9000 30) {
    Write-Host " Kiro ready ($(Elapsed $t0))" -ForegroundColor Green
} else {
    Write-Host " Kiro timeout! ($(Elapsed $t0))" -ForegroundColor Red
}
$script:perfStats["kiro+services"] = (Get-Date) - $t0

# ============================================
# [3/6] 同步模型 + 启动 Main Gateway + Sub-Agents（全部并行）
# Main Gateway 和 Sub-Agents 不需要等 sync 完成
# ============================================
$t0 = Get-Date
Write-Host "[3/6] Sync + Main + Sub-Agents..." -NoNewline

# 启动 Main Gateway（后台）
$psi2 = New-Object System.Diagnostics.ProcessStartInfo
$psi2.FileName = "cmd.exe"
$psi2.Arguments = "/c set OPENCLAW_DISABLE_BONJOUR=1 && `"$NODE`" `"$OPENCLAW_MJS`" gateway --force"
$psi2.WorkingDirectory = $WORKDIR
$psi2.UseShellExecute = $true
$psi2.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
$script:p2 = [System.Diagnostics.Process]::Start($psi2)

# 启动 Sub-Agents（后台）
$script:subCmdProcs = @()
foreach ($agent in $subAgents) {
    $cmdArgs = "/k title $($agent.id) && set OPENCLAW_DISABLE_BONJOUR=1 && `"$NODE`" `"$OPENCLAW_MJS`" --profile $($agent.profile) gateway --force"
    $proc = Start-Process "cmd.exe" -ArgumentList $cmdArgs -WorkingDirectory $WORKDIR -WindowStyle Minimized -PassThru
    $script:subCmdProcs += $proc
}

# 同步模型（前台，等待完成以获取 token）
try {
    $result = python "D:\Kiro\testopenclaw\sync_models.py" 2>&1
    $lines = @($result)
    if ($lines[0] -match "^OK:(\d+):([^:]+):(.*)$") {
        $script:gwToken = $Matches[3]
        Write-Host " $($Matches[1]) models ($(Elapsed $t0))" -ForegroundColor Green
    } else { 
        Write-Host " sync warning ($(Elapsed $t0))" -ForegroundColor Yellow
    }
} catch { 
    Write-Host " sync failed ($(Elapsed $t0))" -ForegroundColor Red
}
$script:perfStats["sync+launch"] = (Get-Date) - $t0

# ============================================
# [4/6] 等待所有服务就绪
# ============================================
$t0 = Get-Date
Write-Host "[4/6] Waiting..." -NoNewline

# 构建端口和名称映射
$allPorts = @(18789, 8899, 8900)
$portNames = @{ 18789 = "Main Dashboard"; 8899 = "Multi-Agent"; 8900 = "Bot Review" }
foreach ($agent in $subAgents) {
    $port = $script:agentPorts[$agent.id]
    if ($port) {
        $allPorts += $port
        $name = ($agent.id -replace '-agent$', '')
        $portNames[$port] = $name.Substring(0,1).ToUpper() + $name.Substring(1)
    }
}

$deadline = (Get-Date).AddSeconds(30)
$pendingPorts = [System.Collections.Generic.List[int]]::new()
foreach ($p in $allPorts) { $pendingPorts.Add($p) }

Write-Host ""
while ($pendingPorts.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $readyPorts = @()
    foreach ($port in $pendingPorts) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $port)
            $tcp.Close()
            $readyPorts += $port
            Write-Host "  [OK] $($portNames[$port]) ($port)" -ForegroundColor Green
        } catch {}
    }
    foreach ($port in $readyPorts) { $pendingPorts.Remove($port) | Out-Null }
    if ($pendingPorts.Count -gt 0) { Start-Sleep -Milliseconds 200 }
}

if ($pendingPorts.Count -gt 0) {
    Write-Host "  [WARN] Timeout:" -ForegroundColor Yellow
    foreach ($port in $pendingPorts) {
        Write-Host "    - $($portNames[$port]) ($port)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  All ready! ($(Elapsed $t0))" -ForegroundColor Green
}
$script:perfStats["wait"] = (Get-Date) - $t0

# ============================================
# [5/6] 打开浏览器
# ============================================
$t0 = Get-Date
Write-Host "[5/6] Browsers..." -NoNewline

try {
    if ($script:gwToken) {
        cmd /c start "Main Dashboard" "http://127.0.0.1:18789/?token=$($script:gwToken)"
    } else {
        cmd /c start "Main Dashboard" "http://127.0.0.1:18789/"
    }
    Start-Process "http://127.0.0.1:8899/"
    Start-Process "http://127.0.0.1:8900/"
    Write-Host " Done ($(Elapsed $t0))" -ForegroundColor Green
} catch {
    Write-Host " Partial ($(Elapsed $t0))" -ForegroundColor Yellow
}
$script:perfStats["browsers"] = (Get-Date) - $t0

# ============================================
# [6/6] 完成
# ============================================
$totalSec = [math]::Round(((Get-Date) - $launchStart).TotalSeconds, 1)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  All services running! (${totalSec}s)" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

function FmtMs($ms) { if ($ms -lt 1000) { "${ms}ms" } else { "$([math]::Round($ms/1000,2))s" } }

Write-Host "  Init:          $(FmtMs ([int]$script:perfStats['init'].TotalMilliseconds))" -ForegroundColor Gray
Write-Host "  Kiro+Services: $(FmtMs ([int]$script:perfStats['kiro+services'].TotalMilliseconds))" -ForegroundColor Gray
Write-Host "  Sync+Launch:   $(FmtMs ([int]$script:perfStats['sync+launch'].TotalMilliseconds))" -ForegroundColor Gray
Write-Host "  Wait Ready:    $(FmtMs ([int]$script:perfStats['wait'].TotalMilliseconds))" -ForegroundColor Gray
Write-Host "  Browsers:      $(FmtMs ([int]$script:perfStats['browsers'].TotalMilliseconds))" -ForegroundColor Gray
Write-Host ""
Write-Host "  Main Dashboard: http://127.0.0.1:18789/" -ForegroundColor Cyan
Write-Host "  Multi-Agent:    http://127.0.0.1:8899" -ForegroundColor Cyan
Write-Host "  Bot Review:     http://127.0.0.1:8900" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Press any key to stop all services" -ForegroundColor DarkGray
Write-Host ""

# ============================================
# 守护循环
# ============================================
$checkCount = 0
while ($true) {
    if ([Console]::KeyAvailable) { 
        $null = [Console]::ReadKey($true)
        break 
    }
    
    $checkCount++
    if ($checkCount % 15 -eq 0) {
        # 检查 Kiro Gateway
        try { $tcp = New-Object System.Net.Sockets.TcpClient; $tcp.Connect("127.0.0.1", 9000); $tcp.Close() }
        catch {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Kiro Gateway down, restarting..." -ForegroundColor Yellow
            if ($script:p1 -and !$script:p1.HasExited) { $script:p1.Kill(); Start-Sleep -Milliseconds 500 }
            $psi1r = New-Object System.Diagnostics.ProcessStartInfo
            $psi1r.FileName = "python"; $psi1r.Arguments = "main.py --port 9000"
            $psi1r.WorkingDirectory = "D:\Kiro\testopenclaw\kiro-gateway"
            $psi1r.UseShellExecute = $false; $psi1r.CreateNoWindow = $true
            $script:p1 = [System.Diagnostics.Process]::Start($psi1r)
            Start-Sleep -Milliseconds 2000
        }
        
        # 检查 Main Gateway
        try { $tcp = New-Object System.Net.Sockets.TcpClient; $tcp.Connect("127.0.0.1", 18789); $tcp.Close() }
        catch {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Main Gateway down, restarting..." -ForegroundColor Yellow
            if ($script:p2 -and !$script:p2.HasExited) { $script:p2.Kill(); Start-Sleep -Milliseconds 500 }
            $lockDir = "$env:TEMP\openclaw"
            if (Test-Path $lockDir) {
                Get-ChildItem $lockDir -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
            }
            $psi2r = New-Object System.Diagnostics.ProcessStartInfo
            $psi2r.FileName = "cmd.exe"
            $psi2r.Arguments = "/c set OPENCLAW_DISABLE_BONJOUR=1 && `"$NODE`" `"$OPENCLAW_MJS`" gateway --force"
            $psi2r.WorkingDirectory = $WORKDIR
            $psi2r.UseShellExecute = $true
            $psi2r.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
            $script:p2 = [System.Diagnostics.Process]::Start($psi2r)
            if (Wait-ForPort 18789 30) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Main Gateway ready" -ForegroundColor Green
                if ($script:gwToken) { cmd /c start "Main Dashboard" "http://127.0.0.1:18789/?token=$($script:gwToken)" }
            } else { 
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Main Gateway timeout" -ForegroundColor Red 
            }
            $checkCount = 0
        }
    }
    Start-Sleep 2
}

Cleanup
