# 删除近3个月的报告文件和原始数据
$cutoffDate = (Get-Date).AddMonths(-3)
$deletedFiles = @()
$failedFiles = @()

Write-Host "=== 开始清理近3个月的报告文件 ===" -ForegroundColor Cyan
Write-Host "截止日期: $cutoffDate" -ForegroundColor Yellow
Write-Host ""

# 1. 删除报告 Markdown 文件
Write-Host "1. 删除报告 Markdown 文件..." -ForegroundColor Green
$reportFiles = Get-ChildItem 'C:\Users\zhuyulin\.openclaw\workspaces\' -Recurse -Include '*report*.md','*weekly*.md','*daily*.md' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $cutoffDate }

foreach ($file in $reportFiles) {
    try {
        Remove-Item $file.FullName -Force
        $deletedFiles += $file.FullName
        Write-Host "✓ 已删除: $($file.Name)" -ForegroundColor Gray
    } catch {
        $failedFiles += $file.FullName
        Write-Host "✗ 删除失败: $($file.Name) - $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""

# 2. 删除原始数据 JSON 文件
Write-Host "2. 删除原始数据 JSON 文件..." -ForegroundColor Green
$jsonFiles = Get-ChildItem 'C:\Users\zhuyulin\.openclaw\workspaces\coder-agent\news-verifier\output\' -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $cutoffDate }

foreach ($file in $jsonFiles) {
    try {
        Remove-Item $file.FullName -Force
        $deletedFiles += $file.FullName
        Write-Host "✓ 已删除: $($file.Name)" -ForegroundColor Gray
    } catch {
        $failedFiles += $file.FullName
        Write-Host "✗ 删除失败: $($file.Name) - $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== 清理完成 ===" -ForegroundColor Cyan
Write-Host "成功删除: $($deletedFiles.Count) 个文件" -ForegroundColor Green
Write-Host "删除失败: $($failedFiles.Count) 个文件" -ForegroundColor Red

if ($failedFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "失败文件列表:" -ForegroundColor Red
    $failedFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
