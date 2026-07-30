"""Sync models from configured providers to openclaw.json, then propagate to sub-agents.

All configuration is read dynamically from openclaw.json:
- Provider URLs, API keys, and model lists from models.providers
- Sub-agent list from agents.list
- Primary model from agents.defaults.model.primary

No hardcoded values. If a provider is unreachable, existing config is preserved.
"""
import urllib.request, json, os, shutil, time, glob

HOME = os.environ["USERPROFILE"]
MAIN_CONFIG = os.path.join(HOME, ".openclaw", "openclaw.json")
BACKUP_PATH = MAIN_CONFIG + ".sync-bak"

# Agent names and emojis - used to fix encoding corruption from config.patch
AGENT_NAMES = {
    "main": "先知",
    "writer-agent": "文墨",
    "coder-agent": "码农",
    "info-agent": "讯探",
    "image-agent": "绘影",
}

AGENT_EMOJIS = {
    "main": "\U0001f52e",        # 🔮
    "writer-agent": "\u270d\ufe0f",  # ✍️
    "coder-agent": "\U0001f4bb",     # 💻
    "info-agent": "\U0001f50d",      # 🔍
    "image-agent": "\U0001f3a8",     # 🎨
}

# Agent model assignments - protected from config.patch corruption
# Agent model assignments - NOT hardcoded
# Models are managed by the user via OpenClaw webchat UI (agents page).
# sync_models.py only protects names/emojis from config.patch encoding corruption,
# it does NOT override model assignments.
AGENT_MODELS = {}

