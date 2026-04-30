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

# 从主配置动态读取 sub-agent 列表
# Profile -> agent_id 映射从 agents.list 自动生成
def _load_sub_agents():
    """从 openclaw.json 动态读取 sub-agent 列表，不硬编码。"""
    try:
        with open(MAIN_CONFIG, "r", encoding="utf-8-sig") as f:
            cfg = json.load(f)
        mapping = {}
        for agent in cfg.get("agents", {}).get("list", []):
            aid = agent.get("id", "")
            if aid and aid != "main":
                # 从 agent id 提取 profile 名称（去掉 -agent 后缀）
                profile = aid.replace("-agent", "") if aid.endswith("-agent") else aid
                mapping[profile] = aid
        return mapping if mapping else None
    except Exception:
        return None

SUB_AGENTS = _load_sub_agents() or {
    # Fallback：仅在配置文件不可读时使用
    "writer": "writer-agent",
    "coder":  "coder-agent",
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
            # 跳过非真实模型（如 auto-kiro、auto 等别名/虚拟模型）
            mid = m["id"]
            if mid.startswith("auto") or mid == "auto-kiro":
                continue
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

# 1.2 Volcengine Ark (火山引擎方舟) - 直连火山引擎 API
VOLCENGINE_ARK_BASEURL = "https://ark.cn-beijing.volces.com/api/v3"
VOLCENGINE_ARK_APIKEY = "f3684480-c0d1-4a97-a2b3-41b86d226d46"

def fetch_volcengine_models(base_url, api_key):
    """从火山引擎 API 动态获取已开通的模型列表。"""
    import ssl
    ctx = ssl.create_default_context()
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}

    # Step 1: 获取所有可用模型
    try:
        req = urllib.request.Request(f"{base_url}/models", headers=headers)
        resp = urllib.request.urlopen(req, timeout=15, context=ctx)
        data = json.loads(resp.read().decode("utf-8"))
        all_models = data.get("data", [])
    except Exception as e:
        return [], f"Failed to list models: {e}"

    if not all_models:
        return [], "No models returned from API"

    # Step 2: 过滤出 chat 类模型（排除 embedding、image、video 等）
    skip_keywords = ["embedding", "seedance", "seedream", "seededit", "seed3d",
                     "wan2", "vision-lite", "ui-tars", "character", "translation",
                     "smart-router", "seaweed", "pretrain", "browsing", "functioncall",
                     "mistral", "vision-pro"]
    chat_model_ids = []
    for m in all_models:
        mid = m.get("id", "")
        if any(kw in mid for kw in skip_keywords):
            continue
        chat_model_ids.append(mid)

    # Step 3: 并发探测模型是否已开通
    # 策略：发送无效请求（空 messages），根据错误码判断：
    #   - 404 ModelNotOpen/NotFound = 未开通
    #   - 400 InvalidParameter = 已开通（参数错误说明模型存在）
    #   - 200 = 已开通
    #   - 429 = 已开通（限流）
    import concurrent.futures
    
    def probe_model(mid):
        # 发送空 messages 触发 400 而非实际推理，速度极快
        payload = json.dumps({
            "model": mid,
            "messages": [],
            "max_tokens": 1,
        }).encode("utf-8")
        try:
            req = urllib.request.Request(f"{base_url}/chat/completions",
                                        data=payload, headers=headers, method="POST")
            # 减少单个请求超时从 15s 到 5s
            resp = urllib.request.urlopen(req, timeout=5, context=ctx)
            # 200 = 模型存在且可用（不太可能空 messages 返回 200，但以防万一）
            return mid
        except urllib.error.HTTPError as e:
            code = e.code
            body = ""
            try: body = e.read().decode("utf-8")
            except: pass
            if code == 404:
                # ModelNotOpen 或 NotFound = 未开通
                return None
            if code in (400, 422, 429):
                # 400 InvalidParameter / 422 / 429 RateLimit = 模型存在
                return mid
            return None
        except Exception:
            return None

    available_ids = set()
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as executor:
        futures = {executor.submit(probe_model, mid): mid for mid in chat_model_ids}
        # 减少超时时间从 90s 到 15s，加快启动速度
        done, pending = concurrent.futures.wait(futures, timeout=15)
        
        # 取消未完成的任务
        for future in pending:
            future.cancel()
        
        for future in done:
            try:
                result = future.result(timeout=0.1)
                if result:
                    available_ids.add(result)
            except Exception:
                pass
    
    # 构建模型列表
    opened_models = []
    for mid in sorted(available_ids):
        is_reasoning = "thinking" in mid or "seed" in mid or "r1" in mid
        opened_models.append({
            "id": mid,
            "name": mid,
            "reasoning": is_reasoning,
            "input": ["text"],
            "contextWindow": 200000 if "doubao" in mid else 128000,
            "maxTokens": 64000 if "doubao" in mid else 8192,
        })

    return opened_models, None

trae_models, trae_error = fetch_volcengine_models(VOLCENGINE_ARK_BASEURL, VOLCENGINE_ARK_APIKEY)
if trae_error:
    sync_results.append(f"WARN trae-gw: {trae_error}")
else:
    sync_results.append(f"OK trae-gw: {len(trae_models)} models (Volcengine Ark, dynamic)")

# 添加 Volcengine Ark provider (保留 trae-gw 名称以兼容现有配置)
if trae_models:
    all_providers["trae-gw"] = {
        "api": "openai-completions",
        "baseUrl": VOLCENGINE_ARK_BASEURL,
        "apiKey": VOLCENGINE_ARK_APIKEY,
        "models": trae_models
    }
    for m in trae_models:
        all_models_map[f"trae-gw/{m['id']}"] = {"alias": m["name"]}

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
    
    # Check if api/baseUrl/apiKey changed
    current_api = current_provider.get("api")
    current_baseUrl = current_provider.get("baseUrl")
    current_apiKey = current_provider.get("apiKey")
    new_api = provider_data.get("api")
    new_baseUrl = provider_data.get("baseUrl")
    new_apiKey = provider_data.get("apiKey")
    
    if current_api != new_api or current_baseUrl != new_baseUrl or current_apiKey != new_apiKey:
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
        
        # Keep apiKey from provider_data (source of truth), fallback to existing config
        api_key = provider_data.get("apiKey") or provider_config.get("apiKey")
        
        # Rebuild provider config with correct structure
        config["models"]["providers"][provider_id] = {
            "api": provider_data["api"],
            "models": provider_data["models"]
        }
        
        # Add baseUrl if present
        if "baseUrl" in provider_data:
            config["models"]["providers"][provider_id]["baseUrl"] = provider_data["baseUrl"]
        
        # Restore/set apiKey if it existed
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
