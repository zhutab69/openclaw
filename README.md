# OpenClaw 多模型网关项目

**完成日期**: 2026-04-16  
**状态**: ✅ 所有服务正常运行

---

## 🏗️ 项目架构

```
┌─────────────────────────────────────────────────────────────────┐
│                     OpenClaw 多模型网关系统                        │
└─────────────────────────────────────────────────────────────────┘

┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│  Kiro Gateway    │  │  Trae Gateway    │  │  Direct APIs     │
│  (子项目 1)       │  │  (子项目 2)       │  │  (Anthropic/     │
│  端口: 9000      │  │  端口: 9010      │  │   OpenAI)        │
│  模型: 13 个     │  │  模型: 12 个     │  │  模型: 6 个      │
└────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘
         │                     │                     │
         └─────────────────────┼─────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │  OpenClaw 主项目     │
                    │  (子项目 3)          │
                    │  Main Agent: 18789  │
                    │  聚合 31 个模型      │
                    └──────────┬──────────┘
                               │
         ┌─────────────────────┼─────────────────────┐
         │                     │                     │
    ┌────▼────┐          ┌────▼────┐          ┌────▼────┐
    │ Writer  │          │   Dev   │          │  Info   │
    │  3010   │          │  3020   │          │  3030   │
    └─────────┘          └─────────┘          └─────────┘
         │                     │                     │
         └─────────────────────┼─────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Image Agent: 3040  │
                    └─────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                        辅助服务                                    │
├──────────────────────────────────────────────────────────────────┤
│  Multi-Agent Hub (8899)  │  Bot Review Center (8900)             │
│  多智能体管理中心          │  (子项目 4)                            │
└──────────────────────────────────────────────────────────────────┘
```

### 子项目说明
- **子项目 1**: `kiro-gateway/` - Kiro 模型代理
- **子项目 2**: `trae-gateway/` - Trae 模型代理
- **子项目 3**: `node-v22.22.1-win-x64/` - OpenClaw 主项目（含 Multi-Agent Hub）
- **子项目 4**: `OpenClaw-bot-review/` - Bot 审查中心

---

## 📋 目录

