# COMMON_RULES_EXTENDED.md - 扩展协作规则

> 长任务（>5分钟、多步骤、[COORDINATED]）时加载此文件。
> 短任务（简单查询、单步操作）不需要加载。

---

## 🔄 智能协作机制 🔴 MUST

### 进度文件协议

`[COORDINATED]` 任务开始前创建进度文件：

```
路径：C:\Users\zhuyulin\.openclaw\workspace\.progress\<taskId>.json
taskId = agent名-时间戳（如 coder-1779787642）
```

格式：
```json
{
  "taskId": "coder-1779787642",
  "agent": "coder-agent",
  "task": "任务简述",
  "status": "running|completed|failed",
  "startedAt": "ISO时间",
  "updatedAt": "ISO时间",
  "steps": [{ "name": "步骤名", "status": "done|running|pending|failed", "output": "路径或结果" }],
  "intermediateFiles": ["已产出文件路径"],
  "error": "失败原因（如有）"
}
```

### 中间结果持久化 🔴 MUST

- 每阶段产出**立即写入文件**，不依赖最终返回
- 文件命名：`workspace/<taskId>-step<N>-<描述>.json`
- 最终结果写入 task 指定的输出路径

### 自愈重试 🔴 MUST

| 故障类型 | 策略 |
|----------|------|
| 工具超时 | 等 5s 重试 1 次 |
| web_fetch 失败 | 换 URL 重试 |
| exec 失败 | 修正后重试 1 次 |
| 文件读写失败 | 修正路径重试 |

上限：同一步骤最多重试 2 次。仍失败则更新进度文件 status="failed"，输出中间结果，正常退出。

### 超时自保 🔴 MUST

- 运行超过**总时限 80%** 仍未完成 → 立即停止、输出已有结果、正常退出
- 绝不允许卡死不输出

### 任务原子化 🟡 SHOULD

复杂任务自行拆分为原子步骤，每步独立可验证，完成后更新进度文件。

### 断点恢复 🟡 SHOULD

启动时检查是否存在同名进度文件（status="failed"）：
- 有效 intermediateFiles → 从断点继续
- 不存在 → 从头开始

---

## 🖼️ 图片传递 🟡 SHOULD

子 agent 无法自动接收图片。主管需通过 `attachments` 参数以 base64 传递。
