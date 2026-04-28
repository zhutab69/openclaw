# OpenClaw Launcher - Ultra Optimized Version
# 优化目标：减少启动时间从 70s 到 30s 以内

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = "OpenClaw Launcher (Ultra Optimized)"

$NODE = "D:\Kiro\testopenclaw\node-v22.22.1-win-x64\node.exe"
$OPENCLAW_MJS = "D:\Kiro\testopenclaw\node-v22.22.1-win-x64\node_modules\openclaw\openclaw.mjs"
$WORKDIR = "D:\Kiro\testopenclaw"

$subAgents = @(
    @{ id = "writer-agent"; profile = "writer"; port = 3010 },
    @{ id = "dev-agent";    profile = "dev";    port = 3020 },
    @{ id = "info-agent";   profile = "info";   port = 3030 },
    @{ id = "image-agent";  profile = "image";  port = 3040 }
)

$script:perfStats = @{}

function Elapsed($start) { 
    $ms = [int]((Get-Date)-$start).TotalMilliseconds
    if ($ms -lt 1000) { return "${ms}ms" }
    return "$([math]::Round($ms/1000, 2))s"
}

function Clear-AllPorts {
    $targetPorts = @(3010, 3020, 3030, 3040, 18789, 8899, 8900, 9000)
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
        foreach ($procId in $pidsToKill) { 
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue 
        }
        Start-Sleep -Milliseconds 800  # 减少等待时间
        
        $lockDir = "$env:TEMP\openclaw"
        if (Test-Path $lockDir) {
            Get-ChildItem $lockDir -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        }
        
        return $true
    }
    return $false
}

