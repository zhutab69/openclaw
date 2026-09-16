# SKILL_EXTENSIONS.md - 扩展层触发词索引

> 扩展层 skill 不直接加载到 prompt，通过场景触发词自动发现并按需加载。
> Agent 在任务开始时扫描此文件的触发词表，命中则 read 对应 SKILL.md 后执行。

## 扫描规则

1. 每次收到用户消息时，扫描下方触发词表
2. 如果用户消息中包含任一触发词/场景描述 → read 对应 SKILL.md
3. 如果多个扩展 skill 命中 → 选最具体的（参考 SKILL_RULES.md 路由决策表）
4. 扩展层 skill 使用前标注：📖 调用技能：<name>（扩展层）

## 触发词索引

| Skill | 触发词/场景 | 位置 |
|-------|------------|------|
| wecom-doc | 企微文档、doc.weixin.qq.com、新建文档、覆写文档、智能文档、文档内容 | ~/.openclaw/plugin-skills/wecom-doc/SKILL.md |
| wecom-contact | 查通讯录、找人、查联系方式、成员查询 | ~/.openclaw/plugin-skills/wecom-contact/SKILL.md |
| wecom-smartsheet | 智能表格、表格记录、字段管理、增删改查 | ~/.openclaw/plugin-skills/wecom-smartsheet/SKILL.md |
| wecom-todo | 待办、创建待办、待办列表、标记完成、分派任务 | ~/.openclaw/plugin-skills/wecom-todo/SKILL.md |
| wecom-meeting | 创建会议、预约会议、会议列表、取消会议、开会 | ~/.openclaw/plugin-skills/wecom-meeting/SKILL.md |
| wecom-schedule | 日程、创建日程、查看日程、日程提醒 | ~/.openclaw/plugin-skills/wecom-schedule/SKILL.md |
| wecom-send-template-card | 模板卡片、发送卡片消息、交互卡片 | ~/.openclaw/plugin-skills/wecom-send-template-card/SKILL.md |
| ecc-documentation-lookup | 文档查询、API参考、React文档、Next.js文档、Prisma文档、框架文档 | ~/.openclaw/skills/ecc-documentation-lookup/SKILL.md |
| strategic-compact | 上下文压缩、手动compact、context管理、token优化 | ~/.openclaw/skills/strategic-compact/SKILL.md |
| blogwatcher | 博客监控、RSS订阅、博客更新 | D:/Kiro/testopenclaw/node-v22.22.1-win-x64/node_modules/openclaw/skills/blogwatcher/SKILL.md |
| gemini | Gemini模型、Google AI、Gemini API | D:/Kiro/testopenclaw/node-v22.22.1-win-x64/node_modules/openclaw/skills/gemini/SKILL.md |
| goplaces | 地点搜索、Google Maps、附近地点、地图 | D:/Kiro/testopenclaw/node-v22.22.1-win-x64/node_modules/openclaw/skills/goplaces/SKILL.md |
| notion | Notion文档、Notion页面、Notion数据库 | D:/Kiro/testopenclaw/node-v22.22.1-win-x64/node_modules/openclaw/skills/notion/SKILL.md |
| openai-whisper-api | 语音转文字、音频转录、Whisper、ASR | D:/Kiro/testopenclaw/node-v22.22.1-win-x64/node_modules/openclaw/skills/openai-whisper-api/SKILL.md |
| voice-call | 语音通话、打电话、Voice Call | D:/Kiro/testopenclaw/node-v22.22.1-win-x64/node_modules/openclaw/skills/voice-call/SKILL.md |

---

## 与其他层的关系

- **核心层**（`<available_skills>`）：自动加载，自动匹配，无需查本文件
- **扩展层**（本文件）：不加载到 prompt，但 agent 主动扫描触发词发现
- **库存层**（`skill-library-index.md`）：不自动扫描，仅在用户明确要求或 agent 搜索时使用

## 升降级规则

| 动作 | 条件 | 操作 |
|------|------|------|
| 核心→扩展 | skill 使用频率低（月均<3次）但仍有价值 | `skills.entries.<name>.enabled: false` + 加入本文件 |
| 扩展→库存 | skill 长期未命中（季度0次）或依赖不可用 | 从本文件移除 + 加入 `skill-library-index.md` |
| 库存→删除 | skill 完全不可用（依赖缺失/功能重复/无法运行） | 删除 skill 目录 |
| 扩展→核心 | skill 使用频率升高（周均>2次） | 从本文件移除 + `skills.entries` 删除该条目或设 `enabled: true` |
| 库存→扩展 | 用户重新需要该 skill 且依赖可用 | 从 `skill-library-index.md` 移到本文件 + 验证可用性 |
