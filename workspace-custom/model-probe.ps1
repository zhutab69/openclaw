# Model liveness probe - send a real completion to each model to test availability.
# Being listed by /v1/models does NOT mean generation works.
$ErrorActionPreference = "Continue"
$config = Get-Content "C:\Users\zhuyulin\.openclaw\openclaw.json" -Raw | ConvertFrom-Json
$apiKey = $config.models.providers.'kiro-gw'.apiKey
$base = "http://127.0.0.1:9000"
$headers = @{ Authorization = "Bearer $apiKey"; "Content-Type" = "application/json" }

$models = @(
  "claude-haiku-4.5",
  "claude-sonnet-4",
  "claude-sonnet-4.5",
  "claude-sonnet-4.6",
  "claude-sonnet-5",
  "claude-opus-4.5",
  "claude-opus-4.6",
  "claude-opus-4.7",
  "claude-opus-4.8",
  "claude-opus-5",
  "deepseek-3.2",
  "glm-5",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
  "gpt-5.6-sol",
  "minimax-m2.1",
  "minimax-m2.5",
  "qwen3-coder-next"
)

$results = @()
foreach ($m in $models) {
  $body = @{
    model = $m
    messages = @(@{ role = "user"; content = "reply with the single word: ok" })
    max_tokens = 8
    stream = $false
  } | ConvertTo-Json -Depth 5
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $status = "?"; $detail = ""
  try {
    $r = Invoke-RestMethod -Uri "$base/v1/chat/completions" -Method POST -Headers $headers -Body $body -TimeoutSec 60 -ErrorAction Stop
    $txt = ""
    try { $txt = $r.choices[0].message.content } catch {}
    $status = "OK"
    $detail = ($txt -replace "\s+"," ").Trim()
    if ($detail.Length -gt 40) { $detail = $detail.Substring(0,40) }
  }
  catch {
    $status = "FAIL"
    $code = 0
    if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
    $msg = $_.Exception.Message
    try {
      $stream = $_.Exception.Response.GetResponseStream()
      $reader = New-Object System.IO.StreamReader($stream)
      $errBody = $reader.ReadToEnd()
      if ($errBody) { $msg = $errBody }
    } catch {}
    if ($msg.Length -gt 120) { $msg = $msg.Substring(0,120) }
    $detail = "http=$code $msg"
  }
  $watch.Stop()
  $results += [PSCustomObject]@{ model = $m; status = $status; ms = $watch.ElapsedMilliseconds; detail = $detail }
  Write-Output ("{0,-22} {1,-5} {2,7}ms  {3}" -f $m, $status, $watch.ElapsedMilliseconds, $detail)
}

Write-Output ""
Write-Output "=== SUMMARY ==="
$ok = ($results | Where-Object { $_.status -eq "OK" }).model -join ", "
$fail = ($results | Where-Object { $_.status -eq "FAIL" }).model -join ", "
Write-Output "ALIVE: $ok"
Write-Output "DEAD:  $fail"
$results | ConvertTo-Json -Compress | Out-File "C:\Users\zhuyulin\.openclaw\workspace\logs\model-probe-result.json" -Encoding utf8
