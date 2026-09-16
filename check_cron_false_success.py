"""Detect cron "false success" runs: status=ok but the task never actually ran.

Observed failure mode (2026-09-15): several cron runs were recorded as ok while the
reply was just an assistant greeting/self-introduction (e.g. "我是 Kiro, 一个 AI 驱动的
开发环境...", "我在等你的指令"), i.e. the task prompt never took effect - typically
after upstream 504 retries. Such runs reset consecutive_errors and never fire
failureAlert, so they hide worse than a clean failure.

Detection is deliberately precision-first, because a noisy check gets ignored:

  1. GENERIC signatures  - the reply is an idle greeting / self-introduction rather
                           than task output. High precision: a task run has no
                           reason to introduce itself.
  2. PER-JOB expectation - only for jobs explicitly hardened with an output marker,
                           and only for runs AFTER that hardening (see SINCE).
                           Jobs whose reply is delivered to a chat channel are
                           intentionally NOT marker-based, so user-visible
                           messages stay clean.

Read-only. Never throws, never blocks startup: always exits 0.

Usage:
  python check_cron_false_success.py [--hours N] [--quiet-when-clean]
"""

import argparse
import datetime as _dt
import os
import re
import sqlite3
import sys
import time

# --- Layer 1: generic "the task never ran" reply shapes ---------------------
GENERIC_SIGNATURES = [
    (re.compile(r"我是\s*Kiro"), "self-introduction"),
    (re.compile(r"AI\s*驱动的开发环境"), "self-introduction"),
    (re.compile(r"^\s*(I am|I'm)\s+Kiro\b", re.IGNORECASE), "self-introduction"),
    (re.compile(r"我(已)?准备好[了。\s]"), "idle greeting"),
    (re.compile(r"我在等你的指令"), "idle greeting"),
    (re.compile(r"你需要我做什么"), "idle greeting"),
    (re.compile(r"请告诉我(你想|需要)"), "idle greeting"),
]

# --- Layer 2: per-job output marker, effective only after hardening ---------
# prefix -> (required pattern, effective-from local datetime)
EXPECTED = {
    "0ae7ed3a": (re.compile(r"#CRONOK:0ae7ed3a"), "2026-09-15T10:30:00"),
}


def _to_ms(iso: str):
    try:
        return int(_dt.datetime.fromisoformat(iso).timestamp() * 1000)
    except ValueError:
        return None


def resolve_db():
    home = os.environ.get("USERPROFILE")
    if not home:
        return None
    p = os.path.join(home, ".openclaw", "state", "openclaw.sqlite")
    return p if os.path.isfile(p) else None


def classify(job_id: str, ts: int, summary: str):
    """Return a reason string when the run looks like a false success, else None."""
    for pat, label in GENERIC_SIGNATURES:
        if pat.search(summary):
            return f"{label} reply (task prompt never took effect)"
    for prefix, (pat, since_iso) in EXPECTED.items():
        if not job_id.startswith(prefix):
            continue
        since_ms = _to_ms(since_iso)
        if since_ms is not None and ts < since_ms:
            continue  # predates the hardening; marker not expected yet
        if not pat.search(summary):
            return f"missing required output marker for {prefix}"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=int, default=48, help="lookback window (default 48)")
    ap.add_argument("--quiet-when-clean", action="store_true",
                    help="print nothing when no suspicious run is found")
    ap.add_argument("--top", type=int, default=3,
                    help="how many findings to detail (default 3; startup output "
                         "stays short, the count is always reported)")
    ap.add_argument("--verbose", action="store_true",
                    help="detail every finding (equivalent to --top 0)")
    args = ap.parse_args()
    if args.verbose:
        args.top = 0

    db = resolve_db()
    if not db:
        print("[cron-check] skipped: state sqlite not found")
        return 0

    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        cur = con.cursor()
        names = {jid: name for jid, name in cur.execute("select job_id, name from cron_jobs")}
        since = int((time.time() - args.hours * 3600) * 1000)
        rows = list(cur.execute(
            "select job_id, ts, status, coalesce(summary,'') "
            "from cron_run_logs where ts >= ? order by ts desc",
            (since,),
        ))
        con.close()
    except sqlite3.Error as e:
        print(f"[cron-check] skipped: {e}")
        return 0

    suspicious = []
    for job_id, ts, status, summary in rows:
        if status != "ok":
            continue
        why = classify(job_id, ts, summary)
        if why:
            suspicious.append((job_id, ts, why, summary))

    if not suspicious:
        if not args.quiet_when_clean:
            print(f"[cron-check] no false-success run in last {args.hours}h "
                  f"({len(rows)} runs scanned)")
        return 0

    # Group by job: at startup the useful signal is "which jobs are affected, and
    # how often", not a full transcript dump.
    per_job = {}
    for job_id, ts, why, summary in suspicious:
        per_job.setdefault(job_id, []).append((ts, why, summary))

    print(f"[cron-check] {len(suspicious)} suspicious 'ok' run(s) across "
          f"{len(per_job)} job(s) in last {args.hours}h -- task likely did NOT run")
    for job_id, hits in sorted(per_job.items(), key=lambda kv: -len(kv[1])):
        name = names.get(job_id, "(deleted job)")
        newest = time.strftime("%m-%d %H:%M", time.localtime(hits[0][0] / 1000))
        print(f"   - [{job_id[:8]}] {name[:26]} x{len(hits)}, latest {newest}")

    detail = suspicious if args.top <= 0 else suspicious[: args.top]
    if detail:
        print("   detail:")
        for job_id, ts, why, summary in detail:
            when = time.strftime("%m-%d %H:%M", time.localtime(ts / 1000))
            head = " ".join(summary.split())[:52]
            print(f"     {when} [{job_id[:8]}] {why}")
            print(f"       reply: {head}")
    if args.top > 0 and len(suspicious) > args.top:
        print(f"   (+{len(suspicious) - args.top} more; run "
              f"check_cron_false_success.py --verbose for all)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # never block the launcher
        print(f"[cron-check] skipped: {e}")
        sys.exit(0)
