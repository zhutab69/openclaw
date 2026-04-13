"""Sync Kiro Gateway models to main openclaw.json, then propagate to sub-agents.

Priority rules:
- Sub-agent profile's own model (agents.list[0].model) takes highest priority
- Main config's sub-agent model is used as default only if sub-agent has no own model set
- models_map and fallbacks are always synced (these are the available model list, not the chosen model)
"""
import urllib.request, json, os, shutil

HOME = os.environ["USERPROFILE"]
MAIN_CONFIG = os.path.join(HOME, ".openclaw", "openclaw.json")
BACKUP_PATH = MAIN_CONFIG + ".sync-bak"

# Profile -> agent_id mapping
SUB_AGENTS = {
    "writer": "writer-agent",
    "dev":    "dev-agent",
    "info":   "info-agent",
    "image":  "image-agent",
}

# === Step 1: Fetch models from Kiro Gateway ===
req = urllib.request.Request("http://127.0.0.1:9000/v1/models")
req.add_header("Authorization", "Bearer my-super-secret-password-123")
resp = json.loads(urllib.request.urlopen(req, timeout=10).read())

models = []
for m in resp["data"]:
    models.append({
        "id": m["id"], "name": m["id"], "reasoning": True,
        "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000
    })

all_ids = [m["id"] for m in models]
primary = "claude-sonnet-4.5" if "claude-sonnet-4.5" in all_ids else all_ids[0]
fallbacks = [i for i in all_ids if i != primary]
models_map = {f"kiro-gw/{i}": {"alias": i} for i in all_ids}

# === Step 2: Update main openclaw.json ===
with open(MAIN_CONFIG, "r", encoding="utf-8-sig") as f:
    config = json.load(f)

current_ids = [m["id"] for m in config["models"]["providers"]["kiro-gw"].get("models", [])]
models_changed = set(current_ids) != set(all_ids)

if models_changed:
    shutil.copy2(MAIN_CONFIG, BACKUP_PATH)
    config["models"]["providers"]["kiro-gw"]["models"] = models

config["agents"]["defaults"]["model"]["primary"] = f"kiro-gw/{primary}"
config["agents"]["defaults"]["model"]["fallbacks"] = [f"kiro-gw/{i}" for i in fallbacks]
config["agents"]["defaults"]["models"] = models_map

tmp_path = MAIN_CONFIG + ".tmp"
try:
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    with open(tmp_path, "r", encoding="utf-8") as f:
        verified = json.load(f)
    assert "models" in verified and "gateway" in verified and "agents" in verified
    os.replace(tmp_path, MAIN_CONFIG)
except Exception as e:
    if os.path.exists(BACKUP_PATH):
        shutil.copy2(BACKUP_PATH, MAIN_CONFIG)
    if os.path.exists(tmp_path):
        os.remove(tmp_path)
    print(f"FAIL:{e}")
    exit(1)

token = config.get("gateway", {}).get("auth", {}).get("token", "")

# Build a lookup: agent_id -> model from main config's agents.list
main_agent_models = {}
for a in config.get("agents", {}).get("list", []):
    if a.get("model"):
        main_agent_models[a["id"]] = a["model"]

# === Step 3: Sync to sub-agent configs ===
# Priority: sub-agent's own model > main config's model for that agent
sub_results = []
for profile, agent_id in SUB_AGENTS.items():
    cfg_path = os.path.join(HOME, f".openclaw-{profile}", "openclaw.json")
    if not os.path.exists(cfg_path):
        sub_results.append(f"SKIP {profile}: config not found")
        continue
    try:
        with open(cfg_path, "r", encoding="utf-8-sig") as f:
            sub_cfg = json.load(f)

        # Get sub-agent's own current model
        sub_own_model = None
        for a in sub_cfg.get("agents", {}).get("list", []):
            if a.get("id") == agent_id and a.get("model"):
                sub_own_model = a["model"]
                break

        # Get main config's model for this agent (as default)
        main_model = main_agent_models.get(agent_id)

        # Determine effective model:
        # - If sub-agent has its own model set → keep it (highest priority)
        # - If sub-agent has no model → use main config's model as default
        if sub_own_model:
            effective_model = sub_own_model
            model_source = "own"
        elif main_model:
            effective_model = main_model
            model_source = "from_main"
        else:
            effective_model = f"kiro-gw/{primary}"
            model_source = "default"

        # Check if anything needs updating
        cur_models = sub_cfg.get("agents", {}).get("defaults", {}).get("models", {})
        cur_fallbacks = sub_cfg.get("agents", {}).get("defaults", {}).get("model", {}).get("fallbacks", [])
        needs_update = (
            cur_models != models_map or
            cur_fallbacks != [f"kiro-gw/{i}" for i in fallbacks] or
            (model_source == "from_main" and sub_own_model != effective_model)
        )

        if not needs_update and not models_changed:
            sub_results.append(f"SKIP {profile}: no change")
            continue

        # Ensure structure
        if "agents" not in sub_cfg:
            sub_cfg["agents"] = {}
        if "defaults" not in sub_cfg["agents"]:
            sub_cfg["agents"]["defaults"] = {}
        if "model" not in sub_cfg["agents"]["defaults"]:
            sub_cfg["agents"]["defaults"]["model"] = {}

        # Always update available models list and fallbacks
        sub_cfg["agents"]["defaults"]["models"] = models_map
        sub_cfg["agents"]["defaults"]["model"]["fallbacks"] = [f"kiro-gw/{i}" for i in fallbacks]

        # Only update agents.list model if sub-agent has no own model (use main as default)
        if model_source == "from_main":
            for a in sub_cfg.get("agents", {}).get("list", []):
                if a.get("id") == agent_id:
                    a["model"] = effective_model
                    break

        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(sub_cfg, f, indent=4, ensure_ascii=False)

        model_display = effective_model.replace("kiro-gw/", "")
        sub_results.append(f"OK {profile}: synced {len(models_map)} models (model={model_display}, source={model_source})")
    except Exception as e:
        sub_results.append(f"FAIL {profile}: {e}")

print(f"OK:{len(models)}:{primary}:{token}")
for r in sub_results:
    print(r)
