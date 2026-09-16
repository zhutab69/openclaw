<#
  sync-cn-reach.ps1 -- fire-and-forget launcher/status probe for
  D:\Kiro\testspider\platform\scripts\sync-cn-reachable-to-mysql.cjs

  Why: the sync can run longer than the cron job timeout (300s). Waiting for it
  inside the cron turn made every run time out and immediately retry, burning
  tokens and CPU. This script starts the sync detached and lets the NEXT cron
  run report the previous result.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File sync-cn-reach.ps1 -Mode status
    powershell -NoProfile -ExecutionPolicy Bypass -File sync-cn-reach.ps1 -Mode start

  Output is KEY=VALUE lines (stable, machine readable). Never throws.
#>
param(
    [ValidateSet('status', 'start')]
    [string]$Mode = 'status'
)

$ErrorActionPreference = 'Continue'

$ProjectDir = 'D:\Kiro\testspider\platform'
$ScriptRel = 'scripts/sync-cn-reachable-to-mysql.cjs'
$StateDir = Join-Path $env:USERPROFILE '.openclaw\workspace\cron-state'
$OutFile = Join-Path $StateDir 'sync-cn-reach.out'
$ExitFile = Join-Path $StateDir 'sync-cn-reach.exit'
$StartFile = Join-Path $StateDir 'sync-cn-reach.start'

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

function Test-SyncRunning {
    # The detached worker is a powershell wrapper that spawns node. Match on the
    # script name so either process keeps the job marked as running.
    try {
        $hit = @(Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'sync-cn-reachable-to-mysql' })
        return ($hit.Count -gt 0)
    } catch {
        return $false
    }
}

function Get-LastDoneLine {
    if (-not (Test-Path $OutFile)) { return 'NONE' }
    try {
        $lines = Get-Content $OutFile -ErrorAction Stop
        # Prefer the terminal "done" event; fall back to dry_done.
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match '"event"\s*:\s*"(done|dry_done)"') { return $lines[$i].Trim() }
        }
        # No done event: surface the last non-empty line so failures stay visible.
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i].Trim()) { return 'NO_DONE_EVENT|' + $lines[$i].Trim() }
        }
        return 'NONE'
    } catch {
        return 'NONE'
    }
}

$running = Test-SyncRunning

if ($Mode -eq 'status') {
    $lastStart = if (Test-Path $StartFile) { (Get-Content $StartFile -Raw).Trim() } else { 'NONE' }
    $lastExit = if (Test-Path $ExitFile) { (Get-Content $ExitFile -Raw).Trim() } else { 'NONE' }
    $ageMin = 'NONE'
    if ($lastStart -ne 'NONE') {
        try { $ageMin = [string][math]::Round(((Get-Date) - [datetime]$lastStart).TotalMinutes, 1) } catch { $ageMin = 'NONE' }
    }
    Write-Output ("RUNNING=" + $running.ToString().ToLower())
    Write-Output ("LAST_START=" + $lastStart)
    Write-Output ("AGE_MIN=" + $ageMin)
    Write-Output ("LAST_EXIT=" + $lastExit)
    Write-Output ("LAST_DONE=" + (Get-LastDoneLine))
    exit 0
}

# ---- Mode = start ----
if ($running) {
    Write-Output "STARTED=false"
    Write-Output "REASON=already-running"
    exit 0
}

# Reset per-run state so the next status probe cannot read a stale result.
Remove-Item $ExitFile -Force -ErrorAction SilentlyContinue
Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
Set-Content -Path $StartFile -Value ((Get-Date).ToString('o')) -Encoding ASCII

# Detached worker: run node, capture all streams to $OutFile, then persist the
# exit code. Single quotes keep $LASTEXITCODE unexpanded until the child runs.
$inner = 'Set-Location ''{0}''; node {1} *> ''{2}''; Set-Content -Path ''{3}'' -Value $LASTEXITCODE' -f $ProjectDir, $ScriptRel, $OutFile, $ExitFile

try {
    $p = Start-Process -FilePath 'powershell' `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner `
        -WindowStyle Hidden -PassThru -ErrorAction Stop
    Write-Output "STARTED=true"
    Write-Output ("PID=" + $p.Id)
} catch {
    Write-Output "STARTED=false"
    Write-Output ("REASON=launch-failed|" + $_.Exception.Message)
}
exit 0
