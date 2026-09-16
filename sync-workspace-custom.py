#!/usr/bin/env python3
"""Mirror the publishable parts of ~/.openclaw/workspace into this repo so they get
version history, and refuse to copy anything that carries a credential.

Why a mirror instead of tracking the workspace directly: that directory is 2649
files / 607 MB (node_modules 114 MB, overseas-source-backup 85 MB, ~40 MB of dated
news snapshots) and it also holds personal memory and channel identifiers. Only a
hand-picked whitelist belongs in version control.

Why the whitelist is limited to infrastructure: the GitHub remote of this repo is
PUBLIC (verified: anonymous HTTP 200 on github.com/zhutab69/openclaw). Personal and
identifying files are therefore excluded on purpose and listed in EXCLUDED_ON_PURPOSE
so the reason is not lost.

Usage:
    python sync-workspace-custom.py            # report drift only, change nothing
    python sync-workspace-custom.py --apply    # copy live -> mirror
"""
import hashlib
import os
import re
import shutil
import sys

HOME = os.environ["USERPROFILE"]
WS = os.path.join(HOME, ".openclaw", "workspace")
REPO = os.path.dirname(os.path.abspath(__file__))
MIRROR = os.path.join(REPO, "workspace-custom")

# Infrastructure that is safe to publish. Keep this list explicit: a glob would
# silently pull in the next data dump or memory file that lands in the workspace.
WHITELIST = [
    # web dashboard + service registry (single source of truth for the launcher)
    "webservers.json",
    "dashboard-server.cjs",
    "dashboard.html",
    "package.json",
    # keepalive / heartbeat / uptime
    "kiro-keepalive.ps1",
    "kiro-heartbeat.ps1",
    "log-heartbeat.ps1",
    "cron-uptime.ps1",
    "cron-uptime.js",
    "sweep-watchdog.ps1",
    # agent + model ops
    "start-agents.ps1",
    "model-probe.ps1",
    "memory-verifier.ps1",
    "memory-verifier.js",
    # data pipeline entry points still in use
    "sync-cn-reach.ps1",
    # housekeeping
    "cleanup-delivery-queue.cjs",
    "cleanup-reports.ps1",
    "delete-reports.ps1",
    # skill tooling
    "skill-analyzer.py",
    "skill-tool-map.json",
    "skill-library-index.md",
    "SKILL_RULES.md",
    "SKILL_EXTENSIONS.md",
    # shared operating rules (no personal content)
    "COMMON_RULES.md",
    "COMMON_RULES_CORE.md",
    "COMMON_RULES_COORDINATION.md",
    "COMMON_RULES_EXTENDED.md",
    "COMMON_RULES_OPS.md",
    "TOOLS.md",
]

# Deliberately NOT mirrored, with the reason. Documented so a future pass does not
# "helpfully" add them to a public repo.
EXCLUDED_ON_PURPOSE = {
    "MEMORY.md": "personal/business memory",
    "MEMORY-blocks.md": "personal/business memory (96 KB)",
    "MEMORY.archive.md": "personal/business memory archive",
    "MEMORY-synonyms.json": "derived from memory content",
    "USER.md": "user profile",
    "IDENTITY.md": "agent identity",
    "SOUL.md": "agent persona",
    "AGENTS.md": "agent roster with internal detail",
    "KIRO_INTRO.md": "internal-facing intro",
    "HEARTBEAT.md": "operational notes",
    "config.json": "contains botId / channel wiring",
    "channels.json": "contains botId and allowFrom user identifiers",
    "bindings.json": "agent<->channel bindings",
    "skill-health-report.json": "internal audit data (40 KB)",
    "skill-health-report.md": "internal audit data",
    "*-2026-*.json / news-*.json": "dated collection snapshots (~40 MB)",
    "_*.ps1 / _*.cjs": "one-off probe scripts",
    "node_modules/, overseas-source-backup/": "vendored deps / 85 MB data",
}

# Anything matching these must not reach the mirror.
BLOCK = [
    ("refresh_token value", re.compile(r"refreshToken[\"']?\s*[:=]\s*[\"'][A-Za-z0-9_\-\.]{20,}")),
    ("client_secret value", re.compile(r"clientSecret[\"']?\s*[:=]\s*[\"'][^\"']{10,}")),
    ("corp secret", re.compile(r"corpsecret\s*[:=]\s*[\"'][^\"']{10,}", re.I)),
    ("aws access key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("private key block", re.compile(r"BEGIN (?:RSA |EC )?PRIVATE KEY")),
    ("url with password", re.compile(r"https?://[^\s:/\"']+:[^\s@\"']{4,}@")),
    ("real codewhisperer arn", re.compile(r"arn:aws:codewhisperer:[^\s\"']*:\d{12}:")),
]

# Note on the gateway API key: dashboard-server.cjs and kiro-heartbeat.ps1 embed the
# upstream trae-gateway default key, which this repo's own README.md already documents,
# so mirroring those files adds no new exposure. It matches none of the BLOCK patterns
# above and needs no allowlist entry. Scrubbing it would make the mirror diverge from
# the live files and break restores; rotating it is a separate hardening item.


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def gate(path):
    """Return list of blocking reasons for this file."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        return [f"unreadable: {e}"]
    bad = []
    for label, rx in BLOCK:
        if rx.search(text):
            bad.append(label)
    return bad


def main():
    apply = "--apply" in sys.argv
    if not os.path.isdir(WS):
        raise SystemExit(f"[ABORT] workspace not found: {WS}")

    os.makedirs(MIRROR, exist_ok=True)

    missing, blocked, new, changed, same = [], [], [], [], []
    for name in WHITELIST:
        src = os.path.join(WS, name)
        dst = os.path.join(MIRROR, name)
        if not os.path.isfile(src):
            missing.append(name)
            continue
        reasons = gate(src)
        if reasons:
            blocked.append((name, sorted(set(reasons))))
            continue
        if not os.path.exists(dst):
            new.append(name)
        elif sha(src) != sha(dst):
            changed.append(name)
        else:
            same.append(name)
            continue
        if apply:
            # binary copy: preserves UTF-8-no-BOM exactly, per project rule 4
            shutil.copyfile(src, dst)

    verb = "copied" if apply else "would copy"
    print(f"mirror = {MIRROR}")
    print()
    if new:
        print(f"NEW ({len(new)}) -- {verb}")
        for n in new:
            print(f"  + {n}")
        print()
    if changed:
        print(f"CHANGED ({len(changed)}) -- {verb}")
        for n in changed:
            print(f"  ~ {n}")
        print()
    if same:
        print(f"UP-TO-DATE ({len(same)})")
    if missing:
        print(f"MISSING from workspace ({len(missing)}) -- whitelist may be stale")
        for n in missing:
            print(f"  ? {n}")
    if blocked:
        print()
        print(f"*** BLOCKED ({len(blocked)}) -- credential found, NOT copied ***")
        for n, r in blocked:
            print(f"  ! {n}: {', '.join(r)}")

    print()
    print(f"summary: new={len(new)} changed={len(changed)} same={len(same)} "
          f"missing={len(missing)} blocked={len(blocked)}")
    if not apply and (new or changed):
        print("run with --apply to write")
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
