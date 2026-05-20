# OpenClaw 升级优化指南

> 记录 OpenClaw 2026.3.13 → 2026.5.7 升级后的所有优化操作，供下次升级参考。

## 升级概览

| 项目 | 旧版本 | 新版本 |
|------|--------|--------|
| OpenClaw | 2026.3.13 | 2026.5.7 |
| openclaw-weixin | 1.0.3 | 2.4.3 |
| wecom-openclaw-plugin | 2026.3.26 | 2026.5.14 |
| Node.js | 22.22.1 | 22.22.1 (不变) |

---

## 一、性能优化（最重要）

### 1.1 移除 OPENCLAW_SKIP_STARTUP_MODEL_PREWARM

**问题**：设置此环境变量后，启动时跳过模型预热，导致每次请求都触发 `ensureOpenClawModelsJson` → `resolveImplicitProviders` → `runProviderCatalogWithTimeout(timeoutMs=null)` 无超时等待，耗时 20-30s。

**修复**：从 `OpenClaw.ps1` 中移除所有 `OPENCLAW_SKIP_STARTUP_MODEL_PREWARM=1`。

**效果**：webchat 加载从 88s → 55s，每次对话请求减少 20-30s。

**注意**：启动时间不会增加（model prewarm 与 plugin 加载并行）。

```powershell
# ❌ 错误 - 不要设置这个
$env:OPENCLAW_SKIP_STARTUP_MODEL_PREWARM = "1"

# ✅ 正确 - 让 OpenClaw 自行预热模型
# (不设置该环境变量)
```

### 1.2 清理 models.json 中的无效 providers

**问题**：`~/.openclaw/agents/*/agent/models.json` 中残留旧版本的 providers（ollama、litellm、anthropic、openai、trae-gw），导致 auth 阶段对每个不可达 provider 超时。

**修复脚本**：

```python
"""清理 models.json - 只保留 openclaw.json 中配置的 providers"""
import os, json, glob, shutil

home = os.environ["USERPROFILE"]
patterns = [
    os.path.join(home, ".openclaw", "agents", "*", "agent", "models.json"),
    os.path.join(home, ".openclaw-*", "agents", "*", "agent", "models.json"),
]

# 从 openclaw.json 读取有效 providers
cfg_path = os.path.join(home, ".openclaw", "openclaw.json")
with open(cfg_path, "r", encoding="utf-8-sig") as f:
    cfg = json.load(f)
valid_providers = set(cfg.get("models", {}).get("providers", {}).keys())

for pattern in patterns:
    for fp in glob.glob(pattern):
        with open(fp, "r", encoding="utf-8") as f:
            data = json.load(f)
        providers = data.get("providers", {})
        # 只保留有效 providers
        cleaned = {k: v for k, v in providers.items() if k in valid_providers}
        if len(cleaned) < len(providers):
            shutil.copy2(fp, fp + ".bak")
            with open(fp, "w", encoding="utf-8") as f:
                json.dump({"providers": cleaned}, f, indent=2, ensure_ascii=False)
            print(f"Fixed: {fp}")
```

**效果**：auth 阶段从 18-21s → 0.5-0.9s。

**升级后必做**：每次升级后运行此脚本，或确认 `openclaw.json` 中只有实际使用的 providers。

### 1.3 禁用 Kiro Gateway 的 FAKE_REASONING

**问题**：Kiro Gateway 默认注入 `<thinking_mode>enabled</thinking_mode>` 标签，而 OpenClaw 2026.5.7 自带 `thinking=medium` 模式，两者叠加导致双重 thinking 开销。

**修复**：在 `kiro-gateway/.env` 中添加：

```env
FAKE_REASONING=off
FIRST_TOKEN_TIMEOUT=12
```

**效果**：每次请求减少 ~1.5s，prompt tokens 减少 ~300。

**升级后必做**：确认 `.env` 中 `FAKE_REASONING=off`。

### 1.4 Preflight Cache TTL 补丁

**文件**：`node_modules/openclaw/dist/model-preflight.runtime-*.js`

**修改**：将 `PREFLIGHT_CACHE_TTL_MS` 从 `5 * 6e4`（5分钟）改为 `60 * 6e4`（60分钟）。

```javascript
// 找到这一行：
const PREFLIGHT_CACHE_TTL_MS = 5 * 6e4;
// 改为：
const PREFLIGHT_CACHE_TTL_MS = 60 * 6e4;
```

