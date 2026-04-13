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

## 2. 端口修改规则

修改子 agent 端口时，必须同步更新以下三个文件，保持一致：

1. `OpenClaw.ps1` — `$subAgents` 数组、`$targetPorts`、`$allPorts`
2. `C:\Users\zhuyulin\.openclaw\workspace\dashboard-server.js` — `agents` 数组里的 port
3. `C:\Users\zhuyulin\.openclaw\workspace\dashboard.html` — JS 里的 port

## 3. 文件编码规则

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

## 4. openclaw.json 修改规则

`sync_models.py` 只能更新 `models` 和 `agents.defaults`，**禁止覆盖 `agents.list`**，否则会丢失所有子 agent 配置。

## 5. 项目文件结构

- `OpenClaw.ps1` — 一键启动脚本（主要维护文件）
- `StartOpenClaw.bat` — 启动入口（调用 ps1）
- `kiro-gateway/` — Kiro Gateway 项目
- `sync_models.py` — 模型同步脚本（根目录，合并了 Kiro Gateway 模型获取 + sub-agent 同步）
- `node-v22.22.1-win-x64/` — Node.js + OpenClaw 2026.3.13
- `C:\Users\zhuyulin\.openclaw\openclaw.json` — OpenClaw 主配置
- `C:\Users\zhuyulin\.openclaw\workspace\dashboard-server.js` — 多 agent 监控服务
- `C:\Users\zhuyulin\.openclaw\workspace\dashboard.html` — 监控页面
