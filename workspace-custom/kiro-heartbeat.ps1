# Kiro Gateway 心跳保活脚本
# 功能：1. 保持 Gateway token 活跃  2. 检测 token 过期时自动刷新

$headers = @{ "Authorization" = "Bearer my-super-secret-password-123" }
$body = '{"model":"claude-haiku-4.5","messages":[{"role":"user","content":"heartbeat"}],"max_tokens":1}'

try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:9000/v1/chat/completions" -Method POST -Headers $headers -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 15
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Heartbeat OK (Status: $($response.StatusCode))"
} catch {
    $statusCode = 0
    if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Heartbeat Failed (Status: $statusCode)"
    
    # 500 = token 过期，自动刷新
    if ($statusCode -eq 500) {
        Write-Host "Token expired, auto-refreshing..."
        try {
            $refreshResult = python "D:\Kiro\testopenclaw\refresh_token.py" 2>&1
            if ($refreshResult -match "SUCCESS") {
                Write-Host "Token refreshed successfully"
            } else {
                Write-Host "Token refresh output: $refreshResult"
            }
        } catch {
            Write-Host "Token refresh failed: $($_.Exception.Message)"
        }
    }
}
