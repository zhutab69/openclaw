
========================================
  OpenClaw Launcher v4
  Node v22.22.1 / npm 11.14.1 / Python 3.14.4
  OpenClaw 2026.5.7 / Next.js 16.1.6
  mcporter 0.9.0
========================================

[1/5] Config + Cleanup... 4 agents (ports: 3020, 3040, 3060, 3080) (241ms)
[2/5] Kiro Gateway... token refreshed... ready (7.01s)
[3/5] Launch all services... 14 models, all launched (26.22s)
[4/5] Waiting for services...
  [==========================....] 86%
  [FAIL] Multi-Agent (8899)
  [WARMUP] Triggering model cache... sent
[5/5] Opening browsers... done (399ms)

========================================
  All services running! (96.5s)
========================================

  Init:        260ms
  Kiro GW:     7.02s
  Launch All:  26.22s
  Wait Ready:  62.02s
  Browsers:    401ms

  Main Dashboard: http://127.0.0.1:18789/
  Multi-Agent:    http://127.0.0.1:8899
  Bot Review:     http://127.0.0.1:8900

  Press any key to stop all services

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

**修复**：在 `kiro-gateway/.env` 中添加（当前实际配置）：

```env
FAKE_REASONING=off
FIRST_TOKEN_TIMEOUT=10
FIRST_TOKEN_MAX_RETRIES=2
CONNECT_TIMEOUT=10
```

**效果**：每次请求减少 ~1.5s，prompt tokens 减少 ~300。

**关于 `CONNECT_TIMEOUT=10`**（原为 30s）：上游 Kiro/AWS 偶发连接卡顿时，30s×重试会造成长时间 stall（曾观测到单次 235s）。降到 10s 让失败更快暴露、更快 failover，避免长时间挂起。

**升级后必做**：确认 `.env` 中 `FAKE_REASONING=off`、`CONNECT_TIMEOUT=10`（kiro-gateway 是独立项目，OpenClaw 核心升级不影响它；但重装 kiro-gateway 时需重新确认）。

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

### 1.7 sync_models fallback 数量上限

**文件**：`D:\Kiro\testopenclaw\sync_models.py`

**问题**：每个模型的 fallback 列表过长（曾达 13 个），失败时会依次尝试全部 fallback，叠加连接超时后 stall 时间被放大。

**修复**：将 fallback 上限从 13 降到 **3**（保留最可靠的少数几个即可）。

**效果**：失败时最多尝试 3 个 fallback，配合 `CONNECT_TIMEOUT=10` 显著缩短最坏情况的等待。

**归属**：`sync_models.py` 是本仓库脚本，不受 OpenClaw 升级影响。

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
4. **Sub-Agents** — 间隔 **2s** 启动，减少 CPU 竞争
5. **Multi-Agent / Bot Review** — 轻量服务
6. **外部 Web 服务（8901/8902）** — 从 `~/.openclaw/workspace/webservers.json` 动态读取并启动（见第八节）
7. **Warmup 请求** — 向 Kiro Gateway 发送一个简单请求预热缓存

> ⚠️ **启动并发争抢（已知瓶颈，未修复）**：启动脚本在主网关**端口 18789 就绪**后即开始起子 agent，但"端口就绪"早于主网关的 channel/weixin 初始化，导致 5 个 Node 进程（主+4 子 agent）同时做模型解析/插件加载，互相抢 CPU 与 kiro-gw(9000)，把主网关的 channel 初始化拖长约 14s。
> **可优化方向**（评估中，尚未落地）：把子 agent 的启动条件从"等端口"改为"等主网关真正 `ready`"，或加大 sub-agent stagger（2s → 8~15s），或减少常驻子 agent 数量。

### 3.3 Watchdog 监控

启动脚本包含 watchdog 循环，每 30s 检查：
- Kiro Gateway `/health`（2次失败 → 重启）
- Kiro API upstream 连通性（5次失败 → 重启 gateway 刷新 token）
- Main Gateway TCP 端口（2次失败 → 重启 + 清理 lock 文件）

### 3.4 打开浏览器（单次调用，避免竞态）

**问题**：早期用逐个 `Start-Process`/`cmd start` 打开多个页面，浏览器冷启动时会随机丢标签或开出空白"新标签页"（调整间隔时间只是改变哪个标签失败，治标不治本）。

**修复**：探测默认浏览器（注册表 `HKCU\...\UrlAssociations\http\UserChoice` → ProgId → `shell\open\command`），把**全部 URL（网关带 token、8899、8900、以及 webservers 的各 URL）作为参数一次性传给浏览器**（如 `firefox url1 url2 ...`），浏览器原生稳定各开一个标签；探测失败时回退到逐个 `cmd start`。

**注意**：访问地址统一用 `127.0.0.1`（非 `localhost`），避免 Windows 上先解析 IPv6 `::1` 的偶发延迟。

### 3.5 端口防御清理

- **初始清理（[1/5]）**与 **Cleanup 函数**的 `targetPorts` 均动态包含 `webservers.json` 里的端口（8901/8902）。
- **web 服务启动前**再按各自端口做一次定向 `Stop-Process`，确保上次未正常关闭的残留进程不会造成 `EADDRINUSE`。
- 说明：直接点窗口 X 关闭启动脚本时，Cleanup 不执行，各服务会残留，但下次启动的初始清理会自愈。

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
- [ ] 7b. 确认 `kiro-gateway/.env`：`FAKE_REASONING=off`、`CONNECT_TIMEOUT=10`、`FIRST_TOKEN_TIMEOUT=10`（仅重装 kiro-gateway 时需检查）
- [ ] 8. 确认启动脚本中**没有** `OPENCLAW_SKIP_STARTUP_MODEL_PREWARM`
- [ ] 9. 确认 `plugins.bundledDiscovery = "allowlist"`
- [ ] 10. 确认子 agent auth mode = "none"，主 agent auth mode = "token"
- [ ] 11. 启动并验证 webchat 加载时间 < 10s
- [ ] 12. 发送测试消息，确认响应时间 < 10s
- [ ] 13. 检查 cron 任务是否正常执行
- [ ] 14. **检查 skills 状态**：升级可能重置 `skills.entries`，导致所有 skill 变为 enabled（默认）。升级后立即检查并禁用不需要的 skill。
- [ ] 15. **Bot Review 若同时升级/重拉上游**：按第九节逐项确认定制未丢失（尤其 `output:standalone`），并重新 `npm run build`。
- [ ] 16. 确认 `~/.openclaw/workspace/webservers.json` 存在，启动后 8901/8902 正常打开（见第八节）。

