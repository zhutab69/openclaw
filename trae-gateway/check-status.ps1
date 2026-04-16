# Trae Gateway Status Check Script

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  Trae Gateway Status Check' -ForegroundColor White
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

$port = 9010
$portInUse = $false

try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect('127.0.0.1', $port)
    $tcp.Close()
    $portInUse = $true
} catch {
    $portInUse = $false
}

if ($portInUse) {
    Write-Host '  [OK] Trae Gateway is running' -ForegroundColor Green
    Write-Host '  Port: '$port -ForegroundColor Gray
    Write-Host '  URL: http://127.0.0.1:'$port -ForegroundColor Cyan
} else {
    Write-Host '  [X] Trae Gateway is not running' -ForegroundColor Red
    Write-Host ''
    Write-Host '  To start:' -ForegroundColor Yellow
    Write-Host '  cd trae-gateway' -ForegroundColor Gray
    Write-Host '  python main.py' -ForegroundColor Gray
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''