function Start-MainGateway {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c set OPENCLAW_DISABLE_BONJOUR=1 && `"$NODE`" `"$OPENCLAW_MJS`" gateway --force"
    $psi.WorkingDirectory = $WORKDIR
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
    return [System.Diagnostics.Process]::Start($psi)
}

# 优化的端口检测函数 - 减少轮询间隔
function Wait-ForPort($port, $timeoutSec = 30, $showProgress = $true) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $port)
            $tcp.Close()
            return $true
        } catch {
            if ($showProgress) { Write-Host "." -NoNewline }
            Start-Sleep -Milliseconds 200  # 从 500ms 减少到 200ms
        }
    }
    return $false
}

# 新增：并行端口检测
function Wait-ForPorts($ports, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $pendingPorts = New-Object System.Collections.Generic.List[int]
    foreach ($p in $ports) {
        $pendingPorts.Add($p)
    }
    
    while ($pendingPorts.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $readyPorts = @()
        foreach ($port in $pendingPorts) {
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $tcp.Connect("127.0.0.1", $port)
                $tcp.Close()
                $readyPorts += $port
            } catch {}
        }
        
        foreach ($port in $readyPorts) {
            $pendingPorts.Remove($port) | Out-Null
        }
        
        if ($pendingPorts.Count -gt 0) {
            Start-Sleep -Milliseconds 200
        }
    }
    
    return $pendingPorts.Count -eq 0
}

function Cleanup {
    Write-Host "`n`n========================================" -ForegroundColor Cyan
    Write-Host "  Stopping all services..." -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    
    # 关闭主服务
    if ($script:p1 -and !$script:p1.HasExited) { 
        Write-Host "  Stopping Kiro Gateway (PID $($script:p1.Id))..." -ForegroundColor Gray
        $script:p1.Kill() 
    }
    if ($script:p2 -and !$script:p2.HasExited) { 
        Write-Host "  Stopping Main Gateway (PID $($script:p2.Id))..." -ForegroundColor Gray
        $script:p2.Kill() 
    }
    if ($script:pDash -and !$script:pDash.HasExited) { 
        Write-Host "  Stopping Dashboard (PID $($script:pDash.Id))..." -ForegroundColor Gray
        $script:pDash.Kill() 
    }
    if ($script:pBot -and !$script:pBot.HasExited) { 
        Write-Host "  Stopping Bot Review (PID $($script:pBot.Id))..." -ForegroundColor Gray
        $script:pBot.Kill() 
    }
    
    # 关闭所有子代理（包括子进程）
    if ($script:subCmdProcs) {
        Write-Host "  Stopping Sub-Agents..." -ForegroundColor Gray
        foreach ($proc in $script:subCmdProcs) {
            if ($proc -and !$proc.HasExited) {
                try {
                    Write-Host "    Stopping PID $($proc.Id)..." -ForegroundColor DarkGray
                    # 使用 taskkill /T 杀死进程树（包括子进程）
                    cmd /c "taskkill /F /T /PID $($proc.Id) >nul 2>&1"
                } catch {
                    Write-Host "    Failed to stop PID $($proc.Id): $_" -ForegroundColor Yellow
                }
            }
        }
    }
    
    # 额外清理：通过端口查找并关闭残留进程
    Write-Host "  Cleaning up ports..." -ForegroundColor Gray
    Clear-AllPorts | Out-Null
    
    $lockDir = "$env:TEMP\openclaw"
    if (Test-Path $lockDir) {
        Get-ChildItem $lockDir -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    }
    
    Write-Host "  All services stopped." -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OpenClaw Launcher (Ultra Optimized)" -ForegroundColor White
Write-Host "  Node.js v22.22.1 / Next.js v15.1.6 / OpenClaw 2026.3.13" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$launchStart = Get-Date

# ============================================
# [1/8] 清理残留进程
# ============================================
$t0 = Get-Date
Write-Host "[1/8] Cleaning up old processes..." -NoNewline
if (Clear-AllPorts) { 
    Write-Host " Done! ($(Elapsed $t0))" -ForegroundColor Green 
} else {
    Write-Host " No cleanup needed ($(Elapsed $t0))" -ForegroundColor DarkGray
}
$script:perfStats["cleanup"] = (Get-Date) - $t0

$lockDir = "$env:TEMP\openclaw"
if (Test-Path $lockDir) {
    Get-ChildItem $lockDir -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

# ============================================
# [2/8] 启动 Kiro Gateway (Python) - 异步启动
# ============================================
$t0 = Get-Date
Write-Host "[2/8] Starting Kiro Gateway (port 9000)..." -NoNewline
$psi1 = New-Object System.Diagnostics.ProcessStartInfo
$psi1.FileName = "python"
$psi1.Arguments = "main.py --port 9000"
$psi1.WorkingDirectory = "D:\Kiro\testopenclaw\kiro-gateway"
$psi1.UseShellExecute = $false
$psi1.CreateNoWindow = $true
$script:p1 = [System.Diagnostics.Process]::Start($psi1)
Write-Host " Started PID $($script:p1.Id) ($(Elapsed $t0))" -ForegroundColor Yellow
$script:perfStats["kiro-gateway-start"] = (Get-Date) - $t0

# ============================================
# [3/8] 等待 Kiro Gateway 就绪 + 同步模型（提前）
# ============================================
$t0 = Get-Date
Write-Host "[3/8] Waiting for Kiro Gateway..." -NoNewline
if (Wait-ForPort 9000 30 $true) {
    Write-Host " Ready! ($(Elapsed $t0))" -ForegroundColor Green
    
    # 同步模型
    $t1 = Get-Date
    Write-Host "  Syncing models..." -NoNewline
    try {
        $result = python "D:\Kiro\testopenclaw\sync_models.py" 2>&1
        $lines = @($result)
        if ($lines[0] -match "^OK:(\d+):([^:]+):(.*)$") {
            Write-Host " Synced $($Matches[1]) models ($(Elapsed $t1))" -ForegroundColor Green
            $script:gwToken = $Matches[3]
        } else { 
            Write-Host " Warning: $($lines[0]) ($(Elapsed $t1))" -ForegroundColor Yellow 
        }
    } catch { 
        Write-Host " Failed: $_ ($(Elapsed $t1))" -ForegroundColor Red 
    }
} else {
    Write-Host " Timeout! ($(Elapsed $t0))" -ForegroundColor Red
}
$script:perfStats["kiro-gateway-ready"] = (Get-Date) - $t0

# ============================================
# [4/8] 启动主 Gateway (OpenClaw Main) - Kiro 就绪后启动
# ============================================
$t0 = Get-Date
Write-Host "[4/8] Starting Main Gateway (port 18789)..." -NoNewline
$script:p2 = Start-MainGateway
Write-Host " Started PID $($script:p2.Id) ($(Elapsed $t0))" -ForegroundColor Yellow
$script:perfStats["main-gateway-start"] = (Get-Date) - $t0

# ============================================
# [5/8] 并行启动所有子 Agents - 完全并行
# ============================================
# [5/8] 并行启动所有子 Agents
# ============================================
$t0 = Get-Date
Write-Host "[5/8] Starting Sub-Agents (parallel)..."
$script:subCmdProcs = @()

# 直接启动（不使用 Jobs，确保进程对象被正确保存）
foreach ($agent in $subAgents) {
    $cmdArgs = "/k title $($agent.id) (port $($agent.port)) && set OPENCLAW_DISABLE_BONJOUR=1 && `"$NODE`" `"$OPENCLAW_MJS`" --profile $($agent.profile) gateway --port $($agent.port) --force"
    $proc = Start-Process "cmd.exe" -ArgumentList $cmdArgs -WorkingDirectory $WORKDIR -WindowStyle Minimized -PassThru
    $script:subCmdProcs += $proc
    Write-Host "  [$($agent.id)] PID $($proc.Id) on port $($agent.port)" -ForegroundColor Green
}

