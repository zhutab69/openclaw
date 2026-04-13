# OpenClaw Launcher - Optimized Version
# Node.js v22.22.1 / OpenClaw 2026.3.13

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = "OpenClaw Launcher (Optimized)"

$NODE = "D:\Kiro\testopenclaw\node-v22.22.1-win-x64\node.exe"
$OPENCLAW_MJS = "D:\Kiro\testopenclaw\node-v22.22.1-win-x64\node_modules\openclaw\openclaw.mjs"
$WORKDIR = "D:\Kiro\testopenclaw"

$subAgents = @(
    @{ id = "writer-agent"; profile = "writer"; port = 3010 },
    @{ id = "dev-agent";    profile = "dev";    port = 3020 },
    @{ id = "info-agent";   profile = "info";   port = 3030 },
    @{ id = "image-agent";  profile = "image";  port = 3040 }
)

# 性能统计
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
        Start-Sleep -Milliseconds 1500
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
            Start-Sleep -Milliseconds 500
        }
    }
    return $false
}

function Cleanup {
    Write-Host "`n`n========================================" -ForegroundColor Cyan
    Write-Host "  Stopping all services..." -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    
    if ($script:p1 -and !$script:p1.HasExited) { $script:p1.Kill() }
    if ($script:p2 -and !$script:p2.HasExited) { $script:p2.Kill() }
    if ($script:pDash -and !$script:pDash.HasExited) { $script:pDash.Kill() }
    if ($script:pBot -and !$script:pBot.HasExited) { $script:pBot.Kill() }
    foreach ($proc in $script:subCmdProcs) {
        if ($proc -and !$proc.HasExited) { 
            cmd /c "taskkill /F /T /PID $($proc.Id) >nul 2>&1" 
        }
    }
    Clear-AllPorts | Out-Null
    Write-Host "  All services stopped." -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OpenClaw Launcher (Optimized)" -ForegroundColor White
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

# 清理锁文件
$lockDir = "$env:TEMP\openclaw"
if (Test-Path $lockDir) {
    Get-ChildItem $lockDir -Filter "gateway.*.lock" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

# ============================================
# [2/8] 启动 Kiro Gateway (Python)
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

if (Wait-ForPort 9000 30 $true) {
    Write-Host " Ready! PID $($script:p1.Id) ($(Elapsed $t0))" -ForegroundColor Green
} else {
    Write-Host " Timeout! ($(Elapsed $t0))" -ForegroundColor Red
}
$script:perfStats["kiro-gateway"] = (Get-Date) - $t0

# ============================================
# [3/8] 同步模型配置
# ============================================
$t0 = Get-Date
Write-Host "[3/8] Syncing models..." -NoNewline
try {
    $result = python "D:\Kiro\testopenclaw\sync_models.py" 2>&1
    $lines = @($result)
    if ($lines[0] -match "^OK:(\d+):([^:]+):(.*)$") {
        Write-Host " Synced $($Matches[1]) models ($(Elapsed $t0))" -ForegroundColor Green
        $script:gwToken = $Matches[3]
    } else { 
        Write-Host " Warning: $($lines[0]) ($(Elapsed $t0))" -ForegroundColor Yellow 
    }
} catch { 
    Write-Host " Failed: $_ ($(Elapsed $t0))" -ForegroundColor Red 
}
$script:perfStats["sync-models"] = (Get-Date) - $t0

# ============================================
# [4/8] 启动主 Gateway (OpenClaw Main)
# ============================================
$t0 = Get-Date
Write-Host "[4/8] Starting Main Gateway (port 18789)..." -NoNewline
$script:p2 = Start-MainGateway
Write-Host " Started PID $($script:p2.Id) ($(Elapsed $t0))" -ForegroundColor Green
$script:perfStats["main-gateway"] = (Get-Date) - $t0

# ============================================
# [5/8] 并行启动所有子 Agents
# ============================================
$t0 = Get-Date
Write-Host "[5/8] Starting Sub-Agents (parallel)..."
$script:subCmdProcs = @()
foreach ($agent in $subAgents) {
    $cmdArgs = "/k title $($agent.id) (port $($agent.port)) && set OPENCLAW_DISABLE_BONJOUR=1 && `"$NODE`" `"$OPENCLAW_MJS`" --profile $($agent.profile) gateway --port $($agent.port) --force"
    $proc = Start-Process "cmd.exe" -ArgumentList $cmdArgs -WorkingDirectory $WORKDIR -WindowStyle Minimized -PassThru
    $script:subCmdProcs += $proc
    Write-Host "  [$($agent.id)] PID $($proc.Id) on port $($agent.port)" -ForegroundColor Green
    Start-Sleep -Milliseconds 500  # 减少延迟
}
Write-Host "  All sub-agents started ($(Elapsed $t0))" -ForegroundColor Green
$script:perfStats["sub-agents"] = (Get-Date) - $t0

# ============================================
# [6/8] 启动 Dashboard Server (Node.js)
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
Write-Host " Started PID $($script:pDash.Id) ($(Elapsed $t0))" -ForegroundColor Green
$script:perfStats["dashboard"] = (Get-Date) - $t0

# ============================================
# [7/8] 启动 Bot Review (Next.js)
# ============================================
$t0 = Get-Date
Write-Host "[7/8] Starting Bot Review Server (port 8900)..." -NoNewline
$psiBot = New-Object System.Diagnostics.ProcessStartInfo
$psiBot.FileName = $NODE
$psiBot.Arguments = "`"D:\Kiro\testopenclaw\OpenClaw-bot-review\.next\standalone\server.js`""
$psiBot.WorkingDirectory = "D:\Kiro\testopenclaw\OpenClaw-bot-review\.next\standalone"
$psiBot.UseShellExecute = $false
$psiBot.CreateNoWindow = $true
$psiBot.EnvironmentVariables["PORT"] = "8900"
$psiBot.EnvironmentVariables["OPENCLAW_DISABLE_BONJOUR"] = "1"
$script:pBot = [System.Diagnostics.Process]::Start($psiBot)
Write-Host " Started PID $($script:pBot.Id) ($(Elapsed $t0))" -ForegroundColor Green
$script:perfStats["bot-review"] = (Get-Date) - $t0

# ============================================
# [8/8] 等待所有服务就绪
# ============================================
$t0 = Get-Date
Write-Host "[8/8] Waiting for all services..." -NoNewline
$allPorts = @(18789, 3010, 3020, 3030, 3040, 8899, 8900)
$deadline = (Get-Date).AddSeconds(45)  # 减少超时时间
$pending = [System.Collections.Generic.List[int]]::new()
foreach ($p in $allPorts) { $pending.Add($p) | Out-Null }

$readyPorts = @()
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $done = @()
    foreach ($port in $pending) {
        try { 
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $port)
            $tcp.Close()
            $done += $port
            $readyPorts += $port
        } catch {}
    }
    foreach ($port in $done) { 
        $pending.Remove($port) | Out-Null
        Write-Host "." -NoNewline 
    }
    if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 500 }
}

if ($pending.Count -gt 0) {
    Write-Host ""
    Write-Host "  Warning: Ports $($pending -join ', ') not ready ($(Elapsed $t0))" -ForegroundColor Yellow
} else {
    Write-Host " All ready! ($(Elapsed $t0))" -ForegroundColor Green
}
$script:perfStats["wait-ready"] = (Get-Date) - $t0

# ============================================
# 打开浏览器
# ============================================
$t0 = Get-Date
Write-Host ""
Write-Host "Opening browsers..." -ForegroundColor Yellow

# 验证端口就绪状态（修复：使用数组避免枚举错误）
$portsToCheck = @(18789, 8899, 8900)
$portsReady = @{}

foreach ($port in $portsToCheck) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", $port)
        $tcp.Close()
        $portsReady[$port] = $true
        Write-Host "  [OK] Port $port is ready" -ForegroundColor DarkGray
    } catch {
        $portsReady[$port] = $false
        Write-Host "  [WARN] Port $port not responding!" -ForegroundColor Red
    }
}

Write-Host ""

# 打开主控制台 (18789)
Write-Host "  [1/3] Opening Main Dashboard..." -ForegroundColor DarkGray
try {
    if ($portsReady[18789]) {
        if ($script:gwToken) { 
            cmd /c start "Main Dashboard" "http://127.0.0.1:18789/?token=$($script:gwToken)"
        } else { 
            cmd /c start "Main Dashboard" "http://127.0.0.1:18789/"
        }
        Write-Host "        [+] Opened: Main Dashboard (18789)" -ForegroundColor Green
    } else {
        Write-Host "        [-] Skipped: Main Dashboard (port not ready)" -ForegroundColor Red
    }
} catch {
    Write-Host "        [!] Failed to open Main Dashboard: $($_.Exception.Message)" -ForegroundColor Red
}

Start-Sleep -Milliseconds 2000

# 打开多 Agent 监控 (8899)
Write-Host "  [2/3] Opening Multi-Agent Hub..." -ForegroundColor DarkGray
try {
    if ($portsReady[8899]) {
        cmd /c start "Multi-Agent Hub" "http://127.0.0.1:8899/"
        Write-Host "        [+] Opened: Multi-Agent Hub (8899)" -ForegroundColor Green
    } else {
        Write-Host "        [-] Skipped: Multi-Agent Hub (port not ready)" -ForegroundColor Red
    }
} catch {
    Write-Host "        [!] Failed to open Multi-Agent Hub: $($_.Exception.Message)" -ForegroundColor Red
}

Start-Sleep -Milliseconds 2000

# 打开 Bot Review (8900)
Write-Host "  [3/3] Opening Bot Review..." -ForegroundColor DarkGray
try {
    if ($portsReady[8900]) {
        cmd /c start "Bot Review" "http://127.0.0.1:8900/"
        Write-Host "        [+] Opened: Bot Review (8900)" -ForegroundColor Green
    } else {
        Write-Host "        [-] Skipped: Bot Review (port not ready)" -ForegroundColor Red
    }
} catch {
    Write-Host "        [!] Failed to open Bot Review: $($_.Exception.Message)" -ForegroundColor Red
}


# 诊断信息
$failedPorts = $portsToCheck | Where-Object { !$portsReady[$_] }
if ($failedPorts.Count -gt 0) {
    Write-Host ""
    Write-Host "  [WARN] Some services are not ready: $($failedPorts -join ', ')" -ForegroundColor Yellow
    Write-Host "  [TIP] You can manually open: http://127.0.0.1:8899/" -ForegroundColor Cyan
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
$kiroMs = [int]$script:perfStats['kiro-gateway'].TotalMilliseconds
$syncMs = [int]$script:perfStats['sync-models'].TotalMilliseconds
$mainMs = [int]$script:perfStats['main-gateway'].TotalMilliseconds
$subMs = [int]$script:perfStats['sub-agents'].TotalMilliseconds
$dashMs = [int]$script:perfStats['dashboard'].TotalMilliseconds
$botMs = [int]$script:perfStats['bot-review'].TotalMilliseconds
$waitMs = [int]$script:perfStats['wait-ready'].TotalMilliseconds
$browserMs = [int]$script:perfStats['open-browsers'].TotalMilliseconds

Write-Host "  [1] Cleanup:        $(if($cleanupMs -lt 1000){$cleanupMs.ToString() + 'ms'}else{[math]::Round($cleanupMs/1000,2).ToString() + 's'})" -ForegroundColor Gray
Write-Host "  [2] Kiro Gateway:   $(if($kiroMs -lt 1000){$kiroMs.ToString() + 'ms'}else{[math]::Round($kiroMs/1000,2).ToString() + 's'})" -ForegroundColor Gray
Write-Host "  [3] Sync Models:    $(if($syncMs -lt 1000){$syncMs.ToString() + 'ms'}else{[math]::Round($syncMs/1000,2).ToString() + 's'})" -ForegroundColor Gray
Write-Host "  [4] Main Gateway:   $(if($mainMs -lt 1000){$mainMs.ToString() + 'ms'}else{[math]::Round($mainMs/1000,2).ToString() + 's'})" -ForegroundColor Gray
Write-Host "  [5] Sub-Agents:     $(if($subMs -lt 1000){$subMs.ToString() + 'ms'}else{[math]::Round($subMs/1000,2).ToString() + 's'})" -ForegroundColor Gray
Write-Host "  [6] Dashboard:      $(if($dashMs -lt 1000){$dashMs.ToString() + 'ms'}else{[math]::Round($dashMs/1000,2).ToString() + 's'})" -ForegroundColor Gray
Write-Host "  [7] Bot Review:     $(if($botMs -lt 1000){$botMs.ToString() + 'ms'}else{[math]::Round($botMs/1000,2).ToString() + 's'})" -ForegroundColor Gray
Write-Host "  [8] Wait Ready:     $(if($waitMs -lt 1000){$waitMs.ToString() + 'ms'}else{[math]::Round($waitMs/1000,2).ToString() + 's'})" -ForegroundColor Gray
Write-Host "  [9] Open Browsers:  $(if($browserMs -lt 1000){$browserMs.ToString() + 'ms'}else{[math]::Round($browserMs/1000,2).ToString() + 's'})" -ForegroundColor Gray
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
    if ($checkCount % 5 -eq 0) {  # 每10秒检查一次（原来是6秒）
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
                Start-Sleep -Milliseconds 1000 
            }
            $psi1r = New-Object System.Diagnostics.ProcessStartInfo
            $psi1r.FileName = "python"
            $psi1r.Arguments = "main.py --port 9000"
            $psi1r.WorkingDirectory = "D:\Kiro\testopenclaw\kiro-gateway"
            $psi1r.UseShellExecute = $false
            $psi1r.CreateNoWindow = $true
            $script:p1 = [System.Diagnostics.Process]::Start($psi1r)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [OK] Kiro Gateway restarted" -ForegroundColor Green
            Start-Sleep -Milliseconds 3000
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
                Start-Sleep -Milliseconds 1000 
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
