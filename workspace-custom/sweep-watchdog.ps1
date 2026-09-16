# Sweep census watchdog. ASCII-only to avoid PS5.1 no-BOM decode issues.
# Emits machine-readable status lines for cron agent to read.
# Detects: queue-runner alive + active output file advancing; kills hung sweep child so runner resumes.
$ErrorActionPreference = "Continue"
$STALL_MIN = 3
$root = "D:\Kiro\testspider\platform\data\bulk\cn"
$qlog = Join-Path $root "queue-runner.log"

# 1) queue-runner parent alive?
$runner = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*sweep-queue-runner*' } | Select-Object -First 1
if (-not $runner) {
    $tail = if (Test-Path $qlog) { Get-Content $qlog -Tail 6 } else { @() }
    $allDone = $tail | Where-Object { $_ -like '*queue_all_done*' }
    $aborted = $tail | Where-Object { $_ -like '*queue_abort*' }
    if ($allDone) { Write-Output "STATUS=QUEUE_ALL_DONE" }
    elseif ($aborted) { Write-Output "STATUS=QUEUE_ABORTED"; $tail | Select-Object -Last 2 | ForEach-Object { Write-Output "LOG=$_" } }
    else { Write-Output "STATUS=QUEUE_GONE_UNKNOWN"; $tail | Select-Object -Last 2 | ForEach-Object { Write-Output "LOG=$_" } }
    exit 0
}

# 2) active output file = newest cn-reach.jsonl across reach-* dirs (exclude bak)
$active = Get-ChildItem $root -Recurse -Filter "cn-reach.jsonl" -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -notlike '*bak*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $active) { Write-Output "STATUS=NO_ACTIVE_FILE"; exit 0 }
$ageMin = [math]::Round(((Get-Date) - $active.LastWriteTime).TotalMinutes, 1)
$lines = (Get-Content $active.FullName -ReadCount 0).Count

# 3) sweep child process
$child = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*cn-reachability-sweep*' } | Select-Object -First 1

if ($ageMin -gt $STALL_MIN) {
    if ($child) {
        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Output "STATUS=STALL_KILLED"
        Write-Output "KILLED_PID=$($child.ProcessId)"
    } else {
        Write-Output "STATUS=STALL_NOCHILD"
    }
    Write-Output "AGE_MIN=$ageMin"
    Write-Output "ACTIVE=$($active.Directory.Name)"
    Write-Output "LINES=$lines"
    exit 0
}

Write-Output "STATUS=RUNNING"
Write-Output "AGE_MIN=$ageMin"
Write-Output "ACTIVE=$($active.Directory.Name)"
Write-Output "LINES=$lines"
exit 0
