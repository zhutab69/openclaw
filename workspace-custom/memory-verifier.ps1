# memory-verifier.ps1 - 校验记忆完整性
# 运行模式：
#   1) CheckOnly - 检查未整合日记、inbox 待处理项、整合验证失败（不写入）
#   2) ForceIntegrate - 强制处理所有未整合文件（适合手动修复）
param(
    [ValidateSet('CheckOnly','ForceIntegrate')]
    $Mode = 'CheckOnly',
    [switch]$NoAlert
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = "C:\Users\zhuyulin\.openclaw\workspace"
$memoryDir = Join-Path $workspaceRoot "memory"
$verifierLog = Join-Path $workspaceRoot "memory\verifier-log.jsonl"

# 步骤1：扫描所有日记（支持同日多文件）
function GetUnconsolidatedDiaries {
    $all = Get-ChildItem -Path $memoryDir -File -Filter "*.md" | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}' }
    $unprocessed = @()
    foreach ($f in $all) {
        $content = Get-Content -Path $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content) { continue }
        $hasMark = $content -match '<!--\s*consolidated\s*-->'
        if (-not $hasMark) {
            $unprocessed += @{
                path = $f.FullName
                name = $f.Name
                size = $f.Length
                lastWrite = $f.LastWriteTimeUtc
            }
        }
    }
    return $unprocessed
}

# 步骤2：验证 Dream Log 最近一次成功运行时间
function GetLastDreamRun {
    $dreamLog = Join-Path $memoryDir "dream-log.md"
    if (-not (Test-Path $dreamLog)) { return $null }
    $content = Get-Content -Path $dreamLog -Raw
    $matches = [regex]::Matches($content, '## 🌙 Dream #(\d+) — (\d{4}-\d{2}-\d{2})')
    if ($matches.Count -eq 0) { return $null }
    $last = $matches[-1]
    return @{
        id = [int]$last.Groups[1].Value
        date = [DateTime]::ParseExact($last.Groups[2].Value, 'yyyy-MM-dd', $null)
    }
}

# 步骤3：验证 MEMORY.md 与 MEMORY-blocks.md 可读性
function ValidateMemoryFiles {
    $memoryPath = Join-Path $workspaceRoot "MEMORY.md"
    $blocksPath = Join-Path $workspaceRoot "MEMORY-blocks.md"
    $errors = @()
    foreach ($p in ($memoryPath, $blocksPath)) {
        if (Test-Path $p) {
            try {
                $null = Get-Content -Path $p -TotalCount 1 -ErrorAction Stop
            } catch {
                $errors += "$p read error: $_"
            }
        }
    }
    return $errors
}

# 步骤4：按模式处理
$unconsolidated = GetUnconsolidatedDiaries
$lastDream = GetLastDreamRun
$memoryErrors = ValidateMemoryFiles
$now = [DateTime]::UtcNow

$result = @{
    timestamp = $now.ToString('o')
    mode = $Mode
    unconsolidatedCount = $unconsolidated.Count
    unconsolidatedFiles = $unconsolidated
    lastDreamRunId = $lastDream.id
    lastDreamDate = $lastDream.date.ToString('o')
    memoryErrors = $memoryErrors
}

# 模式：检查
if ($Mode -eq 'CheckOnly') {
    # 判定告警条件
    $alerts = @()
    if ($unconsolidated.Count -gt 0) {
        $alerts += "存在 $($unconsolidated.Count) 个未整合日记：" + ($unconsolidated.name -join ', ')
    }
    if ($memoryErrors.Count -gt 0) {
        $alerts += "记忆文件读取错误：" + ($memoryErrors -join '; ')
    }
    # 过去48小时无 Dream 运行（但排除18、19日正常关机）
    $twoDaysAgo = $now.AddDays(-2)
    if ($lastDream.date -lt $twoDaysAgo) {
        $alerts += "最近48小时内没有 Dream 运行（最后 #$($lastDream.id) 在 $($lastDream.date.ToString('yyyy-MM-dd'))）"
    }
    $result.alerts = $alerts
    $result.requiresAlert = ($alerts.Count -gt 0) -and (-not $NoAlert)
    
    $result | ConvertTo-Json -Depth 3
    if ($alerts.Count -gt 0) { exit 1 } else { exit 0 }
} else {
    # 模式：强制整合
    # 这里留为 future integration with Auto-Dream 的桩
    $result.message = "ForceIntegrate not yet implemented"
    $result | ConvertTo-Json -Depth 3
    exit 2
}
