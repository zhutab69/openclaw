"""Sync models from multiple providers to openclaw.json, then propagate to sub-agents.

Supported providers:
1. kiro-gw: Kiro Gateway (port 9000)
2. trae-gw: Trae Gateway (port 9010) - Trae 内置模型代理
3. direct: OpenClaw native providers (anthropic, openai, etc.)

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

# Direct provider models (OpenClaw native, no gateway)
DIRECT_PROVIDERS = {
    "anthropic": {
        "api": "anthropic-messages",
        "baseUrl": "https://api.anthropic.com/v1",
        "models": [
            {"id": "claude-3-5-sonnet-20241022", "name": "Claude 3.5 Sonnet", "contextWindow": 200000, "maxTokens": 8192},
            {"id": "claude-3-5-haiku-20241022", "name": "Claude 3.5 Haiku", "contextWindow": 200000, "maxTokens": 8192},
            {"id": "claude-3-opus-20240229", "name": "Claude 3 Opus", "contextWindow": 200000, "maxTokens": 4096},
        ]
    },
    "openai": {
        "api": "openai-completions",
        "baseUrl": "https://api.openai.com/v1",
        "models": [
            {"id": "gpt-4-turbo", "name": "GPT-4 Turbo", "contextWindow": 128000, "maxTokens": 4096},
            {"id": "gpt-4", "name": "GPT-4", "contextWindow": 8192, "maxTokens": 4096},
            {"id": "gpt-3.5-turbo", "name": "GPT-3.5 Turbo", "contextWindow": 16385, "maxTokens": 4096},
        ]
    }
}

def fetch_gateway_models(gateway_url, gateway_name, auth_token=None):
    """Fetch models from a gateway (Kiro or Trae)."""
    try:
        req = urllib.request.Request(f"{gateway_url}/models")
        if auth_token:
            req.add_header("Authorization", f"Bearer {auth_token}")
        resp = json.loads(urllib.request.urlopen(req, timeout=10).read())
        
        models = []
        for m in resp["data"]:
            models.append({
                "id": m["id"],
                "name": m.get("name", m["id"]),
                "reasoning": True,
                "input": ["text", "image"],
                "contextWindow": m.get("context_window", 200000),
                "maxTokens": m.get("max_tokens", 64000)
            })
        
        return models, None
    except Exception as e:
        return [], str(e)

# === Step 1: Fetch models from all providers ===
all_providers = {}
all_models_map = {}
sync_results = []

# 1.1 Kiro Gateway
kiro_models, kiro_error = fetch_gateway_models(
    "http://127.0.0.1:9000/v1",
    "kiro-gw",
    "my-super-secret-password-123"
)
if kiro_error:
    sync_results.append(f"WARN kiro-gw: {kiro_error}")
else:
    all_providers["kiro-gw"] = {
        "api": "openai-completions",
        "baseUrl": "http://127.0.0.1:9000/v1",
        "models": kiro_models
    }
    for m in kiro_models:
        all_models_map[f"kiro-gw/{m['id']}"] = {"alias": m["id"]}
    sync_results.append(f"OK kiro-gw: {len(kiro_models)} models")

# 1.2 Trae Gateway (使用 Trae 内置模型列表)
# 注意：这些是 Trae 文档中列出的内置模型
# API 端点需要通过抓包 Trae CN 应用来确定
trae_builtin_models = [
    {"id": "doubao-seed-2.0-code", "name": "Doubao Seed 2.0 Code", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "doubao-seed-1.8", "name": "Doubao Seed 1.8", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "doubao-seed-code", "name": "Doubao Seed Code", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "minimax-m2.7", "name": "MiniMax M2.7", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "minimax-m2.5", "name": "MiniMax M2.5", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "glm-5.1", "name": "GLM 5.1", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "glm-5v-turbo", "name": "GLM 5V Turbo", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "glm-5", "name": "GLM 5", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "deepseek-v3.1-terminus", "name": "DeepSeek V3.1 Terminus", "reasoning": True, "input": ["text"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "kimi-k2.5", "name": "Kimi K2.5", "reasoning": True, "input": ["text"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "qwen3.5-plus", "name": "Qwen 3.5 Plus", "reasoning": True, "input": ["text"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "qwen3-coder-next", "name": "Qwen 3 Coder Next", "reasoning": True, "input": ["text"], "contextWindow": 200000, "maxTokens": 64000},
]

# 尝试从 Trae Gateway 获取模型（如果运行中）
trae_models, trae_error = fetch_gateway_models(
    "http://127.0.0.1:9010/v1",
    "trae-gw",
    "trae-super-secret-password-456"  # 添加正确的认证 token
)

# 如果 Gateway 未运行或失败，使用内置模型列表
if trae_error:
    sync_results.append(f"INFO trae-gw: Using builtin models ({trae_error})")
    trae_models = trae_builtin_models

# 添加 Trae Gateway provider
all_providers["trae-gw"] = {
    "api": "openai-completions",
    "baseUrl": "http://127.0.0.1:9010/v1",
    "models": trae_models
}
for m in trae_models:
    all_models_map[f"trae-gw/{m['id']}"] = {"alias": m["id"]}
sync_results.append(f"OK trae-gw: {len(trae_models)} models")

# 1.3 Direct providers
for provider_id, provider_info in DIRECT_PROVIDERS.items():
    all_providers[provider_id] = provider_info
    for m in provider_info["models"]:
        all_models_map[f"{provider_id}/{m['id']}"] = {"alias": m["id"]}
    sync_results.append(f"OK {provider_id}: {len(provider_info['models'])} models")

# Determine primary model and fallbacks
# Priority: kiro-gw > trae-gw > anthropic > openai
all_model_ids = list(all_models_map.keys())
primary_model = None
fallback_models = []

# Try to find claude-sonnet-4.5 in gateways first
for prefix in ["kiro-gw", "trae-gw"]:
    candidate = f"{prefix}/claude-sonnet-4.5"
    if candidate in all_model_ids:
        primary_model = candidate
        break

# If not found, use first available model
if not primary_model and all_model_ids:
    primary_model = all_model_ids[0]

# Build fallbacks list (exclude primary)
if primary_model:
    fallback_models = [m for m in all_model_ids if m != primary_model]

# === Step 2: Update main openclaw.json ===
with open(MAIN_CONFIG, "r", encoding="utf-8-sig") as f:
    config = json.load(f)

# Check if models or provider config changed
models_changed = False
if "models" not in config:
    config["models"] = {"providers": {}}
    models_changed = True

for provider_id, provider_data in all_providers.items():
    current_provider = config["models"]["providers"].get(provider_id, {})
    current_models = current_provider.get("models", [])
    current_ids = [m["id"] for m in current_models]
    new_ids = [m["id"] for m in provider_data["models"]]
    
    # Check if models changed
    if set(current_ids) != set(new_ids):
        models_changed = True
        break
    
    # Check if api/baseUrl changed
    current_api = current_provider.get("api")
    current_baseUrl = current_provider.get("baseUrl")
    new_api = provider_data.get("api")
    new_baseUrl = provider_data.get("baseUrl")
    
    if current_api != new_api or current_baseUrl != new_baseUrl:
        models_changed = True
        break

if models_changed:
    shutil.copy2(MAIN_CONFIG, BACKUP_PATH)
    
    # Update all providers
    for provider_id, provider_data in all_providers.items():
        if provider_id not in config["models"]["providers"]:
            config["models"]["providers"][provider_id] = {}
        
        # Clear old structure and rebuild
        provider_config = config["models"]["providers"][provider_id]
        
        # Keep apiKey if exists (for kiro-gw)
        api_key = provider_config.get("apiKey")
        
        # Rebuild provider config with correct structure
        config["models"]["providers"][provider_id] = {
            "api": provider_data["api"],
            "models": provider_data["models"]
        }
        
        # Add baseUrl if present
        if "baseUrl" in provider_data:
            config["models"]["providers"][provider_id]["baseUrl"] = provider_data["baseUrl"]
        
        # Restore apiKey if it existed
        if api_key:
            config["models"]["providers"][provider_id]["apiKey"] = api_key

# Update agents defaults
if "agents" not in config:
    config["agents"] = {}
if "defaults" not in config["agents"]:
    config["agents"]["defaults"] = {}
if "model" not in config["agents"]["defaults"]:
    config["agents"]["defaults"]["model"] = {}

config["agents"]["defaults"]["model"]["primary"] = primary_model
config["agents"]["defaults"]["model"]["fallbacks"] = fallback_models
config["agents"]["defaults"]["models"] = all_models_map

# Save main config
tmp_path = MAIN_CONFIG + ".tmp"
try:
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    with open(tmp_path, "r", encoding="utf-8") as f:
        verified = json.load(f)
    assert "models" in verified and "agents" in verified
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

        # Determine effective model
        if sub_own_model:
            effective_model = sub_own_model
            model_source = "own"
        elif main_model:
            effective_model = main_model
            model_source = "from_main"
        else:
            effective_model = primary_model
            model_source = "default"

        # Check if anything needs updating
        cur_models = sub_cfg.get("agents", {}).get("defaults", {}).get("models", {})
        cur_fallbacks = sub_cfg.get("agents", {}).get("defaults", {}).get("model", {}).get("fallbacks", [])
        needs_update = (
            cur_models != all_models_map or
            cur_fallbacks != fallback_models or
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

        # Extract provider and model name for display
        model_parts = effective_model.split("/", 1)
        model_display = model_parts[1] if len(model_parts) > 1 else effective_model
        sub_results.append(f"OK {profile}: synced {len(all_models_map)} models (model={model_display}, source={model_source})")
    except Exception as e:
        sub_results.append(f"FAIL {profile}: {e}")

# Output results
primary_display = primary_model.split("/", 1)[1] if primary_model and "/" in primary_model else primary_model
print(f"OK:{len(all_models_map)}:{primary_display}:{token}")
for r in sync_results:
    print(r)
for r in sub_results:
    print(r)
