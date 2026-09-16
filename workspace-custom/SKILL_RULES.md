# 技能路由映射(易误判场景)

> 由 hook 注入所有 agent。补充 CORE 层的通用规则,聚焦高频误判。

## 三层架构扫描规则

每次收到用户消息时，按以下顺序匹配 skill：
1. **核心层**：扫描 `<available_skills>` 的 description 和触发词
2. **扩展层**：扫描 `SKILL_EXTENSIONS.md` 的触发词索引
3. **库存层**：仅在用户明确要求或 1+2 均无匹配时，查阅 `skill-library-index.md`

命中扩展层时：read 对应 SKILL.md 后执行，标注：📖 调用技能：<name>（扩展层）

## 路由决策表

| 任务特征 | 正确技能 | 常见误判 | 判断依据 |
|----------|----------|----------|----------|
| 企业微信文档 URL `doc.weixin.qq.com` | wecom-doc | wecom-msg | URL 含 doc.weixin |
| 发消息/看聊天记录 | wecom-msg | wecom-doc | 动词：发、看消息 |
| 智能表格增删改查 | wecom-smartsheet | wecom-doc | 提及“智能表格”+“记录/字段” |
| 创建/查看待办 | wecom-todo | wecom-msg | 动词：待办、提醒、分派 |
| 创建/查询会议 | wecom-meeting | wecom-todo | 动词：开会、预约会议 |
| 查通讯录成员 | wecom-contact | wecom-msg | 动词：找人、查联系方式 |
| 浏览器多步操作/登录 | browser-automation | 直接用 browser 工具 | 多步骤/需恢复/登录检查 |
| 社交平台数据/下载 | opencli | browser-automation | 平台名：bilibili/知乎/小红书等 |
| 生成报告/多源汇总 | report-generation-tool | info-agent 自行搜集 | 动词：生成报告、汇总 |
| 天气查询 | weather | web_fetch | 动词：天气、温度、下雨 |
| 二维码/图片显示 | qrcode-viewer | browser | 动词：显示二维码、打开图片 |
| Canvas/HTML展示 | canvas | browser | 动词：展示、可视化、仪表盘 |
| **修改/优化 SKILL.md 文件** | **skill-creator（至少参考质量标准）** | 直接动手改 | **产出物是 SKILL.md 文件修改** |
| **开始优化前评估质量** | **skill-analysis-workflow** | 跳过评估直接改** | **动词：分析、评估、审查 skill** |

## 不触发规则(工具直用-健康)

以下技能通过 wecom_mcp 工具直接使用,无需 read SKILL.md 也是健康状态:
- wecom-contact(通过 wecom_mcp call contact)
- wecom-meeting(通过 wecom_mcp call meeting)
- wecom-todo(通过 wecom_mcp call todo)
- wecom-smartsheet(通过 wecom_mcp call smartsheet)

## 标注纪律补充

- 重新执行/重跑流程时若再次 read 了 SKILL.md,仍需标注(不因"之前标过"而跳过)
- 同一会话内触发多个 skill 时,每个都单独标注
- 子 agent 同样遵守此规则

## 多候选决策

当多个技能可能匹配时:
1. 看动词(做什么)而非名词(涉及什么系统)
2. 选最具体的(wecom-smartsheet > wecom-doc > wecom-msg)
3. 不确定时标注:`📖 调用技能:<主选>(<理由>)|备选:<次选>`
