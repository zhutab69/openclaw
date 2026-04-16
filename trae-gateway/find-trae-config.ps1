# Trae 配置查找脚本

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Trae 配置信息查找工具" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$traeDir = "D:\Trae CN"

if (!(Test-Path $traeDir)) {
    Write-Host "错误: Trae 目录不存在: $traeDir" -ForegroundColor Red
    exit 1
}

Write-Host "[1/5] 查找配置文件..." -ForegroundColor Yellow
Write-Host ""

# 查找 JSON 文件
Write-Host "  JSON 配置文件:" -ForegroundColor Cyan
$jsonFiles = Get-ChildItem $traeDir -Recurse -Filter "*.json" -ErrorAction SilentlyContinue | Select-Object -First 20
if ($jsonFiles) {
    foreach ($file in $jsonFiles) {
        Write-Host "    - $($file.FullName)" -ForegroundColor Gray
    }
} else {
    Write-Host "    未找到" -ForegroundColor DarkGray
}

Write-Host ""

# 查找 YAML 文件
Write-Host "  YAML 配置文件:" -ForegroundColor Cyan
$yamlFiles = Get-ChildItem $traeDir -Recurse -Filter "*.yaml" -ErrorAction SilentlyContinue | Select-Object -First 20
if (!$yamlFiles) {
    $yamlFiles = Get-ChildItem $traeDir -Recurse -Filter "*.yml" -ErrorAction SilentlyContinue | Select-Object -First 20
}
if ($yamlFiles) {
    foreach ($file in $yamlFiles) {
        Write-Host "    - $($file.FullName)" -ForegroundColor Gray
    }
} else {
    Write-Host "    未找到" -ForegroundColor DarkGray
}

Write-Host ""

# 查找 TOML 文件
Write-Host "  TOML 配置文件:" -ForegroundColor Cyan
$tomlFiles = Get-ChildItem $traeDir -Recurse -Filter "*.toml" -ErrorAction SilentlyContinue | Select-Object -First 20
if ($tomlFiles) {
    foreach ($file in $tomlFiles) {
        Write-Host "    - $($file.FullName)" -ForegroundColor Gray
    }
} else {
    Write-Host "    未找到" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "[2/5] 查找日志文件..." -ForegroundColor Yellow
Write-Host ""

$logFiles = Get-ChildItem $traeDir -Recurse -Filter "*.log" -ErrorAction SilentlyContinue | Select-Object -First 10
if ($logFiles) {
    foreach ($file in $logFiles) {
        Write-Host "    - $($file.FullName)" -ForegroundColor Gray
    }
} else {
    Write-Host "    未找到" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "[3/5] 查找 Trae 进程..." -ForegroundColor Yellow
Write-Host ""

$processes = Get-Process | Where-Object {$_.ProcessName -like "*trae*" -or $_.ProcessName -like "*Trae*"}
if ($processes) {
    foreach ($proc in $processes) {
        Write-Host "    进程: $($proc.ProcessName) (PID: $($proc.Id))" -ForegroundColor Green
        
        # 尝试获取命令行
        try {
            $wmi = Get-WmiObject Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue
            if ($wmi -and $wmi.CommandLine) {
                Write-Host "    命令行: $($wmi.CommandLine)" -ForegroundColor Gray
            }
        } catch {}
    }
} else {
    Write-Host "    未找到 Trae 进程" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "[4/5] 检查常见配置目录..." -ForegroundColor Yellow
Write-Host ""

$configDirs = @(
    "$traeDir\config",
    "$traeDir\data",
    "$traeDir\user",
    "$env:APPDATA\Trae",
    "$env:LOCALAPPDATA\Trae",
    "$env:USERPROFILE\.trae"
)

foreach ($dir in $configDirs) {
    if (Test-Path $dir) {
        Write-Host "    [存在] $dir" -ForegroundColor Green
        $files = Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Select-Object -First 5
        if ($files) {
            foreach ($file in $files) {
                Write-Host "           - $($file.Name)" -ForegroundColor Gray
            }
        }
    } else {
        Write-Host "    [不存在] $dir" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "[5/5] 检查网络连接..." -ForegroundColor Yellow
Write-Host ""

$connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | 
    Where-Object {$_.OwningProcess -in $processes.Id}

if ($connections) {
    Write-Host "    Trae 的网络连接:" -ForegroundColor Cyan
    foreach ($conn in $connections) {
        Write-Host "    - $($conn.LocalAddress):$($conn.LocalPort) -> $($conn.RemoteAddress):$($conn.RemotePort)" -ForegroundColor Gray
    }
} else {
    Write-Host "    未找到活动连接" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  查找完成" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "下一步:" -ForegroundColor Yellow
Write-Host "1. 检查上述配置文件，查找 API 端点和认证信息" -ForegroundColor Gray
Write-Host "2. 或使用 Fiddler/Wireshark 抓包查看 API 请求" -ForegroundColor Gray
Write-Host "3. 将找到的信息配置到 trae-gateway/.env" -ForegroundColor Gray
Write-Host ""