**注意**：此补丁在 `npm install` 或升级后会丢失，需要重新应用。

**查找文件**：
```powershell
Get-ChildItem "node_modules\openclaw\dist" -Filter "model-preflight.runtime-*.js"
```

### 1.5 Update Check 补丁

**文件**：`node_modules/openclaw/dist/update-startup-*.js`

**修改**：将 `UPDATE_CHECK_INTERVAL_MS` 改为 24 天（不能超过 2^31-1 ms ≈ 24.8天，否则 setTimeout 溢出）。

```javascript
// 找到这一行：
const UPDATE_CHECK_INTERVAL_MS = 24 * 3600 * 1e3;
// 改为：
const UPDATE_CHECK_INTERVAL_MS = 24 * 864e5;
```

**注意**：不能设为 365 天！`setTimeout` 最大值是 2^31-1 = 2147483647ms ≈ 24.8天，超过会溢出为 1ms 并刷屏 `TimeoutOverflowWarning`。

### 1.6 Provider Discovery Timeout 补丁（最关键！）

**文件**：`node_modules/openclaw/dist/models-config-*.js`

**问题**：`resolveImplicitProviders` 函数会对所有 bundled provider extensions（96个中的活跃部分，约 8-9 个）执行 catalog 操作。每个操作无超时，导致 model-resolution 耗时 30-42s。

**修改方案（二选一，推荐方案 A）**：

**方案 A（推荐）：跳过隐式 provider discovery**

```javascript
// 找到这一行：
async function resolveImplicitProviders(params) {
	const providers = {};
// 改为（在 const providers 前插入 early return）：
async function resolveImplicitProviders(params) {
	const env = params.env ?? process.env;
	if (!(env.OPENCLAW_LIVE_TEST === "1" || env.OPENCLAW_LIVE_GATEWAY === "1" || env.LIVE === "1")) return {};
	const providers = {};
```

**安全性**：我们只使用 `openclaw.json` 中显式配置的 `kiro-gw` provider，不需要隐式发现。

**方案 B（备选）：给每个 provider catalog 加超时**

```javascript
// 找到 runProviderCatalogWithTimeout 函数内：
const timeoutMs = params.timeoutMs ?? void 0;
// 改为：
const timeoutMs = params.timeoutMs ?? 5000;
```

注意：方案 B 仍会等待 N×5s（N=活跃 provider 数），方案 A 直接跳过整个 discovery。

**效果**：model-resolution 从 30-42s → <1s。

**查找文件**：
```powershell
Get-ChildItem "node_modules\openclaw\dist" -Filter "models-config-*.js" |
  Where-Object { $_.Length -gt 10000 }
```

---

## 二、配置修复

### 2.1 Gateway Auth 配置

```json
{
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "token",          // 主 agent 必须用 token（browser 工具需要 sharedAuthOk）
      "token": "<your-token>"
    },
    "controlUi": {
      "allowInsecureAuth": true
    }
  }
}
```

**子 agent 配置**（`.openclaw-writer/openclaw.json` 等）：
```json
{
  "gateway": {
    "auth": {
      "mode": "none"  // 子 agent 必须用 none（bot review/multi-agent 面板无法传 token）
    }
  }
}
```

### 2.2 Exec Approvals

**文件**：`~/.openclaw/exec-approvals.json`

```json
{
  "version": 1,
  "defaults": {
    "security": "full",
    "ask": "off",
    "autoAllowSkills": true
  },
  "agents": {
    "main": { "security": "full", "ask": "off", "autoAllowSkills": true },
    "writer-agent": { "security": "full", "ask": "off", "autoAllowSkills": true },
    "coder-agent": { "security": "full", "ask": "off", "autoAllowSkills": true },
    "info-agent": { "security": "full", "ask": "off", "autoAllowSkills": true },
    "image-agent": { "security": "full", "ask": "off", "autoAllowSkills": true }
  }
}
```

### 2.3 Plugin 配置

```json
{
  "plugins": {
    "entries": {
      "openclaw-weixin": { "enabled": true },
      "browser": { "enabled": true },
      "wecom-openclaw-plugin": { "enabled": true },
      "memory-core": { "enabled": false }
    },
    "bundledDiscovery": "allowlist",
    "allow": ["wecom-openclaw-plugin", "openclaw-weixin", "browser"]
  }
}
```

