
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

---

*最后更新：2026-07-07*
