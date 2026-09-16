# cron-uptime.ps1 — 打印 OpenClaw Gateway 已运行分钟数
# 用途：cron 补跑守卫判别「补跑」vs「手动执行/正常触发」
# 补跑只在 Gateway 重启后约 2 分钟内发生；手动执行时 uptime 必然较大。
# 输出：一行 "UPTIME_MIN=<数字>"（失败时输出 UPTIME_MIN=999，即按"非补跑"处理，安全偏向执行）
$ErrorActionPreference = 'SilentlyContinue'
try {
    $proc = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -like '*gateway*' -and $_.CommandLine -like '*openclaw*' } |
        Sort-Object CreationDate |
        Select-Object -First 1
    if ($null -eq $proc) {
        Write-Output 'UPTIME_MIN=999'
        exit 0
    }
    $start = $proc.CreationDate
    if ($null -eq $start) {
        Write-Output 'UPTIME_MIN=999'
        exit 0
    }
    $min = [math]::Round(((Get-Date) - $start).TotalMinutes)
    Write-Output ("UPTIME_MIN=" + $min)
} catch {
    Write-Output 'UPTIME_MIN=999'
}