# OpenClaw 运行时故障转移链最大长度（不含 primary）。上游网络中断时，过长的 fallback 会逐一超时，
# 把单次失败拖到数分钟。3 个足以覆盖"某个模型临时不可用"，又不至于在整体不可达时雪崩。
MAX_FALLBACK_MODELS = int(os.environ.get("MAX_FALLBACK_MODELS", "3"))
def _load_config():
    """Load main openclaw.json."""
    with open(MAIN_CONFIG, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def _fix_agent_names(config):
    """Fix garbled agent names, emojis, and models caused by config.patch."""
    agents = config.get("agents", {}).get("list", [])
    fixed = False
    for agent in agents:
        aid = agent.get("id", "")
        # Fix name
        correct_name = AGENT_NAMES.get(aid)
        if correct_name and agent.get("name") != correct_name:
            agent["name"] = correct_name
            fixed = True
        # Fix emoji
        correct_emoji = AGENT_EMOJIS.get(aid)
        if correct_emoji:
            current_emoji = agent.get("identity", {}).get("emoji", "")
            if current_emoji != correct_emoji:
                agent.setdefault("identity", {})["emoji"] = correct_emoji
                fixed = True
    return fixed


def _load_profiles():
    """Load agent-to-profile mapping from agent-profiles.json."""
    profiles_path = os.path.join(HOME, ".openclaw", "agent-profiles.json")
    try:
        with open(profiles_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _load_sub_agents(config):
    """从 openclaw.json 动态读取 sub-agent 列表。"""
    profiles = _load_profiles()
    mapping = {}
    for agent in config.get("agents", {}).get("list", []):
        aid = agent.get("id", "")
        if aid and aid != "main":
            profile = profiles.get(aid) or (aid.replace("-agent", "") if aid.endswith("-agent") else aid)
            mapping[profile] = aid
    return mapping


# ============================================================
# Session Cleanup (runs before model sync on every startup)
# ============================================================

# Sessions older than this are force-closed (seconds)
SESSION_MAX_AGE_S = 2 * 3600  # 2 hours

# Keep at most this many .jsonl files per agent
# B3 rollup (stats-daily.json) preserves统计数据，删文件不再丢统计，
# 因此原始 session 文件保持精简以最小化启动加载；此值仅影响 session 详情可回溯条数。
SESSION_MAX_FILES = 100

# Session keys that should be reset (new session created) on startup
# These are "sticky" sessions that OpenClaw reuses for webchat/wecom
STICKY_SESSION_KEYS = ["agent:main:main"]

# Sticky session is reset if older than this (seconds)
# Daily reset ensures fresh context while dailyMemory preserves important info
# Based on sessionStartedAt (creation time), not updatedAt
STICKY_RESET_AGE_S = 8 * 3600  # 8 hours (reset on next startup after a work day)

# Sticky session with pendingFinalDelivery is removed if pending older than this
PENDING_DELIVERY_MAX_AGE_S = 30 * 60  # 30 minutes

# Terminal deliveries older than this cannot be safely replayed. Clear only their
# pending-delivery fields while preserving the session and its transcript.
TERMINAL_PENDING_DELIVERY_MAX_AGE_S = 2 * 3600  # 2 hours

# Subagent/dashboard entries with abortedLastRun=True are orphan-recovery candidates;
# remove them if older than this regardless of status
ORPHAN_CANDIDATE_MAX_AGE_S = 3600  # 1 hour

# Old completed entries (status in done/failed/timeout) that bloat sessions.json
# are removed if older than this
OLD_ENTRY_MAX_AGE_S = 24 * 3600  # 24 hours


def _cleanup_sessions():
    """Clean up stale/zombie sessions for all agents.

    1. Fix sessions.json: mark running+aborted sessions as done
    2. Remove sessions older than SESSION_MAX_AGE_S
    3. Reset sticky sessions (webchat main) to force new session creation
    4. Delete orphan .lock files
    5. Trim session files to SESSION_MAX_FILES (oldest deleted first)
    6. Clean orphan trajectory files
    """
    config = _load_config()
    agents = config.get("agents", {}).get("list", [])
    profiles = _load_profiles()

    # Build list of session directories to clean
    session_dirs = []
    # Main agent
    main_dir = os.path.join(HOME, ".openclaw", "agents", "main", "sessions")
    if os.path.isdir(main_dir):
        session_dirs.append(("main", main_dir))
    # Sub-agents
    for agent in agents:
        aid = agent.get("id", "")
        if aid and aid != "main":
            sub_dir = os.path.join(HOME, ".openclaw", "agents", aid, "sessions")
            if os.path.isdir(sub_dir):
                session_dirs.append((aid, sub_dir))

    now_ms = int(time.time() * 1000)
    now_s = time.time()
    total_fixed = 0
    total_reset = 0
    total_pending_cleared = 0
    total_deleted = 0
    total_locks = 0

    for agent_id, sess_dir in session_dirs:
        # --- Step 1: Fix sessions.json ---
        sessions_json = os.path.join(sess_dir, "sessions.json")
        if os.path.isfile(sessions_json):
            try:
                with open(sessions_json, "r", encoding="utf-8-sig") as f:
                    sdata = json.load(f)

                modified = False
                keys_to_remove = []

                if isinstance(sdata, dict):
                    for key, entry in sdata.items():
                        if not isinstance(entry, dict):
                            continue
                        status = entry.get("status", "")
                        aborted = entry.get("abortedLastRun", False)
                        last_active = entry.get("updatedAt", 0) or entry.get("lastInteractionAt", 0)
                        pending_created = entry.get("pendingFinalDeliveryCreatedAt", 0)
                        has_pending = bool(entry.get("pendingFinalDelivery") or entry.get("pendingPayload"))

                        # Rule 0: terminal pending deliveries older than two hours are
                        # stale recovery records. Preserve the session/transcript, but
                        # remove only delivery fields so they cannot replay to a now
                        # invalid channel target on every Gateway restart.
                        if (
                            has_pending
                            and status in ("done", "failed", "timeout")
                            and pending_created > 0
                            and now_ms - pending_created > TERMINAL_PENDING_DELIVERY_MAX_AGE_S * 1000
                        ):
                            for pending_field in tuple(entry):
                                if pending_field.startswith("pendingFinalDelivery") or pending_field == "pendingPayload":
                                    entry.pop(pending_field, None)
                            has_pending = False
                            pending_created = 0
                            total_pending_cleared += 1
                            modified = True

                        # Rule 1: running + aborted → remove key entirely (zombie from crash)
                        if status == "running" and aborted:
                            keys_to_remove.append(key)
                            total_fixed += 1
                            continue

                        # Rule 2: any session older than max age and still running → remove
                        if status == "running" and last_active > 0:
                            age_ms = now_ms - last_active
                            if age_ms > SESSION_MAX_AGE_S * 1000:
                                keys_to_remove.append(key)
                                total_fixed += 1
                                continue

                        # Rule 3: sticky sessions (webchat main) - reset if session is old
                        # Uses sessionStartedAt (creation time) not updatedAt (which refreshes on every interaction)
                        if key in STICKY_SESSION_KEYS:
                            session_started = entry.get("sessionStartedAt", 0)
                            if session_started > 0:
                                session_age_ms = now_ms - session_started
                                if session_age_ms > STICKY_RESET_AGE_S * 1000:
                                    keys_to_remove.append(key)
                                    total_reset += 1
                                    continue

                        # Rule 4: sticky sessions with stuck pending delivery
                        # If pendingFinalDelivery exists and is older than threshold, remove
                        if key in STICKY_SESSION_KEYS and has_pending and pending_created > 0:
                            pending_age_ms = now_ms - pending_created
                            if pending_age_ms > PENDING_DELIVERY_MAX_AGE_S * 1000:
                                keys_to_remove.append(key)
                                total_reset += 1
                                continue

                        # Rule 5: orphan-recovery candidates
                        # Subagent entries with abortedLastRun=True are picked up by
                        # subagent-orphan-recovery on restart - remove if old
                        if aborted and last_active > 0 and ":subagent:" in key:
                            age_ms = now_ms - last_active
                            if age_ms > ORPHAN_CANDIDATE_MAX_AGE_S * 1000:
                                keys_to_remove.append(key)
                                total_fixed += 1
                                continue

                        # Rule 6: old completed entries (cleanup bloat)
                        # Remove done/failed/timeout entries older than 24h
                        if status in ("done", "failed", "timeout") and last_active > 0:
                            age_ms = now_ms - last_active
                            if age_ms > OLD_ENTRY_MAX_AGE_S * 1000:
                                # Don't remove sticky keys this way (handled by Rule 3)
                                if key not in STICKY_SESSION_KEYS:
                                    keys_to_remove.append(key)
                                    total_fixed += 1
                                    continue

                    # Remove stale keys
                    # Distinguish between "reset" (keep files for memory) and "purge" (delete files)
                    reset_keys = set()  # Rule 3, 4: only remove mapping, keep .jsonl for memory/startupContext
                    for key in keys_to_remove:
                        session_id = sdata[key].get("sessionId", "")

                        # Rules 3 & 4 are "reset" — keep session files for OpenClaw's
                        # memoryFlush/startupContext to extract. Files will be cleaned
                        # by OpenClaw's own sessionRetention ("24h") or our trim logic.
                        is_reset = key in STICKY_SESSION_KEYS

                        if session_id and not is_reset:
                            # Purge: delete session files (zombie/orphan/old entries)
                            for ext in [".jsonl", ".trajectory.jsonl", ".trajectory-path.json"]:
                                fpath = os.path.join(sess_dir, session_id + ext)
                                if os.path.isfile(fpath):
                                    try:
                                        os.remove(fpath)
                                        total_deleted += 1
                                    except Exception:
                                        pass

                        del sdata[key]
                        modified = True

                if modified:
                    with open(sessions_json, "w", encoding="utf-8") as f:
                        json.dump(sdata, f, indent=2, ensure_ascii=False)
            except Exception:
                pass  # Don't break startup if sessions.json is corrupt

        # --- Step 2: Delete orphan .lock files ---
        for lock_file in glob.glob(os.path.join(sess_dir, "*.lock")):
            try:
                os.remove(lock_file)
                total_locks += 1
            except Exception:
                pass

        # --- Step 3: Trim old session files ---
        jsonl_files = glob.glob(os.path.join(sess_dir, "*.jsonl"))
        # Also include trajectory files in the count
        traj_files = glob.glob(os.path.join(sess_dir, "*.trajectory.jsonl"))
        path_files = glob.glob(os.path.join(sess_dir, "*.trajectory-path.json"))

        # Sort by modification time (newest first)
        all_session_files = []
        for f in jsonl_files:
            if ".trajectory." not in f:
                all_session_files.append(f)
        all_session_files.sort(key=lambda x: os.path.getmtime(x), reverse=True)

        # Keep only the newest SESSION_MAX_FILES
        if len(all_session_files) > SESSION_MAX_FILES:
            to_delete = all_session_files[SESSION_MAX_FILES:]
            for f in to_delete:
                base = f.rsplit(".", 1)[0]  # Remove .jsonl extension
                # Delete the session file and its associated trajectory/path files
                for pattern in [f, base + ".trajectory.jsonl", base + ".trajectory-path.json"]:
                    if os.path.isfile(pattern):
                        try:
                            os.remove(pattern)
                            total_deleted += 1
                        except Exception:
                            pass

        # --- Step 4: Clean orphan trajectory files (no matching .jsonl) ---
        remaining_ids = set()
        for f in glob.glob(os.path.join(sess_dir, "*.jsonl")):
            bn = os.path.basename(f)
            if ".trajectory." not in bn:
                remaining_ids.add(bn.replace(".jsonl", ""))
        for f in glob.glob(os.path.join(sess_dir, "*.trajectory.jsonl")):
            sid = os.path.basename(f).replace(".trajectory.jsonl", "")
            if sid not in remaining_ids:
                try:
                    os.remove(f)
                    total_deleted += 1
                except Exception:
                    pass
        for f in glob.glob(os.path.join(sess_dir, "*.trajectory-path.json")):
            sid = os.path.basename(f).replace(".trajectory-path.json", "")
            if sid not in remaining_ids:
                try:
                    os.remove(f)
                    total_deleted += 1
                except Exception:
                    pass

    # Report
    parts = []
    if total_fixed:
        parts.append(f"fixed={total_fixed}")
    if total_reset:
        parts.append(f"reset={total_reset}")
    if total_pending_cleared:
        parts.append(f"stale_pending_deliveries={total_pending_cleared}")
    if total_deleted:
        parts.append(f"trimmed={total_deleted}")
    if total_locks:
        parts.append(f"locks={total_locks}")
    if parts:
        print(f"[sessions] cleanup: {', '.join(parts)}")


# ============================================================
# Stats Rollup (B3) — 持久化每日统计，删 session 文件不丢统计
# ============================================================
# 设计：每个 agent 维护 stats-daily.json = {lockedByDay, files}
#   - files[sid] = {mtime, byDay}  : 当前磁盘上存在的 session 文件的逐日统计（用于检测被删后归档）
#   - lockedByDay[date] = {...}     : 已被删除文件的逐日统计（永久保留）
# 维护逻辑（在 cleanup 之后运行，本轮被 cleanup 删除的文件立即归档，无可见性缺口）：
#   1. tracked 中已不在磁盘的文件 → 把其 byDay 累加进 lockedByDay，并从 tracked 移除
#   2. 磁盘上新增/mtime 变化的文件 → 重新解析 byDay 写入 tracked（mtime 未变则跳过，最小化启动开销）
# Bot Review 端读取 = lockedByDay + 实时解析当前存在的文件（两者文件集互斥，不重复计数）。

def _iso_to_ms(ts):
    """Parse ISO timestamp string to epoch milliseconds. Returns None on failure."""
    try:
        from datetime import datetime
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000
    except Exception:
        return None


def _empty_day():
    return {"input": 0, "output": 0, "messageCount": 0, "rtSum": 0, "rtCount": 0}


def _merge_day(target, date, src):
    d = target.setdefault(date, _empty_day())
    d["input"] += src.get("input", 0)
    d["output"] += src.get("output", 0)
    d["messageCount"] += src.get("messageCount", 0)
    d["rtSum"] += src.get("rtSum", 0)
    d["rtCount"] += src.get("rtCount", 0)


def _parse_session_by_day(filepath):
    """Parse a session .jsonl into per-day stats.

    Returns {date: {input, output, messageCount, rtSum, rtCount}}.
    Mirrors Bot Review 的解析口径：token 来自 assistant.usage；
    响应时间为 user → 下一个 stopReason=stop 的 assistant，区间 (0, 600000) ms。
    """
    by_day = {}
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read().strip()
    except Exception:
        return by_day
    if not content:
        return by_day

    messages = []  # (role, ts, stopReason)
    for line in content.split("\n"):
        try:
            entry = json.loads(line)
        except Exception:
            continue
        if entry.get("type") != "message":
            continue
        msg = entry.get("message")
        ts = entry.get("timestamp")
        if not msg or not ts:
            continue
        role = msg.get("role")
        messages.append((role, ts, msg.get("stopReason")))
        if role == "assistant" and msg.get("usage"):
            date = ts[:10]
            usage = msg["usage"]
            d = by_day.setdefault(date, _empty_day())
            d["input"] += usage.get("input", 0) or 0
            d["output"] += usage.get("output", 0) or 0
            d["messageCount"] += 1

    last_user_ts = None
    for role, ts, stop in messages:
        if role == "user":
            last_user_ts = ts
        elif role == "assistant" and stop == "stop" and last_user_ts:
            a = _iso_to_ms(ts)
            u = _iso_to_ms(last_user_ts)
            if a is not None and u is not None:
                diff = a - u
                if 0 < diff < 600000:
                    date = last_user_ts[:10]
                    d = by_day.setdefault(date, _empty_day())
                    d["rtSum"] += diff
                    d["rtCount"] += 1
            last_user_ts = None
    return by_day


def _update_one_rollup(sess_dir):
    """Maintain stats-daily.json for a single agent's sessions dir."""
    rollup_path = os.path.join(os.path.dirname(sess_dir), "stats-daily.json")
    rollup = {"lockedByDay": {}, "files": {}}
    if os.path.isfile(rollup_path):
        try:
            with open(rollup_path, "r", encoding="utf-8-sig") as f:
                loaded = json.load(f)
            if isinstance(loaded, dict):
                rollup["lockedByDay"] = loaded.get("lockedByDay", {}) or {}
                rollup["files"] = loaded.get("files", {}) or {}
        except Exception:
            pass

    locked = rollup["lockedByDay"]
    tracked = rollup["files"]

    # 当前磁盘上的 session 文件（排除 trajectory 与已删除标记）
    present = {}
    for fp in glob.glob(os.path.join(sess_dir, "*.jsonl")):
        bn = os.path.basename(fp)
        if ".trajectory." in bn or ".deleted." in bn:
            continue
        sid = bn[:-len(".jsonl")]
        try:
            present[sid] = os.path.getmtime(fp)
        except Exception:
            pass

    changed = False

    # Step 1: 已消失的 tracked 文件 → 归档到 locked
    for sid in list(tracked.keys()):
        if sid not in present:
            for date, c in (tracked[sid].get("byDay") or {}).items():
                _merge_day(locked, date, c)
            del tracked[sid]
            changed = True

    # Step 2: 新增/变化的当前文件 → 解析写入 tracked（mtime 未变则跳过）
    for sid, mtime in present.items():
        prev = tracked.get(sid)
        if prev and abs(float(prev.get("mtime", 0)) - mtime) < 0.001:
            continue
        tracked[sid] = {"mtime": mtime, "byDay": _parse_session_by_day(os.path.join(sess_dir, sid + ".jsonl"))}
        changed = True

    if changed:
        try:
            tmp = rollup_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(rollup, f, ensure_ascii=False)
            os.replace(tmp, rollup_path)
        except Exception:
            pass
    return changed


def _update_stats_rollups():
    """Update stats-daily.json for main + all sub-agents across instances.

    Runs AFTER _cleanup_sessions so files trimmed this run are archived this run.
    Iterates the correct per-profile instance dirs (sub-agents live in
    ~/.openclaw-<profile>/agents/<agent-id>/sessions).
    """
    config = _load_config()
    sub_agents = _load_sub_agents(config)  # {profile: agent_id}

    dirs = []
    main_dir = os.path.join(HOME, ".openclaw", "agents", "main", "sessions")
    if os.path.isdir(main_dir):
        dirs.append(main_dir)
    for profile, agent_id in sub_agents.items():
        sub_dir = os.path.join(HOME, f".openclaw-{profile}", "agents", agent_id, "sessions")
        if os.path.isdir(sub_dir):
            dirs.append(sub_dir)
        else:
            # Fallback: 同实例布局（向后兼容）
            legacy = os.path.join(HOME, ".openclaw", "agents", agent_id, "sessions")
            if os.path.isdir(legacy):
                dirs.append(legacy)

    updated = 0
    for sess_dir in dirs:
        try:
            if _update_one_rollup(sess_dir):
                updated += 1
        except Exception:
            pass
    if updated:
        print(f"[sessions] stats rollup updated: {updated} agent(s)")


def _sync_sub_agent_models(config, sub_agents, all_models_map, fallback_models, primary_model):
    """Sync model assignments from main config to sub-agent configs.
    
    Reads the model for each agent from config.agents.list and writes it
    to the corresponding sub-agent profile config. This ensures webchat UI
    changes are propagated to sub-agents on every startup.
    """
    main_agent_models = {}
    for a in config.get("agents", {}).get("list", []):
        if a.get("model"):
            main_agent_models[a["id"]] = a["model"]

    for profile, agent_id in sub_agents.items():
        cfg_path = os.path.join(HOME, f".openclaw-{profile}", "openclaw.json")
        if not os.path.exists(cfg_path):
            continue
        try:
            with open(cfg_path, "r", encoding="utf-8-sig") as f:
                sub_cfg = json.load(f)

            effective_model = main_agent_models.get(agent_id) or primary_model

            # Fix agent name/emoji in sub-agent config (same protection as main config)
            for a in sub_cfg.get("agents", {}).get("list", []):
                if a.get("id") == agent_id:
                    correct_name = AGENT_NAMES.get(agent_id)
                    if correct_name and a.get("name") != correct_name:
                        a["name"] = correct_name
                    correct_emoji = AGENT_EMOJIS.get(agent_id)
                    if correct_emoji:
                        current_emoji = a.get("identity", {}).get("emoji", "")
                        if current_emoji != correct_emoji:
                            a.setdefault("identity", {})["emoji"] = correct_emoji
                    a["model"] = effective_model
                    break

            # Update sub-agent config
            sub_cfg.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})
            sub_cfg["agents"]["defaults"]["models"] = all_models_map
            sub_cfg["agents"]["defaults"]["model"]["fallbacks"] = fallback_models
            sub_cfg["agents"]["defaults"]["model"]["primary"] = effective_model

            with open(cfg_path, "w", encoding="utf-8") as f:
                json.dump(sub_cfg, f, indent=4, ensure_ascii=False)
        except Exception:
            pass


