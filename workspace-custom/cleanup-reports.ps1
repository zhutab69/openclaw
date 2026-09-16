# 查找近3个月的报告文件
$cutoffDate = (Get-Date).AddMonths(-3)

Write-Host "=== 查找近3个月的报告文件 ===" -ForegroundColor Cyan
Write-Host "截止日期: $cutoffDate" -ForegroundColor Yellow
Write-Host ""

# 查找报告 Markdown 文件
Write-Host "1. 报告 Markdown 文件:" -ForegroundColor Green
$reportFiles = Get-ChildItem 'C:\Users\zhuyulin\.openclaw\workspaces\' -Recurse -Include '*report*.md','*weekly*.md','*daily*.md' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $cutoffDate }
$reportFiles | Select-Object FullName, LastWriteTime, @{Name='SizeMB';Expression={[math]::Round($_.Length/1MB,2)}} | Format-Table -AutoSize

Write-Host "报告文件总数: $($reportFiles.Count)" -ForegroundColor Yellow
Write-Host "报告文件总大小: $([math]::Round(($reportFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 2)) MB" -ForegroundColor Yellow
Write-Host ""

# 查找原始数据 JSON 文件
Write-Host "2. 原始数据 JSON 文件:" -ForegroundColor Green
$jsonFiles = Get-ChildItem 'C:\Users\zhuyulin\.openclaw\workspaces\coder-agent\news-verifier\output\' -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $cutoffDate }
$jsonFiles | Select-Object Name, LastWriteTime, @{Name='SizeMB';Expression={[math]::Round($_.Length/1MB,2)}} | Format-Table -AutoSize

Write-Host "JSON 文件总数: $($jsonFiles.Count)" -ForegroundColor Yellow
Write-Host "JSON 文件总大小: $([math]::Round(($jsonFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 2)) MB" -ForegroundColor Yellow
Write-Host ""

# 汇总
$totalFiles = $reportFiles.Count + $jsonFiles.Count
$totalSize = [math]::Round((($reportFiles | Measure-Object -Property Length -Sum).Sum + ($jsonFiles | Measure-Object -Property Length -Sum).Sum) / 1MB, 2)

Write-Host "=== 汇总 ===" -ForegroundColor Cyan
Write-Host "总文件数: $totalFiles" -ForegroundColor Yellow
Write-Host "总大小: $totalSize MB" -ForegroundColor Yellow