Write-Host "  All sub-agents started ($(Elapsed $t0))" -ForegroundColor Green
$script:perfStats["sub-agents-start"] = (Get-Date) - $t0

# ============================================
# [6/8] 启动 Dashboard Server (Node.js) - 并行启动
# ============================================
$t0 = Get-Date
Write-Host "[6/8] Starting Dashboard Server (port 8899)..." -NoNewline
$psiDash = New-Object System.Diagnostics.ProcessStartInfo
$psiDash.FileName = $NODE
$psiDash.Arguments = "`"$env:USERPROFILE\.openclaw\workspace\dashboard-server.js`""
$psiDash.WorkingDirectory = "$env:USERPROFILE\.openclaw\workspace"
$psiDash.UseShellExecute = $false
$psiDash.CreateNoWindow = $true
$script:pDash = [System.Diagnostics.Process]::Start($psiDash)
Write-Host " Started PID $($script:pDash.Id) ($(Elapsed $t0))" -ForegroundColor Yellow
$script:perfStats["dashboard-start"] = (Get-Date) - $t0

# ============================================
# [7/8] 启动 Bot Review (Next.js) - 并行启动
# ============================================
$t0 = Get-Date
Write-Host "[7/8] Starting Bot Review Server (port 8900)..." -NoNewline
$psiBot = New-Object System.Diagnostics.ProcessStartInfo
$psiBot.FileName = "cmd.exe"
$psiBot.Arguments = "/c set PORT=8900&& set OPENCLAW_HOME=$env:USERPROFILE\.openclaw&& set NODE_ENV=production&& `"$NODE`" `"D:\Kiro\testopenclaw\OpenClaw-bot-review\.next\standalone\server.js`""
$psiBot.WorkingDirectory = "D:\Kiro\testopenclaw\OpenClaw-bot-review\.next\standalone"
$psiBot.UseShellExecute = $false
$psiBot.CreateNoWindow = $true
$script:pBot = [System.Diagnostics.Process]::Start($psiBot)
Write-Host " Started PID $($script:pBot.Id) ($(Elapsed $t0))" -ForegroundColor Yellow
$script:perfStats["bot-review-start"] = (Get-Date) - $t0

# ============================================
# [8/8] 等待所有服务就绪 - 并行检测（带详细日志）
# ============================================
$t0 = Get-Date
Write-Host "[8/8] Waiting for all services..." -NoNewline
$allPorts = @(18789, 3010, 3020, 3030, 3040, 8899, 8900)

# 优化：先快速检查一次，大部分情况下服务已经就绪
$quickCheckReady = $true
foreach ($port in $allPorts) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", $port)
        $tcp.Close()
    } catch {
        $quickCheckReady = $false
        break
    }
}

