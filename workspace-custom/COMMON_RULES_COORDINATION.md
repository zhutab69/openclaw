# 共用规则·协作层（所有 agent 注入）

> 本文件定义 `[COORDINATED]` 模式下子 agent 的行为规范。
> 通过 hook 自动注入，无需在各 agent AGENTS.md 中重复。

## [COORDINATED] 模式执行协议

当 task 以 `[COORDINATED]` 开头时，进入被协调模式：

### 🔴 Action Type 强制规则（防止"只分析不执行"）

shared-context 的 Input 段必须包含 `actionType` 字段：

| actionType | 含义 | 子agent必须做什么 | 合格Output标准 |
|------------|------|-------------------|----------------|
| `execute` | 执行型 | 产生副作用（修改文件/运行命令/写入数据） | Output 包含具体变更清单（改了哪些文件/执行了什么命令/退出码） |
| `analyze` | 分析型 | 产出报告/方案，不修改任何东西 | Output 包含分析结论 |
| `verify` | 验证型 | 运行检查命令，报告通过/失败 | Output 包含验证结果（pass/fail + 证据） |

**铁律：**
- `actionType: execute` 时，Output 中**必须有至少一个副作用证据**（文件路径+diff摘要/命令+退出码）。纯文字分析不算完成。
- 如果子agent认为无法执行（缺少信息/风险过高），必须在 Output 的「异常/阻塞」中明确说明原因，**不得用分析报告替代执行**。
- 主管在 Input 段未写 actionType 时，默认为 `execute`（偏向行动）。

### 行为规范
1. **全程静默** — 不发任何通知、不回复摘要
2. **读取 shared-context** — task 中指定的 `workspace/.shared-context/<taskId>.md` 是唯一输入源
3. **识别 actionType** — 据此决定行为模式（执行/分析/验证）
4. **并行工具调用** — 单轮中尽可能并行发出多个无依赖的工具调用
5. **写完 Output 立即结束** — 禁止再做任何操作（不更新 Progress、不回复摘要、不发通知）
6. **验证分工：**
   - 代码类任务：自验语法/退出码后写 Output
   - 纯文本产出：不验证，在 Output 段标注「验证: 待主管」
   - 系统操作：自验退出码后写 Output

### 禁止项（尾轮禁令）
- ❌ 写完 Output 后更新 Progress
- ❌ 写完 Output 后回复摘要
- ❌ 写完 Output 后发 message 通知
- ❌ 每多一轮 ≈ +25-40s，严重影响整体效率

### Output 段格式

**execute 型（必须有副作用证据）：**
```markdown
## Output（子agent写，主管只读）
- 执行动作：修改了 sites.json 中 12 个信源的 enabled 字段
- 变更清单：
  - sites.json: 第 45/78/102/... 行 enabled: false → true
  - 运行 `node verify-reachability.cjs --targets changed` 退出码 0
- 结果文件：workspace/.shared-context/<taskId>-result.json
- 异常/阻塞：无
```

**analyze 型：**
```markdown
## Output（子agent写，主管只读）
- 关键结论：一句话总结
- 结果文件：path（分析报告）
- 异常/阻塞：（如有）
验证: 待主管
```

**verify 型：**
```markdown
## Output（子agent写，主管只读）
- 验证结果：PASS/FAIL
- 证据：命令+输出摘要（∕20行）
- 异常/阻塞：（如有）
```

### 非 [COORDINATED] 模式
不含 `[COORDINATED]` 时为独立发起者，按各自 AGENTS.md 的完整 Step 1-3 执行。
