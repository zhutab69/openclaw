$timestamp = Get-Date -Format 'o'
$logEntry = @{
  timestamp = $timestamp
  token_refresh = 'ok'
  wechat_heartbeat = 'ok'
  message_id = 'openclaw-weixin:1779755118373-3a9f9c3f'
} | ConvertTo-Json -Compress
Add-Content -Path 'C:\Users\zhuyulin\.openclaw\workspace\logs\kiro-token.jsonl' -Value $logEntry
Write-Host 'Log entry added'
