# 启动所有专精 Agent 脚本（含锁文件清理）
# 用法: .\start-agents.ps1

$agents = @(
    @{ profile='writer'; port=3010 },
    @{ profile='dev';    port=3020 },
    @{ profile='info';   port=3030 },
    @{ profile='image';  port=3040 }
)

foreach ($a in $agents) {
    $profile = $a.profile
    $port    = $a.port

    # 1. 清理残留锁文件
    $lockFile = "$HOME\.openclaw-$profile\gateway.lock"
    if (Test-Path $lockFile) {
        Remove-Item $lockFile -Force
        Write-Host "[$profile] Removed stale lock file"
    }

    # 2. 杀掉占用端口的旧进程
    $lines = netstat -ano | Select-String ":$port " | Select-String "LISTENING"
    foreach ($line in $lines) {
        $parts = $line.ToString().Trim() -split '\s+'
        $procId = $parts[-1]
        if ($procId -match '^\d+$' -and $procId -ne '0') {
            taskkill /PID $procId /F 2>$null
            Write-Host "[$profile] Killed old process PID $procId on port $port"
        }
    }

    Start-Sleep -Seconds 1

    # 3. 启动新实例
    Start-Process powershell -ArgumentList "-NoExit", "-Command", "title $profile-agent (port $port) && openclaw --profile $profile gateway run --port $port" -WindowStyle Normal
    Write-Host "[$profile] Starting on port $port..."
    Start-Sleep -Seconds 3
}

Write-Host ""
Write-Host "All agents started. Checking ports in 15 seconds..."
Start-Sleep -Seconds 15

foreach ($a in $agents) {
    $port = $a.port
    try {
        $t = New-Object System.Net.Sockets.TcpClient
        $t.Connect("127.0.0.1", $port); $t.Close()
        Write-Host "$($a.profile) (:$port): OK"
    } catch {
        Write-Host "$($a.profile) (:$port): FAILED"
    }
}