**关键**：`bundledDiscovery: "allowlist"` 限制只加载必要的 bundled plugins，减少启动时间。

### 2.4 openclaw-weixin Channel 配置

```json
{
  "channels": {
    "openclaw-weixin": {
      "enabled": true,
      "baseUrl": "https://ilinkai.weixin.qq.com",
      "pollIntervalMs": 5000,
      "retryBackoffMs": 10000,
      "maxRetryBackoffMs": 60000,
      "cdnBaseUrl": "https://ilinkai.weixin.qq.com"
    }
  }
}
```

### 2.5 禁止的配置字段（会导致启动失败）

OpenClaw 2026.5.7 有严格的 schema 验证，以下字段**不存在**：
- ❌ `agents.defaults.thinking` — thinking 模式只能在 webchat UI 中设置
- ❌ `browser.profiles.*.persistent` / `headless` / `attachOnly` — managed profile 只支持 `cdpPort` 和 `color`
- ❌ `channels.openclaw-weixin.startDelay` — 不存在此字段

### 2.6 Agent 名称编码问题（反复出现）

**问题**：OpenClaw agent 通过 `config.patch` 或 `gateway tool` 修改 `openclaw.json` 时，中文字符会被双重编码（UTF-8 → Latin-1 → UTF-8），导致名称变成乱码（如 `先知` → `鍏堢煡`）。

**触发条件**：agent 在 webchat 中执行 `config.patch` 修改 `agents.list`。

**修复方法**：用 Python 重写正确的名称：

```python
import os, json

CORRECT_NAMES = {
    "main": "先知",
    "writer-agent": "文墨",
    "coder-agent": "码农",
    "info-agent": "讯探",
    "image-agent": "绘影",
}

cfg_path = os.path.join(os.environ["USERPROFILE"], ".openclaw", "openclaw.json")
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

for agent in data.get("agents", {}).get("list", []):
    correct = CORRECT_NAMES.get(agent.get("id", ""))
    if correct:
        agent["name"] = correct

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
```

**预防**：在启动脚本中加入名称校验（已添加到 `sync_models.py` 流程中）。

---

## 三、启动脚本优化

### 3.1 关键环境变量

```powershell
# ✅ 必须设置
$env:OPENCLAW_DISABLE_BONJOUR = "1"  # 禁用 Bonjour 网络发现

# ❌ 不要设置
# $env:OPENCLAW_SKIP_STARTUP_MODEL_PREWARM = "1"  # 会导致首次请求慢 20-30s
```

### 3.2 启动顺序

1. **Kiro Gateway** — 必须先启动并等待 `/health` 返回 healthy
2. **sync_models.py** — 同步模型列表到 openclaw.json
3. **Main Gateway** — `openclaw gateway --force`
4. **Sub-Agents** — 间隔 1s 启动，减少 CPU 竞争
5. **Multi-Agent / Bot Review** — 轻量服务，最后启动
6. **Warmup 请求** — 向 Kiro Gateway 发送一个简单请求预热缓存

### 3.3 Watchdog 监控

启动脚本包含 watchdog 循环，每 30s 检查：
- Kiro Gateway `/health`（2次失败 → 重启）
- Kiro API upstream 连通性（5次失败 → 重启 gateway 刷新 token）
- Main Gateway TCP 端口（2次失败 → 重启 + 清理 lock 文件）

---

## 四、已知问题与限制

### 4.1 openclaw-weixin 图片不识别

**状态**：未解决

**原因**：iLink API (`getupdates`) 返回的消息中，图片消息只有 `types=1`（文本），不包含 `types=2`（图片）。插件代码本身支持图片（有 CDN 下载 + AES-128-ECB 解密逻辑），但 API 不推送图片数据。

**可能修复**：
- 重新扫码登录（刷新 iLink session token，当前 token 保存于 2026-04-08）
- 重置 sync buffer：清空 `~/.openclaw/openclaw-weixin/accounts/dd325f3e7af3-im-bot.sync.json`

### 4.2 Cross-context messaging denied

**问题**：Cron 任务绑定到 `openclaw-weixin` channel 时，无法发送消息到 `wecom` channel。

**原因**：OpenClaw 2026.5.7 的安全限制，禁止跨 channel 发送消息。