> ⚠️ **Skill 配置丢失风险**：升级时如果 `openclaw.json` 的 `skills.entries` 被重写或清除，所有 skill 会变为默认状态（enabled）。建议升级前备份 skills 配置段，升级后对比恢复。

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
| Web 服务配置 | `~\.openclaw\workspace\webservers.json`（单一数据源） |
| 多智能体面板 | `~\.openclaw\workspace\dashboard-server.cjs` / `dashboard.html` |
| 租房系统 | `D:\Kiro\testzufang\rental-crawler\server.js`（8901） |
| 采集监控 | `D:\Kiro\testspider\server.js`（8902） |
| Bot Review | `D:\Kiro\testopenclaw\OpenClaw-bot-review\`（子仓库，见第九节） |

---

## 八、外部 Web 服务集成（8901 租房 / 8902 采集监控）

启动脚本除 OpenClaw 三件套外，还会拉起两个**独立项目**的 webserver：

| 服务 | 端口 | 项目路径 | 入口 |
|------|------|----------|------|
| 🏠 租房信息系统 | 8901 | `D:\Kiro\testzufang\rental-crawler` | `node server.js`（读 `PORT` 环境变量） |
| 🏥 采集平台监控 | 8902 | `D:\Kiro\testspider` | `node server.js`（端口硬编码 8902） |

- **单一数据源**：`~/.openclaw/workspace/webservers.json`（字段 id/name/emoji/port/desc/cwd/script/url）。`OpenClaw.ps1` 与多智能体面板（`dashboard-server.cjs`）都从此文件**动态读取**——新增项目只改此文件，无需改代码。
- 多智能体面板（8899）提供这两个服务的 启动/停止/重启（API：`/api/webservers`、`/api/webserver/{start|stop|restart}/<id>`）。
- 均用内置 node 启动，**不受 OpenClaw 升级影响**。
- 访问地址统一 `127.0.0.1`。

## 九、Bot Review 升级注意事项（重要）

`OpenClaw-bot-review`（上游 xmanrui）是**独立子仓库**，做了大量本地定制。**重新拉取/合并上游时极易丢失以下改动，必须逐项确认**：

- [ ] `next.config.mjs` 保留 `output: 'standalone'`（启动脚本用 `.next/standalone/server.js` 运行；上游合并曾丢过一次）
- [ ] 多实例改造：`lib/agents.ts` / `lib/daily.ts` / `lib/self-improvement-data.mjs` / `lib/openclaw-paths.ts` 支持跨多个 `.openclaw-*` 实例
- [ ] 统计 rollup：`sync_models.py` 写 `stats-daily.json`（lockedByDay），`lib/openclaw-stats.ts` 读取 locked + 实时
- [ ] 首页趋势图：过滤空白天 + 响应式 SVG（`app/page.tsx`）
- [ ] `post-build.ps1`：`next build` 后把 `.next/static`、`public` 复制进 standalone
- [ ] 启动 env（launcher 中）：`PORT=8900`、`HOSTNAME=127.0.0.1`、`OPENCLAW_HOME`、`OPENCLAW_PACKAGE_DIR`、`OPENCLAW_ALLOW_UNAUTHENTICATED_LOCAL_OPERATOR_UI=true`、`NODE_ENV=production`
- [ ] i18n 简体中文补全（rd-council / self-improvement 等页面标题、按钮）
- [ ] 升级后必须重新 `npm run build`（含 post-build），再重启 8900

> ⚠️ **禁止**把本地定制推送到上游 xmanrui（其 origin 为上游作者）。本地备份走本地 GitLab 父仓库（gitlink）或全量快照。

---

## 十、升级到 2026.7.1 专项风险与前置检查

> 适用：当前 **2026.5.7 → 最新 2026.7.1**（中间约 15 个正式版：5.28 / 6.1 / 6.5–6.11 / 7.1）。
> ⚠️ 本节结论基于版本跨度 + 公开变更信息 + 指南所依赖内部实现的性质；**未在 2026.7.1 实测**，务必按"沙箱先行"执行。

### 10.1 2026.7.1 关键变化（据公开变更说明）
- **Control UI 完全重写**（影响面最大）
- GPT-5.6 / 腾讯 Hy3 模型集成，**模型解析路径调整**
- 修复了若干长期稳定性问题
- provider 行为变更：provider 返回的默认模型现在是"追加为可用"，而非"替换主模型"

### 10.2 指南各节的升级适用性

| 分级 | 章节 | 说明 |
|------|------|------|
| ✅ 仍适用 | §1.2、§1.3、§3、§八 | 配置清理 / kiro-gw(独立) / 自建启动脚本 / 外部 web 服务，均与 OpenClaw 内部无关 |
| ⚠️ 高风险·需重新核对 | **§1.4 / §1.5 / §1.6** | 针对内部 minified dist 文件的补丁，跨 15 版 + Control UI 重写，锚点/函数极可能改名或已被官方修复 |
| ⚠️ 中风险 | §2.1 / §2.3 / §2.5 | schema 可能随 Control UI 重写变化（"Unrecognized key"、允许字段） |

### 10.3 指南未覆盖的新风险（本次升级重点）
1. **Control UI 重写 → 面板 API 兼容性**：Bot Review(8900) 与多智能体面板(8899) 依赖网关 operator/control API（`health`、`sessions.list`、`models.list`、`agents.list`）及 `OPENCLAW_ALLOW_UNAUTHENTICATED_LOCAL_OPERATOR_UI` flag。**若 API/鉴权随重写变化，两个面板可能失效**，需实测。
2. **插件版本兼容**：`openclaw-weixin` / `wecom-openclaw-plugin` 可能需为 7.1 升级到匹配版本。
3. **§1.6 补丁可能已多余**：官方"稳定性修复"或已解决 provider discovery 慢的问题——升级后应**先不打补丁裸测**。

### 10.4 前置检查与安全升级步骤（务必按序）
- [ ] 1. **沙箱先行**：复制整套环境（或至少 `node-v22.*` + `.openclaw`）到副本升级，**不要直接动生产的 5.7**；保留 5.7 作为回滚点。
- [ ] 2. 备份 `openclaw.json`、`cron/jobs.json`、`skills.entries` 段、各 `.openclaw-*` 配置。
- [ ] 3. 升级到 2026.7.1 后，**先裸启动**（不打任何 dist 补丁），观察：
  - [ ] a. 是否报 "Unrecognized key"（→ 按新 schema 修 §2.5）
  - [ ] b. gateway ready / webchat 加载 / 单次请求耗时（判断 §1.4/§1.6 补丁是否还必要）
- [ ] 4. 若仍慢，**逐个核对补丁锚点**是否存在再打：
  - [ ] `models-config-*.js` 里 `resolveImplicitProviders` 是否还在、结构是否变（§1.6）
  - [ ] `model-preflight.runtime-*.js` 的 `PREFLIGHT_CACHE_TTL_MS`（§1.4）
  - [ ] `update-startup-*.js` 的 `UPDATE_CHECK_INTERVAL_MS`（§1.5，≤24 天）
  - [ ] 锚点缺失 → **停止套旧补丁**，重新诊断（很可能已被官方修复）
- [ ] 5. 运行 models.json 清理脚本（§1.2）。
- [ ] 6. **验证面板**：Bot Review(8900) + 多智能体(8899) 能否连上重写后的 Control UI/API；确认 `OPENCLAW_ALLOW_UNAUTHENTICATED_LOCAL_OPERATOR_UI` flag 仍有效；`npm run build`（含 post-build）后重启。
- [ ] 7. 核对插件版本（openclaw-weixin / wecom-openclaw-plugin）与 7.1 的兼容性。
- [ ] 8. 按第五节 + 第九节清单逐条过；确认 8901/8902、cron、微信/企业微信收发正常。
- [ ] 9. 全部通过后再切生产；否则回滚到 5.7。

### 10.5 结论
指南能覆盖**配置层与自建启动/服务部分**，但其核心价值（§1.4–1.6 内部补丁）**强版本绑定**，对 2026.7.1 很可能不再适用；叠加 **Control UI 重写**这一未验证的新风险，**当前不能保证 5.7→7.1 零风险直升**。必须"沙箱先行 + 裸测 + 逐锚点核对 + 面板实测"后方可切换。

> ✅ **已于 2026-08-05 完成沙箱实测**，第十节的多项预测被证伪或证实，详见**第十一节**。第十节保留作为"升级前如何评估"的方法论记录；**具体结论以第十一节为准**。

---

## 十一、2026.5.7 → 2026.7.1-2 沙箱实测结论（2026-08-05）

> 本节是**实测结果**，非推测。沙箱环境：Node v22.23.2 + openclaw 2026.7.1-2，配置目录 `~\.openclaw-upgradetest`，端口 18889。
> 生产 5.7 的**配置与数据主体未受影响**（5 份配置原样、4 个 sqlite 字节级未变），但**并非完全无痕** ——
> 沙箱有几条 side-effect 路径不认 `--profile`，写入了生产目录 6 个文件并把 `exec-approvals.json` 改名。
> 详见 §11.6 末尾"`--profile` 做不到完全隔离"。

### 11.1 版本与渠道选择

npm dist-tags 实况（2026-08-05）：

| 标签 | 版本 | 发布日 | Node 要求 |
|------|------|--------|-----------|
| `latest` | **2026.7.1-2** | 2026-07-18 | `>=22.22.3 <23 \|\| >=24.15.0 <25 \|\| >=25.9.0` |
| `extended-stable` | 2026.6.34 | 2026-08-04 | `>=22.19.0` |
| `beta` | 2026.7.2-beta.7 | 2026-08-02 | 同 7.x |

- 7.x 稳定版只有 `2026.7.1` / `-1` / `-2` 三个；6.x 线有 27 个发布且仍在维护
- **`extended-stable` 是保守选项**：不需要升 Node，插件同处 6.x 时代
- 选 `latest` 需连带升 Node，但实测通道插件仍可用

### 11.2 三个前置条件（缺一不可）

**① Node 必须升到 v22.23.2**

`2026.7.1-2` 要求 `>=22.22.3`，**22.22.1 不满足**，引擎会直接拒绝。

- 官方 zip + `SHASUMS256.txt` 校验；v22 线最新为 v22.23.2（LTS Jod）
- ⚠️ **`npm install` 绝不能在 Node 安装目录下以本地模式执行** —— 它会把 `node_modules/npm` 一并修剪掉，之后该运行时就没有可用的 npm 了。
- 📌 **更正**：启动器横幅上的 `npm N/A` **与此无关**。成因是 `OpenClaw.ps1` 第 443 行用 `execSync('npm -v')` 探测，依赖 **PATH 里有 `npm`**；便携版 Node 没进 PATH，所以恒为 N/A。升级后新运行时 npm 实为 **10.9.8**（`node.exe node_modules\npm\bin\npm-cli.js -v` 可验证），横幅仍显示 N/A 属显示缺陷。改法：照 `$openclawVer` 的写法直接 require `node_modules/npm/package.json`。
- 正确做法（global 安装，保留内置 npm，且布局与生产一致）：
  ```powershell
  cd D:\Kiro\testopenclaw\node-v22.23.2-win-x64
  .\node.exe node_modules\npm\bin\npm-cli.js install -g openclaw@2026.7.1-2 `
      --prefix D:\Kiro\testopenclaw\node-v22.23.2-win-x64 --no-audit --no-fund
  ```
  产物落在 `<prefix>\node_modules\openclaw`，与 5.7 布局相同。