if ($quickCheckReady) {
    Write-Host " All ready! ($(Elapsed $t0))" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  Waiting for services to start..." -ForegroundColor Yellow
    
    $deadline = (Get-Date).AddSeconds(30)
    $pendingPorts = New-Object System.Collections.Generic.List[int]
    foreach ($p in $allPorts) {
        $pendingPorts.Add($p)
    }
    
    $portNames = @{
        18789 = "Main Gateway"
        3010 = "Writer Agent"
        3020 = "Dev Agent"
        3030 = "Info Agent"
        3040 = "Image Agent"
        8899 = "Dashboard"
        8900 = "Bot Review"
    }
    
    while ($pendingPorts.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $readyPorts = @()
        foreach ($port in $pendingPorts) {
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $tcp.Connect("127.0.0.1", $port)
                $tcp.Close()
                $readyPorts += $port
                Write-Host "  [OK] $($portNames[$port]) (port $port) ready" -ForegroundColor Green
            } catch {}
        }
        
        foreach ($port in $readyPorts) {
            $pendingPorts.Remove($port) | Out-Null
        }
        
        if ($pendingPorts.Count -gt 0) {
            Start-Sleep -Milliseconds 200
        }
    }
    
    if ($pendingPorts.Count -gt 0) {
        Write-Host "  [WARN] Timeout waiting for:" -ForegroundColor Yellow
        foreach ($port in $pendingPorts) {
            Write-Host "    - $($portNames[$port]) (port $port)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  All services ready! ($(Elapsed $t0))" -ForegroundColor Green
    }
}

$script:perfStats["wait-ready"] = (Get-Date) - $t0

# ============================================
# 打开浏览器 - 优化版（避免空白页）
# ============================================
$t0 = Get-Date
Write-Host ""
Write-Host "Opening browsers..." -ForegroundColor Yellow

# 直接打开浏览器，不使用 Job（避免空白页问题）
try {
    # 主控制台
    if ($script:gwToken) {
        Start-Process "http://127.0.0.1:18789/?token=$($script:gwToken)"
    } else {
        Start-Process "http://127.0.0.1:18789/"
    }
    Write-Host "  [+] Opened: Main Dashboard (18789)" -ForegroundColor Green
    Start-Sleep -Milliseconds 300
    
    # 多 Agent 监控
    Start-Process "http://127.0.0.1:8899/"
    Write-Host "  [+] Opened: Multi-Agent Hub (8899)" -ForegroundColor Green
    Start-Sleep -Milliseconds 300
    
    # Bot Review
    Start-Process "http://127.0.0.1:8900/"
    Write-Host "  [+] Opened: Bot Review (8900)" -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Failed to open some browsers: $_" -ForegroundColor Yellow
}

$script:perfStats["open-browsers"] = (Get-Date) - $t0

# ============================================
# 启动完成统计
# ============================================
$totalSec = [math]::Round(((Get-Date) - $launchStart).TotalSeconds, 2)
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  [SUCCESS] All services running!" -ForegroundColor Green
Write-Host "  Total startup time: ${totalSec}s" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Performance Breakdown:" -ForegroundColor Yellow

$cleanupMs = [int]$script:perfStats['cleanup'].TotalMilliseconds
$kiroStartMs = [int]$script:perfStats['kiro-gateway-start'].TotalMilliseconds
$kiroReadyMs = [int]$script:perfStats['kiro-gateway-ready'].TotalMilliseconds
$mainStartMs = [int]$script:perfStats['main-gateway-start'].TotalMilliseconds
$subStartMs = [int]$script:perfStats['sub-agents-start'].TotalMilliseconds
$dashStartMs = [int]$script:perfStats['dashboard-start'].TotalMilliseconds
$botStartMs = [int]$script:perfStats['bot-review-start'].TotalMilliseconds
$waitMs = [int]$script:perfStats['wait-ready'].TotalMilliseconds
$browserMs = [int]$script:perfStats['open-browsers'].TotalMilliseconds

