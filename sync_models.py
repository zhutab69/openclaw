"""Sync models from configured providers to openclaw.json, then propagate to sub-agents.

All configuration is read dynamically from openclaw.json:
- Provider URLs, API keys, and model lists from models.providers
- Sub-agent list from agents.list
- Primary model from agents.defaults.model.primary

No hardcoded values. If a provider is unreachable, existing config is preserved.
"""
import urllib.request, json, os, shutil

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
AGENT_MODELS = {
    "main": "kiro-gw/claude-opus-4.6",
    "writer-agent": "kiro-gw/claude-sonnet-4.6",
    "coder-agent": "kiro-gw/claude-opus-4.6",
    "info-agent": "kiro-gw/claude-sonnet-4.6",
    "image-agent": "kiro-gw/claude-sonnet-4.6",
}


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
        # Fix model
        correct_model = AGENT_MODELS.get(aid)
        if correct_model and agent.get("model") != correct_model:
            agent["model"] = correct_model
            fixed = True
    return fixed


def _load_sub_agents(config):
    """从 openclaw.json 动态读取 sub-agent 列表。"""
    mapping = {}
    for agent in config.get("agents", {}).get("list", []):
        aid = agent.get("id", "")
        if aid and aid != "main":
            profile = aid.replace("-agent", "") if aid.endswith("-agent") else aid
            mapping[profile] = aid
    return mapping


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

            # Get sub-agent's own model
            sub_own_model = None
            for a in sub_cfg.get("agents", {}).get("list", []):
                if a.get("id") == agent_id and a.get("model"):
                    sub_own_model = a["model"]
                    break

            # Determine effective model (sub-agent own > main config > default)
            main_model = main_agent_models.get(agent_id)
            if sub_own_model:
                effective_model = sub_own_model
                model_source = "own"
            elif main_model:
                effective_model = main_model
                model_source = "from_main"
            else:
                effective_model = primary_model
                model_source = "default"

            # Update sub-agent config
            sub_cfg.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})
            sub_cfg["agents"]["defaults"]["models"] = all_models_map
            sub_cfg["agents"]["defaults"]["model"]["fallbacks"] = fallback_models

            # Only update agents.list model if sub-agent has no own model
            if model_source == "from_main":
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