**② 两个通道插件必须用 7.x 安装器在 5 个配置目录全部重装**

7.x 新增**插件 peer link 审计**。5.7 时代装的插件缺 `<plugin>\node_modules\openclaw`，7.x 视为致命错误并**拒绝启动**：

```
[openclaw] Reason: OpenClaw startup migrations did not complete cleanly;
           refusing to report the gateway ready.
Plugin "openclaw-weixin"       failed post-core payload smoke check (missing-openclaw-peer-link)
Plugin "wecom-openclaw-plugin" failed post-core payload smoke check (missing-openclaw-peer-link)
```

用 `openclaw plugins install` 重装即自动建链（实测有效）：
```
Linked peerDependency "openclaw" -> ...\node-v22.23.2-win-x64\node_modules\openclaw
```

版本**必须显式指定**：

| 插件（真实包名，scoped） | 目标版本 | 说明 |
|---|---|---|
| `@wecom/wecom-openclaw-plugin` | **`2026.7.2`** | ⚠️ **绝不能用 `latest`** |
| `@tencent-weixin/openclaw-weixin` | **`2.4.6`** | 该线最新，peerDeps `openclaw >=2026.5.12` |

> ⚠️ **`@wecom/wecom-openclaw-plugin` 的 npm `latest` 标签指向畸形版本 `20206.7.201`**（`20206` 是 `2026` 的手误）。语义化版本下 `20206 > 2026`，所以 `latest` 会拉到错版本。同日另有正常的 `2026.7.2`。
>
> 另注意：非 scoped 的 `openclaw-weixin`（latest 3.0.2）与 scoped 的 `@tencent-weixin/openclaw-weixin` 是**两个不同的包**，本项目用的是 scoped 版。

