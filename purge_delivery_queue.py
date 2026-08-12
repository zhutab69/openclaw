"""Purge stale dead-letter entries from OpenClaw's delivery queue.

Called by OpenClaw.ps1 Cleanup (on launcher shutdown), AFTER the gateway is
stopped, so the state SQLite is free of concurrent writers.

Safety design:
  - Only deletes rows with status='failed' (terminal dead letters). Recovery /
    dequeue only ever processes status='pending', so 'pending'/'active' entries
    (waiting or in-flight) are never touched.
  - Only deletes entries whose dead-letter age (failed_at, fallback enqueued_at)
    is older than AGE_MS (default 1 day). Recent failures stay for visibility.
  - Refuses to touch the DB if the gateway is still listening on 18789
    (double safeguard; Cleanup should already have stopped it).
  - Never raises: any error is swallowed so it cannot block launcher shutdown.
  - Checkpoints the WAL so the delete lands in the main db file.

status semantics confirmed from dist (delivery-queue-sqlite):
  new entries default status='pending'; recovery filters WHERE status='pending';
  status='failed' sets failed_at and is terminal.
"""
import io
import json
import os
import socket
import sqlite3
import sys
import time

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

# Resolve the OpenClaw home strictly from USERPROFILE. No hard-coded user path:
# if it is unavailable we cannot safely locate the state db and simply skip.
USERPROFILE = os.environ.get("USERPROFILE")
OPENCLAW_HOME = os.path.join(USERPROFILE, ".openclaw") if USERPROFILE else None
DB = os.path.join(OPENCLAW_HOME, "state", "openclaw.sqlite") if OPENCLAW_HOME else None
CONFIG_PATH = os.path.join(OPENCLAW_HOME, "openclaw.json") if OPENCLAW_HOME else None

# OpenClaw's own default main gateway port, used only when the config declares
# no explicit port (mirrors the launcher/dashboard fallback behaviour).
DEFAULT_GATEWAY_PORT = 18789
AGE_MS = 24 * 60 * 60 * 1000  # 1 day


def _resolve_gateway_port():
    """Read the main gateway port dynamically from openclaw.json.

    Priority: gateway.port > agents.list[main].port > OpenClaw default.
    Never hard-code the port; fall back to the documented default only when the
    config declares none.
    """
    if not CONFIG_PATH or not os.path.isfile(CONFIG_PATH):
        return DEFAULT_GATEWAY_PORT
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8-sig") as f:
            cfg = json.load(f)
    except Exception:
        return DEFAULT_GATEWAY_PORT

    port = (cfg.get("gateway", {}) or {}).get("port")
    if isinstance(port, int) and port > 0:
        return port

    for agent in (cfg.get("agents", {}) or {}).get("list", []) or []:
        if agent.get("id") == "main":
            ap = agent.get("port")
            if isinstance(ap, int) and ap > 0:
                return ap
            break
    return DEFAULT_GATEWAY_PORT


def _gateway_up(port):
    """Return True if something is listening on 127.0.0.1:<port>."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(1.0)
    try:
        return s.connect_ex(("127.0.0.1", port)) == 0
    except OSError:
        return False
    finally:
        s.close()


def main():
    if not DB:
        print("[delivery] USERPROFILE not set, cannot locate state db, skip")
        return

    if not os.path.isfile(DB):
        print("[delivery] state db not found, skip")
        return

    gateway_port = _resolve_gateway_port()
    if _gateway_up(gateway_port):
        print("[delivery] gateway still listening on %d, skip purge" % gateway_port)
        return

    now_ms = int(time.time() * 1000)
    cutoff = now_ms - AGE_MS

    con = sqlite3.connect(DB, timeout=15)
    try:
        cur = con.cursor()
        # count candidates first (for the report)
        n = cur.execute(
            "SELECT COUNT(*) FROM delivery_queue_entries "
            "WHERE status='failed' AND COALESCE(failed_at, enqueued_at, 0) < ?",
            (cutoff,)).fetchone()[0]

        if n == 0:
            # show what remains so the operator can see it's just recent/none
            total_failed = cur.execute(
                "SELECT COUNT(*) FROM delivery_queue_entries WHERE status='failed'").fetchone()[0]
            print("[delivery] no dead letters older than 1d (failed total=%d)" % total_failed)
            return

        cur.execute(
            "DELETE FROM delivery_queue_entries "
            "WHERE status='failed' AND COALESCE(failed_at, enqueued_at, 0) < ?",
            (cutoff,))
        deleted = cur.rowcount
        con.commit()
        cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        remaining = cur.execute(
            "SELECT COUNT(*) FROM delivery_queue_entries WHERE status='failed'").fetchone()[0]
        print("[delivery] purged %d dead-letter entries (>1d); %d recent failed kept"
              % (deleted, remaining))
    finally:
        con.close()


try:
    main()
except Exception as e:
    # Never block launcher shutdown.
    print("[delivery] purge skipped (%s: %s)" % (type(e).__name__, e))