**解决**：修改 cron 任务的 delivery 配置，或移除任务中发送 wecom 消息的步骤。

### 4.3 北森定时任务

**问题**：Browser 工具在 OpenClaw 2026.5.7 中有 bug（managed profile 在 navigate 后丢失 tab tracking）。

**当前方案**：使用 CDP 直接脚本（`auto-approve.js`）绕过 browser 工具。

### 4.4 plugin-tools 加载时间

**现状**：每次请求 2-3s（tool-policy 1.7s + plugin-tools 2.6s）

**原因**：OpenClaw 内部行为，每次请求都重新注册 plugin tools。

**无法优化**：这是 OpenClaw 架构限制，需等待官方修复。

---

## 五、升级检查清单

升级 OpenClaw 后，按以下顺序执行：

- [ ] 1. 备份 `~/.openclaw/openclaw.json` 和 `~/.openclaw/cron/jobs.json`
- [ ] 2. 执行升级（`openclaw update` 或手动替换）
- [ ] 3. 验证 `openclaw.json` schema（启动测试，看是否报 "Unrecognized key"）
- [ ] 4. 重新应用 preflight cache TTL 补丁（`model-preflight.runtime-*.js`）
- [ ] 5. 重新应用 update check 补丁（`update-startup-*.js`，注意不超过 24 天）
- [ ] 6. **重新应用 provider discovery timeout 补丁**（`models-config-*.js`，最关键！）
- [ ] 7. 运行 models.json 清理脚本（移除无效 providers）
- [ ] 7. 确认 `FAKE_REASONING=off` 在 `kiro-gateway/.env`
- [ ] 8. 确认启动脚本中**没有** `OPENCLAW_SKIP_STARTUP_MODEL_PREWARM`
- [ ] 9. 确认 `plugins.bundledDiscovery = "allowlist"`
- [ ] 10. 确认子 agent auth mode = "none"，主 agent auth mode = "token"
- [ ] 11. 启动并验证 webchat 加载时间 < 10s
- [ ] 12. 发送测试消息，确认响应时间 < 10s
- [ ] 13. 检查 cron 任务是否正常执行

---

## 六、性能基准

### 优化后基准（2026.5.7）

| 指标 | 数值 |
|------|------|
| 启动到 gateway ready | ~38s |
| 启动到 webchat 加载完成 | ~55s |
| models.list API | ~6.8s |
| chat.history API | ~7.6s |
| Kiro Gateway 单次请求 | 2.8-6s |
| Kiro Gateway 3并发 | 5.4s (无串行化) |
| auth 阶段 | 0.5-0.9s |
| plugin-tools 阶段 | 2-3s |

### 优化前基准（升级后未优化）

| 指标 | 数值 |
|------|------|
| 启动到 webchat 加载完成 | ~88s |
| models.list API | ~14s |
| model-resolution 阶段 | 14-30s |
| auth 阶段 | 18-21s |
| 每次对话总延迟 | 32-65s |

---

## 七、文件位置速查

| 文件 | 路径 |
|------|------|
| 主配置 | `C:\Users\zhuyulin\.openclaw\openclaw.json` |
| 启动脚本 | `D:\Kiro\testopenclaw\OpenClaw.ps1` |
| 模型同步 | `D:\Kiro\testopenclaw\sync_models.py` |
| Kiro Gateway | `D:\Kiro\testopenclaw\kiro-gateway\` |
| Kiro Gateway .env | `D:\Kiro\testopenclaw\kiro-gateway\.env` |
| Kiro 认证文件 | `C:\Users\zhuyulin\.aws\sso\cache\kiro-auth-token.json` |
| OpenClaw 日志 | `%TEMP%\openclaw\openclaw-YYYY-MM-DD.log` |
| Cron 任务 | `C:\Users\zhuyulin\.openclaw\cron\jobs.json` |
| Exec 权限 | `C:\Users\zhuyulin\.openclaw\exec-approvals.json` |
| Preflight 补丁 | `node_modules\openclaw\dist\model-preflight.runtime-*.js` |
| Update 补丁 | `node_modules\openclaw\dist\update-startup-*.js` |
| models.json | `~\.openclaw\agents\*\agent\models.json` |
| weixin 状态 | `~\.openclaw\openclaw-weixin\accounts\` |

---

*最后更新：2026-05-18*