**②-补 A：7.x 换了插件安装布局（重装不会覆盖旧目录）**

| | 安装位置 | peer 位置 |
|---|---|---|
| 5.7（legacy） | `<home>\npm\node_modules\<pkg>` | 依赖被 **hoist** 到 `<home>\npm\node_modules\openclaw` |
| **7.x** | `<home>\npm\projects\<slug>\node_modules\<pkg>` | `…\<pkg>\node_modules\openclaw`（每插件独立，不 hoist） |

`<slug>` 形如 `wecom-wecom-openclaw-plugin-18f843d908` / `tencent-weixin-openclaw-weixin-7783ac86ba`（包名 + 短哈希），**同一插件在不同 profile 下 slug 相同**。

推论：7.x 重装是**新建 projects 目录**，`npm\node_modules\` 下的 legacy 安装会**原样残留**。验证全部通过后可以手动清理，但升级期间**不要动**（它是回滚素材）。

**②-补 B：peer 必须指向"正在运行的那个 openclaw"**

审计比对实际解析目标与当前运行时，不匹配就拒绝启动：

```
peer link audit failed: ...node-v22.22.1... instead of ...node-v22.23.2...
```

生产现状（2026-08-05 只读审计）之所以必然触发审计失败：

- **主目录**：两个插件自身都**没有** peer 目录，peer 靠 hoist 解析到 `~\.openclaw\npm\node_modules\openclaw` —— 那里躺着一份 **openclaw 2026.6.1 的完整副本**（既不是运行中的 5.7，也不属于任何 Node 目录，是 wecom 升到 2026.5.25 时 npm 顺带拉下来的）。7.x 审计到这份"版本对不上的野生 openclaw"即判 fail
- **4 个子 profile**：peer 在 `…\@wecom\wecom-openclaw-plugin\node_modules\openclaw`，实体指向 **node-v22.22.1** —— 换 Node 目录后即刻作废

**②-补 C：生产有 5 个独立插件安装位置，逐个都要处理**

每个配置目录有自己的 `<home>\npm`，插件**各自独立安装**，互不共享：

| 配置目录 | wecom 版本 | weixin 版本 | peer 解析到 |
|---|---|---|---|
| `~\.openclaw`（主） | 2026.5.25 | 2.4.3 | hoist 的 openclaw **2026.6.1 副本** ⚠️ |
| `~\.openclaw-writer` | **2026.5.14** | ❌ 未装 | **node-v22.22.1** ⚠️ |
| `~\.openclaw-coder` | **2026.5.14** | ❌ 未装 | **node-v22.22.1** ⚠️ |
| `~\.openclaw-infoer` | **2026.5.14** | ❌ 未装 | **node-v22.22.1** ⚠️ |
| `~\.openclaw-imager` | **2026.5.14** | ❌ 未装 | **node-v22.22.1** ⚠️ |

三个要点：

1. 5 个位置**没有一个**的 peer 指向新运行时 → 全部要重装
2. **4 个子 profile 的 wecom 比主目录更旧**（5.14 vs 5.25），是更早一次安装后就没再同步。升级顺手对齐到 2026.7.2
3. **4 个子 profile 都没装微信插件** —— 这是既有状态（子 Agent 不直接接微信通道）。重装时**保持这一现状**，不要给子 profile 新增微信插件，否则 4 个子 Agent 会一起轮询同一个微信账号、抢消息、重复回复真实用户

**②-补 D：上述方案已在沙箱按 1:1 结构验证过**

沙箱 5 个配置目录的最终状态，与生产升级的目标状态完全同构，且 5 个网关全部正常启动、通道端到端通：

| 沙箱配置目录 | wecom | weixin | peer |
|---|---|---|---|
| `~\.openclaw-upgradetest`（主） | 2026.7.2 | 2.4.6 | ✅ node-v22.23.2 |
| `~\.openclaw-ut-writer` | 2026.7.2 | 未装 | ✅ node-v22.23.2 |
| `~\.openclaw-ut-coder` | 2026.7.2 | 未装 | ✅ node-v22.23.2 |
| `~\.openclaw-ut-infoer` | 2026.7.2 | 未装 | ✅ node-v22.23.2 |
| `~\.openclaw-ut-imager` | 2026.7.2 | 未装 | ✅ node-v22.23.2 |

即 `--profile` 形式的 `plugins install` **确实会装到该 profile 自己的 `npm\projects\` 下**，不会串到主目录。

**③ 迁移不可逆，升级前必须有完整目录快照**

7.x 会把大量状态迁到 SQLite 并把原文件改名 `.migrated`：

- Cron store → SQLite（实测导入 34 条历史运行日志，34 个 `cron\runs\*.jsonl` 全部改名）
- 222 条 task registry、10 条 task delivery、114 条 task flow → SQLite
- Memory Core 记忆索引 → per-agent SQLite（23 源 / 186 chunk）
- update-check、config-health → SQLite
- 插件安装记录 → SQLite（对两个通道插件会报"元数据冲突"并保留旧索引，属预期）

**回滚不是换回 Node 目录就行，必须从快照恢复 `~\.openclaw`。** 仅备份配置文件不够。

### 11.3 §1.4–1.6 三个 dist 补丁：7.x 已不需要

| 指南章节 | 5.7 补丁值 | 7.1-2 官方默认 | 是否仍需打 |
|---|---|---|---|
| §1.6 provider discovery | early-return + `timeoutMs ?? 5000` | 原生有 `resolveProviderDiscoveryFilter()`，非 live-test 直接 `return` | ❌ **官方已修复** |
| §1.4 preflight TTL | `60 * 6e4` | `5 * 6e4` | ❌ 不必 |
| §1.5 update check | `24 * 864e5` | `1440 * 60 * 1e3`（24h） | ❌ 官方默认已合理，无溢出风险 |

> 📌 **重要修正**：`model-resolution` 6–17s 的真实根因**不是** provider discovery，而是**多网关进程争抢单线程事件循环**。诊断依据：`eventLoopUtilization=0.965` 而 `cpuCoreRatio=0.061`（单核打满、整机空闲），且本地 kiro-gw `/v1/models` 实测仅 2.7–38.6ms。
>
> 因此**不要**指望靠 dist 补丁解决启动慢。有效手段见 §11.7。

### 11.4 §2.5 禁用字段清单修正（实测）

| 字段 | 指南原记录 | 7.1-2 实测 |
|---|---|---|
| `browser.profiles.*.attachOnly` | ❌ 不存在 | ✅ **合法**，指南该条已过时 |
| `browser.controlPort` | 未记录 | ❌ **不存在**，会导致 `browser: Invalid input` |
| `gateway.controlUi.embedSandbox` | 未记录 | ✅ 合法 |
| `gateway.controlUi.allowExternalEmbedUrls` | 未记录 | ✅ 合法 |
| `agents.defaults.thinking` | ❌ 不存在 | 未使用，无冲突 |
| `channels.openclaw-weixin.startDelay` | ❌ 不存在 | 未使用，无冲突 |

**Control UI 重写未破坏现有配置**：主配置 + 4 个子 profile 在 7.1-2 上 `config validate` 全部通过。

### 11.5 §检查清单 #14 skills 重置：实测未发生

沙箱有 **302 条 `skills.entries`**（仅 1 条启用），升级后**完整保留、启用状态不变**。

仍建议单独导出该段作为保险：一旦被重置，301 条 skill 会全部变默认启用，显著膨胀上下文与工具注册开销。

### 11.6 沙箱隔离要点（踩坑记录）

配置目录复制后，**以下绝对路径仍指向生产，必须全部重写**，否则沙箱会写入生产数据：

1. `agents.list[].workspace` —— 5 个 agent 全是生产路径（**最容易漏**）
2. `plugins.load.paths` —— 指向生产的 smart-memory 插件目录
3. `plugins\installs.json` 的 `installPath` —— 3 条记录全指生产（建议直接停用该文件，让沙箱重装插件）

实测教训：漏改上述路径导致沙箱把生产的 `workspace\memory\.dreams\short-term-recall.json` 改名为 `.migrated`（已恢复，哈希一致）。

复制时应排除：`backups\`、`npm\`、`delivery-queue\`（尤其 delivery-queue，否则沙箱会重试真实企业微信投递）。

**⚠️ 结论性教训：`--profile` 做不到完全隔离，沙箱一定会写生产目录**

即使上面 3 处路径全部改对，仍有若干代码路径**不认 `--profile`**，而是回退到默认的 `~\.openclaw`。沙箱主网关是这样起的：

```
set OPENCLAW_HOME= && node openclaw.mjs --profile upgradetest gateway --force
```

`OPENCLAW_HOME` 被清空、只靠 `--profile`。实测在 12:14–12:43 这段沙箱通道测试窗口内，**生产目录被写入了 6 个文件 + 1 次状态改名**：

| 时间 | 生产目录内的变化 | 性质 |
|---|---|---|
| 12:14:45 / 12:14:59 | `agents\main\sessions\` 新增 2 个 `.reset.<ts>` 归档 | 原文件未动，仅多出副本（哈希与原件一致） |
| 12:20:08 | `plugins\smart-memory.log`、`hooks\skill-library-loader\injected.log`、`hooks\skill-rules-injector\injected.log` | 仅日志增长 |
| 12:42:37 | `skills-entries-backup.json`、`workspace\skill-library-index.md` | 内容哈希不变，仅 mtime 变化 |
| ~12:43:34 | **`exec-approvals.json` → `exec-approvals.json.migrated`** | ⚠️ 真实状态改名（7.x 迁移动作） |

即这几类 side-effect 是"漏"到生产的：

1. **smart-memory 插件日志**（`plugins\smart-memory.log`）
2. **两个 managed hook 的日志**（`hooks\skill-library-loader\*`、`hooks\skill-rules-injector\*`）
3. **skills 索引重写**（`skills-entries-backup.json`、`workspace\skill-library-index.md`）
4. **7.x 的 exec-approvals 迁移** —— 读/改名走生产路径，数据写进 profile 自己的 SQLite，属于最有害的一类

佐证：`smart-memory.log` 末尾几行是 `agent=main`、时间 04:16–04:20Z（本地 12:16–12:20），正好套住沙箱通道端到端测试（12:19:45 收消息 / 12:19:51 回复）。生产根目录 mtime 12:43:34 定位了改名时刻。

**因此**：

- 沙箱验证**必须把"生产会被写入"当作既定前提**，而不是意外。跑之前先做完整快照，跑完之后必须做**快照 vs 生产的全量差异复核**（文件数 / 字节 / 集合差 / size+mtime / 关键文件哈希），把改名类变化找出来
- 改名是 mtime 保持的，**只靠"mtime 晚于快照时间"扫不出来**，必须做相对路径集合差
- 别指望靠沙箱做无痕验证。要真隔离，得整机/容器级隔离，或至少把 `OPENCLAW_HOME` **显式指向沙箱目录**（而不是清空 + `--profile`）

**另注意 `~\.openclaw\plugin-skills\` 下 11 项是符号链接**（指向 wecom 插件 `skills\` 与 browser 扩展）：
- robocopy 会**解引用**，把实体文件写进副本
- `Get-ChildItem -Recurse -File` 与 Python `rglob` **都不跟随**符号链接，统计时会误报 0 文件
- 核对完整性要逐个直连路径判断，别用递归统计下结论

**通道验证前提**：`channels.wecom` 绑定单一 `botId`，微信是轮询模式。**生产与沙箱绝不能同时运行**，否则抢消息、重复回复真实用户。沙箱有独立 `*.sync.json` 副本，不会推进生产游标。

### 11.7 启动慢的真实对策（替代失效的 dist 补丁）

按有效性排序：

1. **加大子 Agent 错峰**（`OpenClaw.ps1` 的 `$script:subAgentStartStaggerMs`，当前 2000ms）—— 直接减少同时启动的 Node 进程数，针对主因
2. **启动后延迟 cron 首次唤醒** —— 避开启动窗口
3. **减少常驻子 Agent 数量** —— 4 个子网关各自完整加载插件与模型配置，是争抢主源
4. ❌ **无效手段**：提高并发、提高 timeout、降级模型。单线程事件循环被饿死时这些都不解决问题
5. ⚠️ `agents.defaults.model.fast` **不存在**。日志里的 `fast=off` 来自 `resolveFastModeState()`，是布尔型 fast mode（由 `agents.defaults.fastModeDefault` 或 per-model `params.fastMode` 控制），且 wrapper 只作用于 minimax/xai/anthropic 特定传输路径，**不会替换成更轻的模型**

### 11.8 通道端到端实测结果（2026.7.1-2）

两个通道**均验证可用**：

```
12:13:47  [wecom] [default] [2026.7.2] Initializing WSClient with SDK...
12:13:47  [wecom] Authentication successful / Heartbeat 30000ms
12:13:47  [openclaw-weixin] weixin monitor started (account=dd325f3e7af3-im-bot)
12:19:45  [wecom] aibot_msg_callback (from=ZhuYuLin)
12:19:45  [wecom] 动态路由 matchedBy=binding.account → agentId=main
12:19:50  [model-fetch] kiro-gw/claude-opus-4.8 status=200 elapsedMs=4116 (SSE)
12:19:51  [wecom] kind=final → 回复送达
12:19:52  Reply ack received / stream finish=true
```

`health --json` 显示两通道 `enabled/configured/running` 全为 `True`，`plugins.errors = []`，模板卡片解析与流式分片正常。

> 💡 若模型报 `ECONNREFUSED` / `All models failed ... Connection error`，先查 **Kiro Gateway (9000) 是否在运行** —— 这与 OpenClaw 版本无关。实测踩过此坑。

### 11.9 三个插件的 SDK 兼容性（逐文件核对）

扫描插件源码的 `openclaw/plugin-sdk/*` 引用，与 7.1-2 的 `exports`（327 项，5.7 为 299 项）逐项比对：

| 插件 | 扫描文件 | SDK 引用 | 7.1-2 缺失 |
|---|---|---|---|
| `@wecom/wecom-openclaw-plugin` | 128 | 6 | **无** |
| `@tencent-weixin/openclaw-weixin` | 82 | 14 | **无** |
| smart-memory（本地 path） | 1 | 1（`plugin-entry`） | **无** |

7.x 移除的导出集中在测试类（`plugin-test-*`、`channel-*-testing`、`test-fixtures`），生产插件未使用。

> 核对时注意：插件位于 `~\.openclaw\npm\node_modules\...`，若扫描脚本一律排除含 `node_modules` 的路径，会把插件本体全部漏掉（应只排除插件自身内部的嵌套 `node_modules`）。

### 11.10 生产升级执行方案

> 前置：已完成 §11.2 三个条件的准备；生产**已完全停止**（所有端口空闲、无 openclaw 网关进程）。

**阶段 A — 备份（不可跳过）**

1. 配置级备份：5 份 `openclaw.json`（主 + 4 profile）、`cron\jobs.json`、`agent-profiles.json`、`exec-approvals.json`、`plugins\installs.json`、`webservers.json`、**`skills.entries` 单独导出**、三个 dist 补丁锚点记录 → 带 SHA-256 清单
2. **完整目录快照**：`~\.openclaw` 全量复制（约 2.4 GB / 5.3 万文件）到仓库外目录
   - ⚠️ robocopy 会漏掉**超长路径**文件（实测 `@mistralai` 下 3 个文件，路径 211–215 字符），需用 `\\?\` 前缀单独补齐
   - 校验：文件数 + 总字节 + 关键文件哈希
3. Git 备份：`OpenClaw.ps1`、`sync_models.py` 等已改动文件推送到备份分支双端

**阶段 B — 停服**

4. 停止 Launcher（Press any key），确认 18789/3020/3040/3060/3080/8899/8900/9000 全部空闲
5. 确认无残留 `node.exe` 命令行含 `openclaw`

**阶段 C — 运行时升级**

6. 保留旧目录 `node-v22.22.1-win-x64` **不删除**（回滚点）
7. 新建 `node-v22.23.2-win-x64`：官方 zip 解压 + SHA-256 校验
8. 按 §11.2① 的 global 方式装 `openclaw@2026.7.1-2`，验证 `node_modules\npm` 完好

**阶段 D — 启动器路径切换**

9. 修改 `OpenClaw.ps1` 中 **4 处**硬编码（实测确认位置）：
   - 第 7 行 `$NODE`
   - 第 8 行 `$OPENCLAW_MJS`
   - 第 446 行 `$openclawVer` 的 require 路径
   - 第 447 行 `$mcporterVer` 的 require 路径
10. `[System.Management.Automation.Language.Parser]::ParseFile` 语法校验

**阶段 E — 插件重装（5 个位置，不止主目录）**

> ⚠️ 这是最容易漏的一步。详见 §11.2②-补 A/B/C：5 个配置目录各有独立的 `<home>\npm`，且 peer 必须解析到**新** Node 目录。漏掉任一目录，对应网关首启即被 peer 审计拦下。已在沙箱按同构结构验证通过（§11.2②-补 D）。

11. **主目录**（`~\.openclaw`）用新运行时执行，版本显式指定：
    ```
    openclaw plugins install @wecom/wecom-openclaw-plugin@2026.7.2
    openclaw plugins install @tencent-weixin/openclaw-weixin@2.4.6
    ```
12. **4 个子 profile** 各自重装 **wecom（仅 wecom）**，用 `--profile` 指向对应配置目录：
    ```
    openclaw --profile writer plugins install @wecom/wecom-openclaw-plugin@2026.7.2
    openclaw --profile coder  plugins install @wecom/wecom-openclaw-plugin@2026.7.2
    openclaw --profile infoer plugins install @wecom/wecom-openclaw-plugin@2026.7.2
    openclaw --profile imager plugins install @wecom/wecom-openclaw-plugin@2026.7.2
    ```
    ⚠️ **不要给子 profile 装微信插件** —— 生产现状是 4 个子 profile 均未安装，保持不变。装上会导致 4 个子 Agent 同时轮询同一微信账号、抢消息、重复回复真实用户。
13. 逐个确认日志出现指向**新**目录的链接：
    ```
    Linked peerDependency "openclaw" -> ...node-v22.23.2-win-x64\node_modules\openclaw
    ```
14. 复核 5 个位置的最终状态（版本 + peer 解析目标），确保无一处仍指向 `node-v22.22.1` 或那份 `2026.6.1` 野生副本。**注意查的是 7.x 的 `projects` 布局**（见 §11.2②-补 A），查 legacy 的 `npm\node_modules\` 会看到没被覆盖的旧版本而误判：
    ```
    <home>\npm\projects\wecom-wecom-openclaw-plugin-18f843d908\
        node_modules\@wecom\wecom-openclaw-plugin\node_modules\openclaw
    <home>\npm\projects\tencent-weixin-openclaw-weixin-7783ac86ba\
        node_modules\@tencent-weixin\openclaw-weixin\node_modules\openclaw   ← 仅主目录
    ```
    期望：5 个 wecom peer + 1 个 weixin peer，共 6 处，全部落在 `node-v22.23.2-win-x64\node_modules\openclaw`
15. legacy 的 `<home>\npm\node_modules\` **保持不动**（回滚素材）。验证全部通过、观察若干天后再考虑清理，尤其是主目录那份 openclaw 2026.6.1 完整副本
16. ⚠️ `plugins\installs.json` 内含**旧 Node 路径**（`plugin-skills\` 的 11 个符号链接指向它）。重装后需确认符号链接目标仍有效，否则 wecom 技能会失效
    - 7.x 会把插件安装记录迁到 SQLite，`installs.json` 不再是唯一真相源；对两个通道插件会报"元数据冲突"并保留旧索引，属预期
    - 复核符号链接时注意：`robocopy` 会**解引用**符号链接，而 `Get-ChildItem -Recurse -File` / Python `rglob` **不跟随**，两者文件数天然不一致。曾因此误报"生产丢失 37 文件"，实为 11 个符号链接造成的统计差异

**阶段 F — 首启验证**

17. `config validate`（主 + 4 profile）
18. 启动主网关，确认：
    - 无 `missing-openclaw-peer-link`、无 `peer link audit failed`
    - `[gateway] ready`
    - 4 插件加载且 `plugins.errors = []`
    - 两通道 `running=True`
    - `skills.entries` 仍 302 条、启用数不变
19. 记录状态迁移日志（Cron/Memory/task → SQLite），确认全部指向生产路径且无报错

**阶段 G — 全量验证**

20. 起 Kiro Gateway (9000)，`/health` 为 `healthy`
21. `models.list` 返回 18 个模型
22. 企业微信 + 微信各发一条消息，确认 `kind=final` 回复送达
23. 4 个子 Agent 网关启动（3020/3040/3060/3080），确认各自无 peer link 报错
24. 8899 面板：`/api/status` 返回 5 个 agent，main + 4 子 Agent 全部 online
25. Bot Review：**不需要重新 build**（实测确认）。`post-build.ps1` 只把 `.next\static` 与 `public` 拷进 standalone，与 openclaw 包路径无关；Bot Review 是运行时通过 `OPENCLAW_PACKAGE_DIR` 读包的，该变量在启动器里已随 `$OPENCLAW_MJS` 一起切到新目录。直接重启 8900 后验证 `/`、`/models`、`/api/config`、`/api/agent-status`、`/api/stats-models`、`/api/daily` 均 200
26. 8901 / 8902 外部 web 服务可访问
27. 开启 cron，观察首轮任务

**回滚方案**

- 阶段 C/D 失败：改回 `OpenClaw.ps1` 的 4 处路径指向旧目录即可，无数据变更
- 阶段 F 及之后失败：**必须**从阶段 A 的完整快照恢复 `~\.openclaw`（因 SQLite 迁移不可逆），再改回路径

### 11.11 两个面板 + 子 Agent 网关：沙箱实测通过

沙箱端口映射：主 18889，子 Agent 4020/4040/4060/4080，面板 9899（对应生产 8899），Bot Review 9900（对应生产 8900）。

**4 个子 Agent 网关**：全部在 7.1-2 上正常启动并监听，`config validate` 通过，无 peer link 报错。

**9899 多智能体面板（= 生产 8899）**

| 检查项 | 结果 |
|---|---|
| `/api/status` 返回 agent 数 | 5（main + 4 子） |
| 4 个子 Agent 在线判定 | ✅ 全部 online |
| `agent.model` 对象形态解析 | ✅ 正常（`formatAgentModel()` 生效，显示如 `claude-opus-4.8 +3`） |
| 页面三个区块（主 Agent / 子 Agent / 最近活动） | ✅ 均有内容，无空白 |

> ⚠️ **已知硬编码**：`dashboard-server.cjs` 第 196 行 `const portMap = { 'main': 18789 };`，第 105 行同样以 `18789` 兜底。只有**子 Agent** 端口从各 `openclaw.json` 动态读取，main 是写死的。
>
> 沙箱里 main 实际跑在 18889，面板仍去探 18789，所以沙箱中 main 一栏判定不准（当时生产已停、18789 空闲）。**生产升级不受影响**（生产 main 就是 18789），但这条违反项目"禁止硬编码端口"规则，建议后续改为读 `config.gateway.port`。

**9900 Bot Review（= 生产 8900）**

| 端点 | 结果 |
|---|---|
| `/api/config` | ✅ 18 个模型、5 个 agent、`gateway.port` 正确回显（沙箱 18889） |
| `/`（首页） | ✅ 200 |
| `/models` | ✅ 200 |
| `/api/stats-models` | ✅ 200 |
| `/api/agent-status` | ✅ 200 |
| `/api/daily` | ✅ 200 |

结论：Control UI 在 7.x 的重写**没有破坏** Bot Review 依赖的 operator/control 读取路径，`OPENCLAW_ALLOW_UNAUTHENTICATED_LOCAL_OPERATOR_UI` flag 仍有效。

### 11.12 生产升级实测记录（2026-08-05 执行完毕）

**阶段 A — 备份**

- 快照复用 `snapshot-openclaw-20260805-110440`，做**增量补齐**后与生产完全对齐：
  - 集合差 `LIVE - SNAP = 0`、共同文件 size 全等、SNAP 独有 37 项全部是 `plugin-skills\` 下 junction 解引用（固有差异）
  - ⚠️ 复核时先纠正了沙箱造成的 3 处改名（`exec-approvals.json` + 2 个 main 会话），全部 SHA-256 与快照原件一致
  - 📌 **改名保持 mtime，只按"mtime 晚于快照"扫不出来**，必须做相对路径集合差
- 配置级备份复用 `pre-upgrade-2026.7.1-2-20260805-103059`：10 项配置与生产逐一哈希一致，自带 `SHA256SUMS.txt` 12 条全过
- Git：指南更新 commit `25293f4` 推送 GitLab + GitHub 双端，`ls-remote` 一致
  - 新 Node 目录**未入库**（旧目录也只跟踪顶层壳脚本 + `node.exe`；入库会让仓库永久增大约 90MB，而回滚靠磁盘保留的旧目录）

**阶段 B/C** — 16 个端口全空、无残留进程、无 Launcher 在跑；新运行时 Node v22.23.2 / npm 10.9.8 / openclaw 2026.7.1-2，旧目录保留。

**阶段 D** — `OpenClaw.ps1` 4 处路径切换完成，AST 无解析错误，旧路径 0 残留。

**阶段 E — 插件重装结果**

6 个 peer 全部落在新运行时（5 × wecom + 1 × weixin）：

| 配置目录 | wecom | weixin |
|---|---|---|
| `~\.openclaw` | 2026.7.2 ✅ | 2.4.6 ✅ |
| 4 个子 profile | 2026.7.2 ✅ | 未装（保持原状）✅ |

`plugins list` 确认 **4/70 enabled**，两个通道插件的 source 已指向 `npm\projects\` 新布局。

**首次 7.x 启动触发的迁移（不可逆，共 47 个 `.migrated`）**

⚠️ **迁移是在阶段 E 的第一条 `plugins install` 就触发的，不是等到阶段 F 启动网关**。指南原先把不可逆点标在阶段 F，实际提前到 E。

- Cron store → SQLite：`cron\jobs.json`、`cron\jobs-state.json` + **34 个** `cron\runs\*.jsonl` 全部改名 `.migrated`
- 222 task registry / 10 task delivery / 114 task flow → SQLite，`tasks\runs.sqlite`、`flows\registry.sqlite`（含 -shm/-wal）归档
- **87 条 outbound delivery queue → SQLite，`delivery-queue\` 目录被直接删除**（不是改名）
- `update-check.json`、`logs\config-health.json`、`exec-approvals.json` 归档
- Memory Core：short-term recall 4 行 + main 记忆索引（23 源 / 186 chunk）→ per-agent SQLite，`memory\main.sqlite` 归档
- `state\openclaw.sqlite` 从 1.16MB 增长到 11.6MB
- 持续提示 `Left plugin install index in place because shared SQLite state has conflicting plugin install metadata` —— 属预期，`plugins\installs.json` 保留未动

**`openclaw.json` 被 7.x 重写，但只动了 2 个字段**：`meta.lastTouchedAt`、`meta.lastTouchedVersion`。字节数从 35471 降到 33922 纯粹是重新格式化。agents.list 5 个、skills.entries 302 条且仍只启用 `qrcode-viewer`、5 个 agent 的模型分配与 fallback 链全部保留。

**阶段 F/G — 验证结果**

- 5 份 `config validate` 全过
- 主网关 `[gateway] ready` **3.0s**（5.7 时 9.4s）；`Repaired OpenClaw host peer link(s) for 2 managed npm plugin package(s)` 自动修复
- 当前运行日志（按 18789 进程启动时间切片后统计）：`missing-openclaw-peer` / `peer link audit` / `refusing to report` 匹配 **0**
- 主网关 4 插件、4 个子 Agent 各 1 插件（wecom）
- wecom WebSocket 连接 + 认证成功（2026.7.2）；weixin monitor 启动并恢复 sync 游标
- 模型调用 status=200 × 7，**0** 个 4xx/5xx、0 个 model-fetch error、0 个 FailoverError
- wecom 出站实测成功：`Reply message sent` + `Reply ack received`
- 启动器全栈 80.6s，9 个服务全部 `[OK]`：18789 / 8899 / 8900 / 3020 / 3040 / 3060 / 3080 / 8901 / 8902
- 16 个 HTTP 端点全部 200；8900 `/api/config` 回显 5 agent / 18 模型 / `gateway.port=18789`；8899 `/api/status` 5 agent 全部 `online:true`
- cron 自动恢复运行，并清理了 3 个上次中断遗留的 stale `runningAtMs` 标记

**7.x 的一个行为变化（会影响 cron 任务）**

配置了多个通道时，`message` 工具**必须显式指定 channel**，否则报：

```
Channel is required when multiple channels are configured: openclaw-weixin, wecom.
Pass --channel <channel> to choose one.
```

实测有一个 cron 任务（cc-hosts 普查）因任务内部直接调 `message` 而失败 —— 这本来就违反项目规则第 7 条"任务内部禁止调用 message，通知交给 `delivery`"。同一任务的 `delivery` 投递是成功的。**排查同类问题时先确认任务是否违规自己发通知。**

### 11.13 待确认的遗留项

| 项目 | 状态 |
|------|------|
| **mcporter** | 两个运行时的 `node_modules\mcporter` **都不存在**，只有 `mcporter.ps1` 壳 —— 这是启动器显示 `mcporter N/A` 的真正原因，与升级无关。如需该功能须单独安装 |
| 启动器 `npm N/A` | `OpenClaw.ps1` 第 443 行用 `execSync('npm -v')` 依赖 PATH，便携版 Node 不在 PATH 里。新运行时 npm 实为 10.9.8。建议改为 require `node_modules/npm/package.json`（纯显示问题，未改） |
| 8899 面板 main 端口硬编码 | `dashboard-server.cjs` 第 196 行 `portMap = { 'main': 18789 }`（第 105 行同样以 18789 兜底）违反项目规则，建议改为读 `config.gateway.port`。生产端口恰好相同，已实测 main 显示 online，不阻塞 |
| 两通道入站实测 | 出站已验证（wecom `Reply ack received`）。**入站需你在企业微信和微信各发一条消息**确认 `kind=final` 回复送达 |
| legacy 插件目录 | `<home>\npm\node_modules\` 下 5 处旧安装未清理（含主目录那份 openclaw 2026.6.1 完整副本），作为回滚素材保留。观察若干天稳定后可清 |
| `gateway.controlUi.allowInsecureAuth=true` | 安全警告仍在，属独立待决事项 |
| Bot Review 模型写入路径 | `agent-model/route.ts` 的 PATCH 会把 `{primary, fallbacks}` 对象覆盖成字符串，**丢失 fallback 链**。改模型请用 webchat，勿用 8900 下拉框 |
| `refresh_token.py` | 仍硬编码旧账号路径与旧 SSO URL。当前凭据链路不经过该脚本，暂未修改 |
| 子 profile 插件版本漂移 | 4 个子 profile 的 wecom 停留在 2026.5.14（主目录 2026.5.25）。阶段 E 会一并对齐到 2026.7.2 |

---

*最后更新：2026-08-05 —— **生产已升级到 openclaw 2026.7.1-2 / Node v22.23.2 并验证通过**。第十一节新增 §11.6 沙箱隔离缺陷、§11.2②-补 插件 5 位置重装、§11.10 阶段 E 扩展、§11.11 面板实测、§11.12 生产升级实测记录。*
