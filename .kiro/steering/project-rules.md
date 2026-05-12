---
inclusion: always
---

# OpenClaw 项目开发规则

## 1. 修改确认规则（必须遵守）

**每次修改前，必须先读取涉及的项目文件（避免有手工改动未记录），然后分析总结改动内容，向用户确认后再执行。**

格式：
- 改动目的：xxx
- 涉及文件：xxx
- 具体改动：xxx
- 潜在风险：xxx

等用户确认后才能执行。

## 2. Agent 配置规则（重要）

**禁止硬编码 agent 信息，所有配置必须从 `openclaw.json` 动态读取。**

### 2.1 配置文件为唯一数据源

- 所有 agent 配置（main agent 和 sub-agent）都在 `C:\Users\zhuyulin\.openclaw\openclaw.json` 的 `agents.list` 中
- Agent 信息包括：id、name、port、model、identity.emoji、workspace 等
- 代码必须支持任意数量的 agent，不能假设固定数量

### 2.2 禁止硬编码的内容

❌ **禁止**：
- 硬编码 agent 列表：`["main", "writer-agent", "coder-agent"]`
- 硬编码端口映射：`{ "writer-agent": 3010, "coder-agent": 3020 }`
- 硬编码 agent 名称：`"文墨"、"码农"`
- 假设固定数量：`if (agents.length === 5)`

✅ **正确**：
- 从配置读取：`agent.port || 18789`
- 动态遍历：`config.agents.list.forEach(agent => ...)`
- 使用配置字段：`agent.name || agent.id`

### 2.3 配置读取优先级

- **Agent 名称**：`agent.name` > IDENTITY.md > `agent.id`
- **Agent 图标**：`agent.identity.emoji` > IDENTITY.md > "🤖"
- **Agent 端口**：`agent.port` > 18789（主网关端口）
- **Agent 模型**：`agent.model` > `agents.defaults.model.primary`

### 2.4 添加新 Agent 的流程

1. 在 `openclaw.json` 的 `agents.list` 中添加配置
2. 创建对应的 workspace 目录（如需要）
3. 重启 OpenClaw 服务
4. **无需修改任何代码**

详见 `OpenClaw-bot-review/DEVELOPMENT.md`

## 3. 端口修改规则（已废弃，保留用于向后兼容）

**注意**：端口配置现在统一在 `openclaw.json` 中管理，以下文件会自动从配置读取：

1. `OpenClaw.ps1` — 从 `openclaw.json` 读取 agent 端口
2. `OpenClaw-bot-review/app/api/config/route.ts` — 从 `openclaw.json` 读取端口
3. `C:\Users\zhuyulin\.openclaw\workspace\dashboard-server.js` — 需要手动同步（待优化）

修改端口时，只需修改 `openclaw.json` 中的 `agents.list[].port` 字段。

## 4. 文件编码规则

修改 `dashboard-server.js` 和 `dashboard.html` 时：
- **必须用 Python** 读写，保持 UTF-8 无 BOM 编码
- **禁止用 PowerShell** 的 `Get-Content` + `WriteAllText`，会导致中文乱码

```python
# 正确方式
with open(fpath, 'r', encoding='utf-8') as f:
    text = f.read()
# 修改 text ...
with open(fpath, 'w', encoding='utf-8') as f:
    f.write(text)
```

## 5. openclaw.json 修改规则

`sync_models.py` 只能更新 `models` 和 `agents.defaults`，**禁止覆盖 `agents.list`**，否则会丢失所有子 agent 配置。

## 6. 任务完整性校验规则（必须遵守）

**所有任务完成后，必须校验完整性。涉及代码修改的任务更需严格校验。**

### 6.1 校验要求

- 每个任务完成后，必须验证修改是否完整生效（构建、运行、功能测试）
- 涉及代码修改时，必须确认：编译通过、功能正常、无遗漏文件
- 涉及多文件修改时，逐一确认每个文件的改动已保存并生效
- 如遇重启、断连等中断，恢复后必须重新检查任务进度，从断点继续而非重头开始

### 6.2 代码修改校验清单

- [ ] 所有修改的文件已保存
- [ ] 构建/编译通过（如 `npm run build`）
- [ ] 服务可正常启动
- [ ] 功能验证通过（API 返回正确、页面显示正确）
- [ ] 无残留的临时代码或调试输出

### 6.3 阶段性进展反馈

多步骤任务执行过程中，必须在每个关键节点输出进展：

格式：
```
[进度 X/N] 步骤描述... ✅ 完成 / ❌ 失败
```

示例：
```
[1/4] 修改 config/route.ts... ✅
[2/4] 修改 agent-status/route.ts... ✅
[3/4] 重新构建 Bot Review... ✅
[4/4] 验证 API 返回... ✅ 所有 agent 状态正确
```

- 每完成一个文件修改、一次构建、一次验证，都要输出当前进度
- 遇到错误时立即报告，不要静默跳过
- 任务结束时输出总结：改了什么、验证了什么、还有什么待确认

### 6.4 避免不完整修改

- 不要假设修改已生效，必须实际验证
- 多步骤修改中，每步完成后确认再进行下一步
- 如果修改涉及构建步骤（如 Bot Review 的 `npm run build`），必须重新构建后才算完成

## 7. Cron 定时任务规则

- **任务内部禁止调用 message 工具发送通知**，通知统一交给 `delivery` 配置
- 根因：WSClient 断连 → message 失败 → job status=error → 调度器 backoff 漂移
- `wakeMode` 必须设为 `"now"`（避免依赖心跳周期）
- `staggerMs` 设为 `0`（不需要随机延迟）
- 任务执行结果通过 `delivery.mode: "announce"` 发送，与任务逻辑解耦

## 8. 项目文件结构

- `OpenClaw.ps1` — 一键启动脚本（主要维护文件）
- `StartOpenClaw.bat` — 启动入口（调用 ps1）
- `kiro-gateway/` — Kiro Gateway 项目
- `sync_models.py` — 模型同步脚本（根目录，合并了 Kiro Gateway 模型获取 + sub-agent 同步）
- `node-v22.22.1-win-x64/` — Node.js + OpenClaw 2026.3.13
- `C:\Users\zhuyulin\.openclaw\openclaw.json` — OpenClaw 主配置
- `C:\Users\zhuyulin\.openclaw\workspace\dashboard-server.js` — 多 agent 监控服务
- `C:\Users\zhuyulin\.openclaw\workspace\dashboard.html` — 监控页面