- [快速开始](#-快速开始)
- [项目结构](#-项目结构)
- [可用模型](#-可用模型)
- [服务状态](#-服务状态)
- [配置说明](#-配置说明)
- [常用命令](#-常用命令)
- [扩展建议](#-扩展建议)
- [故障排查](#-故障排查)

---

## 🚀 快速开始

### 启动所有服务
```bash
# Windows - 双击启动（推荐）
StartOpenClaw.bat

# 或使用 PowerShell
powershell -ExecutionPolicy Bypass -File OpenClaw.ps1
```

**启动的服务**:
- ✅ Kiro Gateway (端口 9000)
- ✅ Trae Gateway (端口 9010)
- ✅ OpenClaw Main Agent (端口 18789)
- ✅ OpenClaw Sub-Agents (端口 3010, 3020, 3030, 3040)
- ✅ Multi-Agent Hub (端口 8899)
- ✅ Bot Review Center (端口 8900)

### 同步模型
```bash
# 同步所有模型到 OpenClaw 和 Sub-Agents
python sync_models.py
```

**同步范围**:
- ✅ Kiro Gateway 模型 (13 个)
- ✅ Trae Gateway 模型 (12 个)
- ✅ Anthropic 原生模型 (3 个)
- ✅ OpenAI 原生模型 (3 个)
- ✅ 更新所有 Sub-Agent 配置

### 访问服务
- **OpenClaw Main**: http://127.0.0.1:18789/
- **Multi-Agent Hub**: http://127.0.0.1:8899/
- **Bot Review Center**: http://127.0.0.1:8900/
- **Kiro Gateway**: http://127.0.0.1:9000/v1/models
- **Trae Gateway**: http://127.0.0.1:9010/v1/models

---

## 📁 项目结构

### 总览
```
testopenclaw/                      # 项目根目录
├── README.md                      # 本文件（项目总览）
├── sync_models.py                 # 模型同步脚本（同步到所有子项目）
├── OpenClaw.ps1                   # 一键启动脚本（启动所有服务）
├── StartOpenClaw.bat              # 启动入口
│
├── kiro-gateway/                  # 子项目 1: Kiro Gateway
│   ├── README.md                  # Kiro Gateway 文档
│   ├── main.py                    # 主程序
│   ├── .env                       # 环境配置
│   ├── requirements.txt           # 依赖包
│   └── kiro/                      # 核心代码
│
├── trae-gateway/                  # 子项目 2: Trae Gateway
│   ├── README.md                  # Trae Gateway 文档
│   ├── main.py                    # 主程序
│   ├── .env                       # 环境配置
│   ├── requirements.txt           # 依赖包
│   └── kiro/                      # 核心代码
│       ├── auth_trae.py           # Trae 认证管理器
│       └── config.py              # Trae 配置
│
├── node-v22.22.1-win-x64/         # 子项目 3: OpenClaw (主项目)
│   ├── openclaw                   # OpenClaw 可执行文件
│   ├── node.exe                   # Node.js 运行时
│   └── node_modules/              # OpenClaw 依赖
│       └── @openclaw/             # OpenClaw 核心
│           ├── dashboard-server.js    # 多智能体管理中心 (端口 8899)
│           └── dashboard.html         # 管理中心前端
│
└── OpenClaw-bot-review/           # 子项目 4: Bot Review Center
    ├── app/                       # Next.js 应用
    ├── package.json               # 项目配置
    └── ...                        # 其他文件
```

### 子项目详情

#### 1️⃣ Kiro Gateway (kiro-gw)
- **目录**: `kiro-gateway/`
- **端口**: 9000
- **功能**: Kiro API 代理网关
- **模型数**: 13 个
- **状态**: ✅ 完全可用
- **文档**: `kiro-gateway/README.md`

#### 2️⃣ Trae Gateway (trae-gw)
- **目录**: `trae-gateway/`
- **端口**: 9010
- **功能**: Trae 内置模型代理网关
- **模型数**: 12 个
- **状态**: ⚠️ 模型列表可用，Chat API 待实现
- **文档**: `trae-gateway/README.md`

#### 3️⃣ OpenClaw (主项目)
- **目录**: `node-v22.22.1-win-x64/`
- **主要服务**:
  - **Main Agent** (端口 18789) - OpenClaw 主网关
  - **Writer Agent** (端口 3010) - 写作 Agent
  - **Dev Agent** (端口 3020) - 开发 Agent
  - **Info Agent** (端口 3030) - 信息 Agent
  - **Image Agent** (端口 3040) - 图像 Agent
  - **Multi-Agent Hub** (端口 8899) - 多智能体管理中心
- **功能**: 聚合所有 provider 的模型，提供统一接口
- **模型数**: 31 个（聚合）
- **状态**: ✅ 完全可用

#### 4️⃣ Bot Review Center
- **目录**: `OpenClaw-bot-review/`
- **端口**: 8900
- **功能**: Bot 审查中心
- **状态**: ✅ 运行中

### 配置文件位置
- **OpenClaw 主配置**: `C:\Users\zhuyulin\.openclaw\openclaw.json`
- **Sub-Agents 配置**:
  - Writer: `C:\Users\zhuyulin\.openclaw-writer\openclaw.json`
  - Dev: `C:\Users\zhuyulin\.openclaw-dev\openclaw.json`
  - Info: `C:\Users\zhuyulin\.openclaw-info\openclaw.json`
  - Image: `C:\Users\zhuyulin\.openclaw-image\openclaw.json`
- **Kiro Gateway**: `kiro-gateway/.env`
- **Trae Gateway**: `trae-gateway/.env`

---

## 🤖 可用模型

### 总计: 31 个模型

| Provider | 模型数 | 端口 | 状态 | 说明 |
|----------|--------|------|------|------|
| **kiro-gw** | 13 | 9000 | ✅ 完全可用 | Kiro Gateway 代理 |
| **trae-gw** | 12 | 9010 | ⚠️ 列表可用 | Trae 内置模型 |
| **anthropic** | 3 | - | ✅ 完全可用 | Anthropic 原生 API |
| **openai** | 3 | - | ✅ 完全可用 | OpenAI 原生 API |

### Kiro Gateway 模型 (13 个)
```
kiro-gw/auto-kiro
kiro-gw/claude-3.7-sonnet
kiro-gw/claude-haiku-4.5
kiro-gw/claude-opus-4.5
kiro-gw/claude-opus-4.6
kiro-gw/claude-sonnet-4
kiro-gw/claude-sonnet-4.5
kiro-gw/claude-sonnet-4.6
kiro-gw/gemini-2.0-flash-exp
kiro-gw/gemini-2.0-flash-thinking-exp-1219
kiro-gw/gemini-exp-1206
kiro-gw/gpt-4o
kiro-gw/gpt-4o-mini
```

### Trae Gateway 模型 (12 个)
```
trae-gw/doubao-seed-2.0-code    # 字节跳动 - 代码专用
trae-gw/doubao-seed-1.8         # 字节跳动 - 通用
trae-gw/doubao-seed-code        # 字节跳动 - 代码专用
trae-gw/minimax-m2.7            # MiniMax - 通用
trae-gw/minimax-m2.5            # MiniMax - 通用
trae-gw/glm-5.1                 # 智谱 AI - 通用
trae-gw/glm-5v-turbo            # 智谱 AI - 视觉
trae-gw/glm-5                   # 智谱 AI - 通用
trae-gw/deepseek-v3.1-terminus  # DeepSeek - 代码专用
trae-gw/kimi-k2.5               # 月之暗面 - 长文本
trae-gw/qwen3.5-plus            # 阿里云 - 通用
trae-gw/qwen3-coder-next        # 阿里云 - 代码专用
```

### Anthropic 原生模型 (3 个)
```
anthropic/claude-3-5-sonnet-20241022
anthropic/claude-3-5-haiku-20241022
anthropic/claude-3-opus-20240229
```

### OpenAI 原生模型 (3 个)
```
openai/gpt-4-turbo
openai/gpt-4
openai/gpt-3.5-turbo
```

---

## 📊 服务状态

### Gateway 服务

| 服务 | 端口 | 子项目 | 状态 | 说明 |
|------|------|--------|------|------|
| **Kiro Gateway** | 9000 | kiro-gateway | ✅ 运行中 | Kiro 模型代理 |
| **Trae Gateway** | 9010 | trae-gateway | ⚠️ 部分可用 | 模型列表可用，Chat API 待实现 |

### OpenClaw 主项目服务

| 服务 | 端口 | 子项目 | 状态 | 说明 |
|------|------|--------|------|------|
| **Main Agent** | 18789 | node-v22.22.1-win-x64 | ✅ 运行中 | OpenClaw 主网关 |
| **Writer Agent** | 3010 | node-v22.22.1-win-x64 | ✅ 运行中 | 写作 Agent |
| **Dev Agent** | 3020 | node-v22.22.1-win-x64 | ✅ 运行中 | 开发 Agent |
| **Info Agent** | 3030 | node-v22.22.1-win-x64 | ✅ 运行中 | 信息 Agent |
| **Image Agent** | 3040 | node-v22.22.1-win-x64 | ✅ 运行中 | 图像 Agent |
| **Multi-Agent Hub** | 8899 | node-v22.22.1-win-x64 | ✅ 运行中 | 多智能体管理中心 |

### 辅助服务

| 服务 | 端口 | 子项目 | 状态 | 说明 |
|------|------|--------|------|------|
| **Bot Review Center** | 8900 | OpenClaw-bot-review | ✅ 运行中 | Bot 审查中心 |

---

## ⚙️ 配置说明

### Kiro Gateway
- **端口**: 9000
- **API Key**: `my-super-secret-password-123`
- **认证方式**: Kiro credentials JSON
- **配置文件**: `kiro-gateway/.env`

### Trae Gateway
- **端口**: 9010
- **API Key**: `trae-super-secret-password-456`
- **认证方式**: CLI Token
- **CLI Token**: `trae-lt-5e18fe704f8e528f3c6819b32f1dea390032d1cace6c09eb89df8cf1`
- **配置文件**: `trae-gateway/.env`
- **状态**: 模型列表可用，Chat API 需要抓包实现

### 主模型配置
- **Primary Model**: `kiro-gw/claude-sonnet-4.5`
- **Fallbacks**: 自动配置所有可用模型

---

## 💻 常用命令

### 启动服务

#### 启动所有服务（推荐）
```bash
# 一键启动所有子项目
StartOpenClaw.bat
```

#### 单独启动子项目
```bash
# 启动 Kiro Gateway
cd kiro-gateway
python main.py

# 启动 Trae Gateway
cd trae-gateway
python main.py

# 启动 OpenClaw（主项目）
cd node-v22.22.1-win-x64
openclaw

# 启动 Bot Review Center
cd OpenClaw-bot-review
npm run dev
```

### 模型管理
```bash
# 同步所有模型到 OpenClaw 和 Sub-Agents
python sync_models.py

# 查看 Kiro Gateway 模型
curl http://127.0.0.1:9000/v1/models \
  -H "Authorization: Bearer my-super-secret-password-123"

# 查看 Trae Gateway 模型
curl http://127.0.0.1:9010/v1/models \
  -H "Authorization: Bearer trae-super-secret-password-456"

# 查看 OpenClaw Main Gateway 模型（聚合所有 provider）
curl http://127.0.0.1:18789/v1/models
```

### 测试 Chat API
```bash
# 测试 Kiro Gateway
curl http://127.0.0.1:9000/v1/chat/completions \
  -H "Authorization: Bearer my-super-secret-password-123" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4.5",
    "messages": [{"role": "user", "content": "Hello"}]
  }'

# 测试 OpenClaw Main Gateway
curl http://127.0.0.1:18789/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "kiro-gw/claude-sonnet-4.5",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

---

## 🔧 扩展建议

### 添加更多模型提供商

如果需要使用其他服务商的模型，可以在 `sync_models.py` 中添加：

```python
DIRECT_PROVIDERS = {
    # ... 现有配置 ...
    
    "volcengine": {  # 火山引擎（Doubao）
        "api": "openai-completions",
        "baseUrl": "https://ark.cn-beijing.volces.com/api/v3/",
        "models": [
            {"id": "doubao-pro-32k", "name": "Doubao Pro 32K", ...},
        ]
    },
    
    "minimax": {  # MiniMax
        "api": "openai-completions",
        "baseUrl": "https://api.minimax.chat/v1/",
        "models": [
            {"id": "abab6.5-chat", "name": "MiniMax ABAB 6.5", ...},
        ]
    },
    
    "deepseek": {  # DeepSeek
        "api": "openai-completions",
        "baseUrl": "https://api.deepseek.com/",
        "models": [
            {"id": "deepseek-chat", "name": "DeepSeek Chat", ...},
        ]
    },
    
    "zhipu": {  # 智谱 AI (GLM)
        "api": "openai-completions",
        "baseUrl": "https://open.bigmodel.cn/api/paas/v4/",
        "models": [
            {"id": "glm-4-plus", "name": "GLM-4 Plus", ...},
        ]
    }
}
```

**注意**: 需要先注册对应服务商账号并获取 API Key，然后在 `openclaw.json` 中配置 `apiKey`。

---

## 🐛 故障排查

### Gateway 无法启动

**检查端口占用**:
```bash
netstat -ano | findstr "9000"
netstat -ano | findstr "9010"
netstat -ano | findstr "18789"
```

**检查 Python 进程**:
```powershell
Get-Process python
```

**强制停止进程**:
```powershell
Stop-Process -Name python -Force
```

### 模型同步失败

**检查 Gateway 是否运行**:
```bash
curl http://127.0.0.1:9000/v1/models
curl http://127.0.0.1:9010/v1/models
```

**查看同步日志**:
```bash
python sync_models.py
```

**手动检查配置**:
```bash
# 查看主配置
cat C:\Users\zhuyulin\.openclaw\openclaw.json

# 查看备份（如果同步失败）
cat C:\Users\zhuyulin\.openclaw\openclaw.json.sync-bak
```

### 配置文件损坏

**恢复备份**:
```bash
copy C:\Users\zhuyulin\.openclaw\openclaw.json.sync-bak C:\Users\zhuyulin\.openclaw\openclaw.json
```

### Trae Gateway Chat API 不可用

**当前状态**: Trae Gateway 只支持模型列表查询，Chat API 需要抓包实现。

**解决方案**:
1. 使用 Fiddler 抓包 Trae CN 应用
2. 获取真实的 Chat API 端点和格式
3. 实现请求/响应转换器
4. 详见 `trae-gateway/README.md`

---

## 📚 详细文档

### 子项目文档
- **Kiro Gateway**: `kiro-gateway/README.md` - Kiro Gateway 完整文档
- **Trae Gateway**: `trae-gateway/README.md` - Trae Gateway 完整文档和实现指南
- **OpenClaw**: `node-v22.22.1-win-x64/README.md` - OpenClaw 主项目文档（如有）
- **Bot Review**: `OpenClaw-bot-review/README.md` - Bot Review Center 文档（如有）

### 项目规则
- **开发规则**: `.kiro/steering/project-rules.md` - 项目开发规范和注意事项

---

## 🔮 未来扩展

### 计划添加的子项目
本项目采用模块化设计，后续可以轻松添加新的子项目：

#### 可能的扩展方向
1. **新的 Gateway 子项目**
   - 其他 AI 服务商的代理网关
   - 自定义模型服务
   - 本地模型服务（Ollama, LM Studio 等）

2. **新的工具子项目**
   - 模型性能监控
   - 成本分析工具
   - 日志分析系统

3. **新的 Agent 子项目**
   - 专用领域 Agent
   - 工作流自动化 Agent
   - 数据处理 Agent

#### 添加新子项目的步骤
1. 在根目录创建新的子项目目录
2. 配置独立的端口和服务
3. 更新 `sync_models.py`（如需模型同步）
4. 更新 `OpenClaw.ps1`（如需自动启动）
5. 更新本 README.md 文档

---

## 🎯 项目完成情况

### ✅ 已完成
1. ✅ 修复 Main Gateway 启动问题（配置格式错误）
2. ✅ 配置 Kiro Gateway（13 个模型，完全可用）
3. ✅ 配置 Trae Gateway（12 个模型，列表可用）
4. ✅ 配置 Direct Providers（6 个模型，完全可用）
5. ✅ 同步 31 个模型到 OpenClaw 和所有 Sub-Agents
6. ✅ 所有服务正常运行
7. ✅ 完善项目文档

### ⏳ 待完成
1. ⏳ Trae Gateway Chat API 实现（需要抓包）
2. ⏳ 添加更多第三方服务商（可选）
3. ⏳ 优化模型选择和 fallback 策略（可选）

### 🎉 总结
- **所有核心功能正常运行**
- **31 个模型可用（19 个完全可用 + 12 个列表可用）**
- **架构清晰，易于扩展**
- **文档完善，便于维护**

---

**最后更新**: 2026-04-16  
**项目状态**: ✅ 生产就绪
