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
SESSION_MAX_FILES = 50

# Session keys that should be reset (new session created) on startup
# These are "sticky" sessions that OpenClaw reuses for webchat/wecom
STICKY_SESSION_KEYS = ["agent:main:main"]

# Sticky session is reset if older than this (seconds)
STICKY_RESET_AGE_S = 4 * 3600  # 4 hours

# Sticky session with pendingFinalDelivery is removed if pending older than this
PENDING_DELIVERY_MAX_AGE_S = 30 * 60  # 30 minutes

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

                        # Rule 3: sticky sessions (webchat main) - reset if stale
                        # This prevents OpenClaw from reusing old sessions that may be corrupted
                        if key in STICKY_SESSION_KEYS and last_active > 0:
                            age_ms = now_ms - last_active
                            if age_ms > STICKY_RESET_AGE_S * 1000:
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
    if total_deleted:
        parts.append(f"trimmed={total_deleted}")
    if total_locks:
        parts.append(f"locks={total_locks}")
    if parts:
        print(f"[sessions] cleanup: {', '.join(parts)}")


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

            # Update sub-agent config
            sub_cfg.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})
            sub_cfg["agents"]["defaults"]["models"] = all_models_map
            sub_cfg["agents"]["defaults"]["model"]["fallbacks"] = fallback_models

            # Sync model from main config
            for a in sub_cfg.get("agents", {}).get("list", []):
                if a.get("id") == agent_id:
                    a["model"] = effective_model
                    break

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
            # Skip virtual/alias models
            if mid.startswith("auto") or mid == "auto-kiro" or not mid:
                continue
            models.append({
                "id": mid,
                "name": m.get("name", mid),
                "reasoning": True,
                "input": ["text", "image"],
                "contextWindow": m.get("context_window", 200000),
                "maxTokens": m.get("max_tokens", 64000),
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

    config = _load_config()

    # Fix agent names (encoding corruption from config.patch)
    if _fix_agent_names(config):
        # Save immediately so names are correct for this run
        with open(MAIN_CONFIG, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2, ensure_ascii=False)

    # Also protect defaults.model.primary
    defaults_primary = config.get("agents", {}).get("defaults", {}).get("model", {}).get("primary", "")
    if defaults_primary != "kiro-gw/claude-sonnet-4.6":
        config.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})["primary"] = "kiro-gw/claude-sonnet-4.6"
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

    # Determine primary model and fallbacks
    # Use existing primary if still valid, otherwise pick first available
    current_primary = (
        config.get("agents", {}).get("defaults", {}).get("model", {}).get("primary", "")
    )
    all_model_ids = list(all_models_map.keys())

    if current_primary in all_model_ids:
        primary_model = current_primary
    else:
        # Current primary no longer available, pick first
        primary_model = all_model_ids[0] if all_model_ids else None

    fallback_models = [m for m in all_model_ids if m != primary_model]

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
        old_provider_model_ids != new_provider_model_ids
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
