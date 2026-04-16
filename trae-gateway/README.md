# Trae Gateway

**基于 Kiro Gateway 的 Trae 模型代理网关**

---

## 📋 目录

- [当前状态](#-当前状态)
- [快速开始](#-快速开始)
- [模型列表](#-模型列表)
- [功能状态](#-功能状态)
- [技术架构](#-技术架构)
- [配置说明](#-配置说明)
- [下一步实现](#-下一步实现)

---

## 📊 当前状态

### ✅ 已完成
- ✅ 基础架构（基于 Kiro Gateway）
- ✅ 端口配置：9010
- ✅ CLI Token 认证
- ✅ 12 个 Trae 内置模型配置
- ✅ OpenClaw 集成（31 个模型同步）
- ✅ 模型列表 API (`/v1/models`)

### ⏳ 待完成
- ⏳ Chat API 实现（需要抓包获取端点）
- ⏳ 流式响应支持
- ⏳ 错误处理

### 📈 完成度
**70%** - 模型列表可用，Chat API 待实现

---

## 🚀 快速开始

### 启动 Gateway
```bash
# 进入目录
cd trae-gateway

# 启动服务
python main.py

# 或指定端口
python main.py --port 9010
```

### 查看模型列表
```bash
curl http://127.0.0.1:9010/v1/models \
  -H "Authorization: Bearer trae-super-secret-password-456"
```

### 测试（仅模型列表可用）
```bash
# 返回 12 个 Trae 模型
curl http://127.0.0.1:9010/v1/models \
  -H "Authorization: Bearer trae-super-secret-password-456"

# Chat API 暂不可用（返回 404）
curl http://127.0.0.1:9010/v1/chat/completions \
  -H "Authorization: Bearer trae-super-secret-password-456" \
  -H "Content-Type: application/json" \
  -d '{"model": "glm-5.1", "messages": [{"role": "user", "content": "Hello"}]}'
```

---

## 🤖 模型列表

### 12 个 Trae 内置模型

| 模型 ID | 模型名称 | 提供商 | 特性 |
|---------|----------|--------|------|
| doubao-seed-2.0-code | Doubao Seed 2.0 Code | 字节跳动 | 代码专用 |
| doubao-seed-1.8 | Doubao Seed 1.8 | 字节跳动 | 通用 |
| doubao-seed-code | Doubao Seed Code | 字节跳动 | 代码专用 |
| minimax-m2.7 | MiniMax M2.7 | MiniMax | 通用 |
| minimax-m2.5 | MiniMax M2.5 | MiniMax | 通用 |
| glm-5.1 | GLM 5.1 | 智谱 AI | 通用 |
| glm-5v-turbo | GLM 5V Turbo | 智谱 AI | 视觉 |
| glm-5 | GLM 5 | 智谱 AI | 通用 |
| deepseek-v3.1-terminus | DeepSeek V3.1 Terminus | DeepSeek | 代码专用 |
| kimi-k2.5 | Kimi K2.5 | 月之暗面 | 长文本 |
| qwen3.5-plus | Qwen 3.5 Plus | 阿里云 | 通用 |
| qwen3-coder-next | Qwen 3 Coder Next | 阿里云 | 代码专用 |

**模型来源**: https://docs.trae.cn/ide/models

---

## 🎯 功能状态

### ✅ 可用功能

#### 1. 模型列表查询
```bash
curl http://127.0.0.1:9010/v1/models \
  -H "Authorization: Bearer trae-super-secret-password-456"
```
返回 12 个 Trae 内置模型

#### 2. OpenClaw 集成
- 在 OpenClaw 中可以看到 `trae-gw/*` 模型
- 例如：`trae-gw/glm-5.1`, `trae-gw/doubao-seed-2.0-code`

#### 3. 模型同步
```bash
# 在项目根目录运行
python sync_models.py
```
自动同步所有模型到 OpenClaw 和 sub-agents

### ⏳ 待实现功能

#### 1. Chat API 调用
- **状态**: 需要抓包获取真实 API 端点
- **当前**: 返回 404（端点未知）
- **需要**: Trae 后端 Chat API 的 URL、请求格式、响应格式

#### 2. 流式响应
- 依赖于 Chat API 实现
- 需要了解 Trae 的 SSE 格式

#### 3. 错误处理
- 需要了解 Trae 特定的错误码和消息

---

## 🏗️ 技术架构

### 当前架构
```
OpenClaw (OpenAI 格式)
    ↓
Trae Gateway (端口 9010)
    ├─ /v1/models ✅ 返回 Trae 内置模型列表
    └─ /v1/chat/completions ⏳ 需要实现
        ↓ [待实现]
    Trae 后端 API (未知端点)
        ↓
    Trae 模型服务
```

### 关键组件

#### 已实现
```
trae-gateway/
├── main.py                    # 主程序（使用内置模型列表）
├── .env                       # 环境配置
├── requirements.txt           # 依赖包
└── kiro/
    ├── auth_trae.py          # Trae 认证管理器
    ├── config.py             # Trae 配置（内置模型列表）
    ├── routes_openai.py      # OpenAI 兼容路由
    └── ...                   # 其他 Kiro Gateway 组件
```

#### 待实现
```
trae-gateway/kiro/
├── converters_trae.py        # 请求/响应转换器
├── streaming_trae.py         # 流式响应处理
└── config.py                 # 更新 Chat API 端点配置
```

---

## ⚙️ 配置说明

### 环境变量 (.env)
```bash
# Trae Gateway 配置
PROXY_API_KEY="trae-super-secret-password-456"
SERVER_PORT="9010"
SERVER_HOST="0.0.0.0"

# Trae CLI Token（推荐）
TRAE_CLI_TOKEN="trae-lt-5e18fe704f8e528f3c6819b32f1dea390032d1cace6c09eb89df8cf1"

# 或使用 Trae 认证文件（备选）
# KIRO_CREDS_FILE="C:/Users/zhuyulin/AppData/Roaming/Trae CN/User/globalStorage/storage.json"

# 日志级别
LOG_LEVEL="INFO"
```

### 认证配置
- **CLI Token**: `trae-lt-5e18fe704f8e528f3c6819b32f1dea390032d1cace6c09eb89df8cf1`
- **来源**: https://console.enterprise.trae.cn/personal/token
- **优先级**: CLI Token > storage.json
- **状态**: ✅ 正常工作

### 模型配置
- **配置文件**: `kiro/config.py`
- **FALLBACK_MODELS**: 12 个 Trae 内置模型
- **来源**: Trae 官方文档
- **更新方式**: 手动更新（当 Trae 发布新模型时）

---

## 🔧 下一步实现

### 方案 A：使用 Fiddler 抓包（推荐）

**目标**: 获取 Trae 真实的 Chat API 端点和格式

**步骤**:
1. **安装 Fiddler**
   - 下载: https://www.telerik.com/fiddler
   - 配置 HTTPS 解密

2. **抓包 Trae CN**
   - 启动 Fiddler
   - 打开 Trae CN (`D:\Trae CN`)
   - 在 Trae 中使用内置模型进行对话
   - 在 Fiddler 中查找 Chat API 请求

3. **记录信息**
   - 完整的 URL（例如：`https://xxx.trae.cn/xxx/chat`）
   - 请求头（Authorization 格式、Content-Type 等）
   - 请求体格式（JSON 结构）
   - 响应格式（流式/非流式）

**预期结果**:
```
URL: https://trae-api-cn.mchost.guru/v1/chat/completions (示例)
Headers:
  Authorization: Bearer trae-lt-xxx
  Content-Type: application/json
Body:
  {
    "model": "glm-5.1",
    "messages": [...],
    "stream": true
  }
```

### 方案 B：检查 Trae CN 应用代码

**步骤**:
1. 进入 Trae CN 安装目录：`D:\Trae CN\resources\app\`
2. 查找 `.asar` 文件
3. 使用 `asar` 工具解包：
   ```bash
   npm install -g asar
   asar extract app.asar app_extracted
   ```
4. 搜索 API 端点相关代码：
   ```bash
   grep -r "chat" app_extracted/
   grep -r "completions" app_extracted/
   grep -r "api" app_extracted/
   ```

### 实现 Chat API 的步骤

#### 1. 更新 API 端点配置
```python
# kiro/auth_trae.py
@property
def api_host(self):
    return "https://真实的Chat API端点"
```

#### 2. 创建请求/响应转换器
```python
# kiro/converters_trae.py
def convert_openai_to_trae(request):
    """将 OpenAI 格式请求转换为 Trae 格式"""
    trae_request = {
        "model": request["model"],
        "messages": request["messages"],
        "stream": request.get("stream", False),
        # ... 其他 Trae 特定字段
    }
    return trae_request

def convert_trae_to_openai(response):
    """将 Trae 响应转换为 OpenAI 格式"""
    openai_response = {
        "id": response.get("id"),
        "object": "chat.completion",
        "model": response.get("model"),
        "choices": [{
            "message": {
                "role": "assistant",
                "content": response.get("content")
            }
        }]
    }
    return openai_response
```

#### 3. 更新路由处理
```python
# kiro/routes_openai.py
# 在 chat_completions 函数中使用 Trae 转换器
from kiro.converters_trae import convert_openai_to_trae, convert_trae_to_openai

# 转换请求
trae_request = convert_openai_to_trae(request_data)

# 调用 Trae API
response = await http_client.post(
    f"{auth_manager.api_host}/chat/completions",
    json=trae_request,
    headers=headers
)

# 转换响应
openai_response = convert_trae_to_openai(response.json())
```

#### 4. 实现流式响应
```python
# kiro/streaming_trae.py
async def stream_trae_response(response):
    """处理 Trae 的 SSE 流式响应"""
    async for line in response.aiter_lines():
        if line.startswith("data: "):
            data = json.loads(line[6:])
            # 转换为 OpenAI SSE 格式
            yield f"data: {json.dumps(convert_chunk(data))}\n\n"
```

#### 5. 测试
```bash
# 测试 Chat API
curl http://127.0.0.1:9010/v1/chat/completions \
  -H "Authorization: Bearer trae-super-secret-password-456" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "glm-5.1",
    "messages": [{"role": "user", "content": "Hello"}]
  }'

# 测试流式响应
curl http://127.0.0.1:9010/v1/chat/completions \
  -H "Authorization: Bearer trae-super-secret-password-456" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "glm-5.1",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'
```

---

## 💡 关键发现

### 1. Trae 架构与 Kiro 不同
- **Kiro**: 从 API 动态获取模型列表
- **Trae**: 模型是 IDE 内置的（硬编码）

### 2. Trae 没有模型列表 API
- 测试了多个端点，均返回 404
- 唯一可用的是 MCP Agent 搜索端点（但不返回模型列表）

### 3. 正确的实施方案
- 使用 Trae 文档中的内置模型列表
- Gateway 的作用是格式转换，不是模型发现

### 4. API 端点需要抓包
- Trae 的 Chat API 端点未公开
- 需要通过抓包 Trae CN 应用来获取

---

## 📊 测试结果

### 模型列表测试 ✅
```bash
$ curl http://127.0.0.1:9010/v1/models \
  -H "Authorization: Bearer trae-super-secret-password-456"

{
  "object": "list",
  "data": [
    {"id": "deepseek-v3.1-terminus", ...},
    {"id": "doubao-seed-1.8", ...},
    {"id": "doubao-seed-2.0-code", ...},
    {"id": "doubao-seed-code", ...},
    {"id": "glm-5", ...},
    {"id": "glm-5.1", ...},
    {"id": "glm-5v-turbo", ...},
    {"id": "kimi-k2.5", ...},
    {"id": "minimax-m2.5", ...},
    {"id": "minimax-m2.7", ...},
    {"id": "qwen3-coder-next", ...},
    {"id": "qwen3.5-plus", ...}
  ]
}
```

### Chat API 测试 ❌
```bash
$ curl http://127.0.0.1:9010/v1/chat/completions \
  -H "Authorization: Bearer trae-super-secret-password-456" \
  -H "Content-Type: application/json" \
  -d '{"model": "glm-5.1", "messages": [{"role": "user", "content": "Hello"}]}'

HTTP Error 404: Not Found
```

---

## 🎯 成功标准

### 阶段 1：模型列表可见 ✅ 已完成
- ✅ Trae Gateway 运行在 9010 端口
- ✅ `/v1/models` 返回 12 个 Trae 模型
- ✅ OpenClaw 可以看到 `trae-gw/*` 模型
- ✅ 模型同步到所有 sub-agents

### 阶段 2：Chat API 可用 ⏳ 待实现
- ⏳ 找到真实的 Chat API 端点
- ⏳ 实现请求/响应转换
- ⏳ 支持流式和非流式响应
- ⏳ 在 OpenClaw 中成功使用 Trae 模型

---

## 📚 相关文档

- **Kiro Gateway 原始文档**: 本项目基于 Kiro Gateway
- **Trae 官方文档**: https://docs.trae.cn/ide/models
- **项目根目录 README**: `../README.md` - 完整项目说明

---

## 🔗 有用的链接

- **Trae 企业控制台**: https://console.enterprise.trae.cn
- **Trae CLI Token**: https://console.enterprise.trae.cn/personal/token
- **Trae 文档**: https://docs.trae.cn
- **Kiro Gateway**: https://github.com/jwadow/kiro-gateway

---

**更新时间**: 2026-04-16  
**状态**: 模型列表配置完成，等待 Chat API 端点信息  
**下一步**: 使用 Fiddler 抓包获取 Chat API 端点