function FormatTime($ms) {
    if ($ms -lt 1000) { return "${ms}ms" }
    return "$([math]::Round($ms/1000,2))s"
}

Write-Host "  [1] Cleanup:           $(FormatTime $cleanupMs)" -ForegroundColor Gray
Write-Host "  [2] Kiro Start:        $(FormatTime $kiroStartMs)" -ForegroundColor Gray
Write-Host "  [3] Main Gateway:      $(FormatTime $mainStartMs)" -ForegroundColor Gray
Write-Host "  [4] Sub-Agents:        $(FormatTime $subStartMs)" -ForegroundColor Gray
Write-Host "  [5] Dashboard:         $(FormatTime $dashStartMs)" -ForegroundColor Gray
Write-Host "  [6] Bot Review:        $(FormatTime $botStartMs)" -ForegroundColor Gray
Write-Host "  [7] Kiro Ready+Sync:   $(FormatTime $kiroReadyMs)" -ForegroundColor Gray
Write-Host "  [8] Wait All Ready:    $(FormatTime $waitMs)" -ForegroundColor Gray
Write-Host "  [9] Open Browsers:     $(FormatTime $browserMs)" -ForegroundColor Gray
Write-Host ""
Write-Host "Service URLs:" -ForegroundColor Yellow
Write-Host "  Main Dashboard:     http://127.0.0.1:18789/" -ForegroundColor Cyan
Write-Host "  Multi-Agent Hub:    http://127.0.0.1:8899" -ForegroundColor Cyan
Write-Host "  Bot Review Center:  http://127.0.0.1:8900" -ForegroundColor Cyan
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Monitoring... (press any key to stop)" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================
# 守护循环（优化版）
# ============================================
$checkCount = 0
while ($true) {
    if ([Console]::KeyAvailable) { 
        $null = [Console]::ReadKey($true)
        break 
    }
    
    $checkCount++
    if ($checkCount % 15 -eq 0) {  # 每30秒检查一次（避免误报）
        # 检查 Kiro Gateway
        $kiroOk = $false
        try { 
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", 9000)
            $tcp.Close()
            $kiroOk = $true 
        } catch {}
        
        if (!$kiroOk) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [WARN] Kiro Gateway down, restarting..." -ForegroundColor Yellow
            if ($script:p1 -and !$script:p1.HasExited) { 
                $script:p1.Kill()
                Start-Sleep -Milliseconds 500
            }
            $psi1r = New-Object System.Diagnostics.ProcessStartInfo
            $psi1r.FileName = "python"
            $psi1r.Arguments = "main.py --port 9000"
            $psi1r.WorkingDirectory = "D:\Kiro\testopenclaw\kiro-gateway"
            $psi1r.UseShellExecute = $false
            $psi1r.CreateNoWindow = $true
            $script:p1 = [System.Diagnostics.Process]::Start($psi1r)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [OK] Kiro Gateway restarted" -ForegroundColor Green
            Start-Sleep -Milliseconds 2000
        }
        
        # 检查 Main Gateway
        $mainOk = $false
        try { 
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", 18789)
            $tcp.Close()
            $mainOk = $true 
        } catch {}
        
        if (!$mainOk) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [WARN] Main Gateway down, restarting..." -ForegroundColor Yellow
            if ($script:p2 -and !$script:p2.HasExited) { 
                $script:p2.Kill()
                Start-Sleep -Milliseconds 500
            }
            
            $lockDir = "$env:TEMP\openclaw"
            if (Test-Path $lockDir) {
                Get-ChildItem $lockDir -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
            }
            
            $script:p2 = Start-MainGateway
            
            if (Wait-ForPort 18789 30 $false) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [OK] Main Gateway ready" -ForegroundColor Green
                if ($script:gwToken) { 
                    Start-Process "http://127.0.0.1:18789/?token=$($script:gwToken)" 
                } else { 
                    Start-Process "http://127.0.0.1:18789/" 
                }
            } else { 
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [ERROR] Main Gateway timeout" -ForegroundColor Red 
            }
            $checkCount = 0
        }
    }
    Start-Sleep 2
}

Cleanup