def _fetch_models(base_url, api_key=None, timeout=10):
    """Fetch models from an OpenAI-compatible /models endpoint."""
    try:
        url = base_url.rstrip("/") + "/models"
        req = urllib.request.Request(url)
        if api_key:
            req.add_header("Authorization", f"Bearer {api_key}")
        resp = json.loads(urllib.request.urlopen(req, timeout=timeout).read())

        models = []
        for m in resp.get("data", []):
            mid = m.get("id", "")
            # Skip virtual/alias models. GPT-5.6 is intentionally included in
            # the visible model list for manual selection, but excluded below
            # from automatic fallback selection.
            if mid.startswith("auto") or mid == "auto-kiro" or not mid:
                continue
            if m.get("metadata_source") != "upstream":
                return [], f"model metadata for {mid} is {m.get('metadata_source', 'missing')}; preserving existing configuration"
            context_window = m.get("context_window")
            max_tokens = m.get("max_tokens")
            input_modes = m.get("input")
            if not isinstance(context_window, int) or context_window <= 0:
                return [], f"model metadata for {mid} has no valid context_window; preserving existing configuration"
            if not isinstance(max_tokens, int) or max_tokens <= 0:
                return [], f"model metadata for {mid} has no valid max_tokens; preserving existing configuration"
            if not isinstance(input_modes, list) or not input_modes or not all(isinstance(mode, str) for mode in input_modes):
                return [], f"model metadata for {mid} has no valid input modes; preserving existing configuration"
            models.append({
                "id": mid,
                "name": m.get("name", mid),
                "reasoning": True,
                "input": input_modes,
                "contextWindow": context_window,
                "maxTokens": max_tokens,
            })
        return models, None
    except Exception as e:
        return [], str(e)


