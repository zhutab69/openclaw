# Trae Gateway 启动和状态检查脚本

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Trae Gateway 状态检查" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 检查端口 9010 是否被占用
$port = 9010
$portInUse = $false

try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", $port)
    $tcp.Close()
    $portInUse = $true
} catch {
    $portInUse = $false
}

if ($portInUse) {
    Write-Host "  [✓] Trae Gateway 正在运行" -ForegroundColor Green
    Write-Host "  端口: $port" -ForegroundColor Gray
    Write-Host "  URL: http://127.0.0.1:$port" -ForegroundColor Cyan
    Write-Host ""
    
    # 尝试获取健康状态
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -TimeoutSec 5 -UseBasicParsing
        Write-Host "  健康检查: OK" -ForegroundColor Green
    } catch {
        Write-Host "  健康检查: 失败" -ForegroundColor Yellow
    }
    
    # 查找进程
    $lines = cmd /c "netstat -ano 2>nul" | Select-String ":$port\s"
    if ($lines) {
        foreach ($line in $lines) {
            if ($line -match "LISTENING.*\s(\d+)\s*$") {
                $pid = $Matches[1]
                try {
                    $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
                    if ($proc) {
                        Write-Host "  进程: $($proc.ProcessName) (PID: $pid)" -ForegroundColor Gray
                    }
                } catch {}
            }
        }
    }
} else {
    Write-Host "  [✗] Trae Gateway 未运行" -ForegroundColor Red
    Write-Host ""
    Write-Host "  启动方式:" -ForegroundColor Yellow
    Write-Host "  1. cd trae-gateway" -ForegroundColor Gray
    Write-Host "  2. python main.py" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  或使用 Docker:" -ForegroundColor Yellow
    Write-Host "  docker-compose up -d" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  配置指南: trae-gateway/SETUP_GUIDE.md" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 检查 .env 文件
$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
    Write-Host "  配置文件: 已找到" -ForegroundColor Green
    
    # 检查关键配置
    $content = Get-Content $envFile -Raw
    $hasApiKey = $content -match 'PROXY_API_KEY\s*='
    $hasToken = $content -match 'REFRESH_TOKEN\s*='
    $hasCredsFile = $content -match 'KIRO_CREDS_FILE\s*='
    
    if ($hasApiKey) {
        Write-Host "  ✓ PROXY_API_KEY 已配置" -ForegroundColor Gray
    } else {
        Write-Host "  ✗ PROXY_API_KEY 未配置" -ForegroundColor Yellow
    }
    
    if ($hasToken -or $hasCredsFile) {
        Write-Host "  ✓ 认证凭证已配置" -ForegroundColor Gray
    } else {
        Write-Host "  ✗ 认证凭证未配置" -ForegroundColor Yellow
        Write-Host "    请配置 REFRESH_TOKEN 或 KIRO_CREDS_FILE" -ForegroundColor Yellow
    }
} else {
    Write-Host "  配置文件: 未找到" -ForegroundColor Red
    Write-Host "  请复制 .env.example 到 .env 并配置" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