def sync():
    """Main sync logic."""
    # Session cleanup FIRST (before model sync, prevents zombie recovery on restart)
    try:
        _cleanup_sessions()
    except Exception as e:
        print(f"[sessions] cleanup error: {e}")

    # Stats rollup (B3): archive per-day stats so trimmed/deleted sessions don't lose history.
    # Runs AFTER cleanup so files trimmed this run are locked into stats-daily.json this run.
    try:
        _update_stats_rollups()
    except Exception as e:
        print(f"[sessions] stats rollup error: {e}")

    config = _load_config()

    # Fix agent names (encoding corruption from config.patch)
    if _fix_agent_names(config):
        # Save immediately so names are correct for this run
        with open(MAIN_CONFIG, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2, ensure_ascii=False)

    sub_agents = _load_sub_agents(config)
    sync_results = []

    # Read existing providers from config
    existing_providers = config.get("models", {}).get("providers", {})
    if not existing_providers:
        print("SKIP: no providers configured in openclaw.json")
        return

    # Fetch fresh model lists from each configured provider
    updated_providers = {}
    all_models_map = {}

    for provider_id, provider_cfg in existing_providers.items():
        base_url = provider_cfg.get("baseUrl", "")
        api_key = provider_cfg.get("apiKey", "")
        api_type = provider_cfg.get("api", "openai-completions")

        if not base_url:
            # No URL = skip (provider might be disabled or config-only)
            sync_results.append(f"SKIP {provider_id}: no baseUrl")
            continue

        # Try to fetch fresh models
        fresh_models, error = _fetch_models(base_url, api_key)

        if error:
            # Provider unreachable — keep existing models unchanged
            existing_models = provider_cfg.get("models", [])
            sync_results.append(
                f"WARN {provider_id}: {error} (keeping {len(existing_models)} existing models)"
            )
            updated_providers[provider_id] = provider_cfg  # Keep as-is
            for m in existing_models:
                all_models_map[f"{provider_id}/{m['id']}"] = {"alias": m["id"]}
        else:
            # Success — update models
            sync_results.append(f"OK {provider_id}: {len(fresh_models)} models")
            updated_providers[provider_id] = {
                "api": api_type,
                "models": fresh_models,
                "baseUrl": base_url,
            }
            if api_key:
                updated_providers[provider_id]["apiKey"] = api_key
            for m in fresh_models:
                all_models_map[f"{provider_id}/{m['id']}"] = {"alias": m["id"]}

    if not all_models_map:
        print("SKIP: no models available from any provider")
        return

    # Preserve the configured default when valid. If it disappeared, prefer the
    # dynamically configured main-agent model before falling back to the first model.
    current_primary = (
        config.get("agents", {}).get("defaults", {}).get("model", {}).get("primary", "")
    )
    main_agent_model = next(
        (
            agent.get("model", "")
            for agent in config.get("agents", {}).get("list", [])
            if agent.get("id") == "main"
        ),
        "",
    )
    all_model_ids = list(all_models_map.keys())

    if current_primary in all_model_ids:
        primary_model = current_primary
    elif main_agent_model in all_model_ids:
        primary_model = main_agent_model
    else:
        primary_model = all_model_ids[0] if all_model_ids else None

    # OpenClaw 运行时故障转移链：只取前 N 个，避免上游网络中断时逐一尝试全部模型
    # 造成数分钟卡顿（所有模型共用同一 kiro-gw/Kiro 后端，后端不可达时多余的 fallback 只会拖慢失败）。
    # GPT-5.6 remains visible for manual selection but is deliberately excluded
    # from automatic fallback because it is not part of the stable runtime path.
    # 注意：agents.defaults.models（完整模型表）仍保留全部，kiro-gw 的 FALLBACK_MODELS 也不受影响。
    fallback_models = [
        model_id
        for model_id in all_model_ids
        if model_id != primary_model
        and not model_id.rsplit("/", 1)[-1].lower().startswith("gpt-5.6")
    ][:MAX_FALLBACK_MODELS]

    # Check if anything changed
    old_models_map = config.get("agents", {}).get("defaults", {}).get("models", {})
    old_fallbacks = (
        config.get("agents", {}).get("defaults", {}).get("model", {}).get("fallbacks", [])
    )
    old_provider_model_ids = set()
    for p in existing_providers.values():
        for m in p.get("models", []):
            old_provider_model_ids.add(m.get("id", ""))
    new_provider_model_ids = set()
    for p in updated_providers.values():
        for m in p.get("models", []):
            new_provider_model_ids.add(m.get("id", ""))

    models_changed = (
        current_primary != primary_model
        or old_provider_model_ids != new_provider_model_ids
        or old_models_map != all_models_map
        or old_fallbacks != fallback_models
    )

    if not models_changed:
        primary_display = primary_model.split("/", 1)[1] if "/" in primary_model else primary_model
        print(f"OK:{len(all_models_map)}:{primary_display}:no_change")
        for r in sync_results:
            print(r)
        # Still sync sub-agent models (user may have changed via webchat)
        _sync_sub_agent_models(config, sub_agents, all_models_map, fallback_models, primary_model)
        return

    # === Update main config ===
    shutil.copy2(MAIN_CONFIG, BACKUP_PATH)

    config["models"]["providers"] = updated_providers

    # Update agents defaults
    config.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})
    config["agents"]["defaults"]["model"]["primary"] = primary_model
    config["agents"]["defaults"]["model"]["fallbacks"] = fallback_models
    config["agents"]["defaults"]["models"] = all_models_map

    # Save main config (atomic write)
    tmp_path = MAIN_CONFIG + ".tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2, ensure_ascii=False)
        # Verify
        with open(tmp_path, "r", encoding="utf-8") as f:
            verified = json.load(f)
        assert "models" in verified and "agents" in verified
        os.replace(tmp_path, MAIN_CONFIG)
    except Exception as e:
        if os.path.exists(BACKUP_PATH):
            shutil.copy2(BACKUP_PATH, MAIN_CONFIG)
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        print(f"FAIL: {e}")
        return

    # === Sync to sub-agent configs ===
    # Build agent_id -> model lookup from main config
    main_agent_models = {}
    for a in config.get("agents", {}).get("list", []):
        if a.get("model"):
            main_agent_models[a["id"]] = a["model"]

    sub_results = []
    for profile, agent_id in sub_agents.items():
        cfg_path = os.path.join(HOME, f".openclaw-{profile}", "openclaw.json")
        if not os.path.exists(cfg_path):
            sub_results.append(f"SKIP {profile}: config not found")
            continue
        try:
            with open(cfg_path, "r", encoding="utf-8-sig") as f:
                sub_cfg = json.load(f)

            # Use model from main config (user-managed, not hardcoded)
            effective_model = main_agent_models.get(agent_id) or primary_model
            model_source = "config"

            # Update sub-agent config
            sub_cfg.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})
            sub_cfg["agents"]["defaults"]["models"] = all_models_map
            sub_cfg["agents"]["defaults"]["model"]["fallbacks"] = fallback_models
            sub_cfg["agents"]["defaults"]["model"]["primary"] = effective_model

            # Always enforce correct model
            for a in sub_cfg.get("agents", {}).get("list", []):
                if a.get("id") == agent_id:
                    a["model"] = effective_model
                    break

            with open(cfg_path, "w", encoding="utf-8") as f:
                json.dump(sub_cfg, f, indent=4, ensure_ascii=False)

            model_parts = effective_model.split("/", 1)
            model_display = model_parts[1] if len(model_parts) > 1 else effective_model
            sub_results.append(
                f"OK {profile}: {len(all_models_map)} models (model={model_display}, src={model_source})"
            )
        except Exception as e:
            sub_results.append(f"FAIL {profile}: {e}")

    # Output
    token = config.get("gateway", {}).get("auth", {}).get("token", "")
    primary_display = primary_model.split("/", 1)[1] if "/" in primary_model else primary_model
    print(f"OK:{len(all_models_map)}:{primary_display}:{token}")
    for r in sync_results:
        print(r)
    for r in sub_results:
        print(r)


if __name__ == "__main__":
    sync()
