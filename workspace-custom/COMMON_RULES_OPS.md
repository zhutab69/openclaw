# 共用规则·运维层（main + coder 注入）

## 🔴 exec 就在 PowerShell 里，禁止再套 `powershell -Command`（2026-08-07 实证纠正）

**根因（实验确证，推翻旧「PowerShell 吞变量」说法）：** exec 的默认 shell 本身就是 PowerShell（Runtime `shell=powershell`）。命令直接写即在 PS 中执行。
之前反复炸变量的真凶是**画蛇添足包一层** `powershell -ExecutionPolicy Bypass -NoProfile -Command "..."` → 变成 **PS 套 PS**：外层 PS 先解析双引号字符串，把 `$x`/`$p`（外层未定义）展开成空，残缺字符串再塞给内层 → 报「= 无法识别」「if 缺少条件」「字符串缺少终止符」。

**实证对比：**
| 写法 | 结果 |
|------|------|
| `powershell -Command "$x='HELLO'; Write-Output $x"` | ❌ `$x` 变空 |
| 直接 `$x = 'DIRECT_OK'; Write-Output "value is $x"` | ✅ 正常 |
| 直接 `$p = Get-Process...; if ($p) {...}`（多语句+变量+if） | ✅ 正常 |

**铁律（新）：**
1. **默认直接写 PowerShell 命令**，不要包 `powershell -Command "..."`，也不需要 `-ExecutionPolicy Bypass -NoProfile`（那是给外层套壳用的，直接跑不涉及策略）。含 `$var`、`if`、多语句、`;` 分隔——直接写全部正常。
2. **只有两种情况才落脚本文件**（`.ps1`/`.cjs` 用 `-File`/`node 文件`）：(a) 几十行的复杂逻辑；(b) 命令里必须内嵌大段含引号/`$`/中文的字符串且易转义错乱。轻量单命令不必写文件。
3. 仍然成立的独立陷阱（与套壳无关）：`&&`/`||` 在 PS5.1 不支持 → 用 `;`；`cd /d` → 用 exec 的 `workdir`；写 JSON 用 Node 或无 BOM UTF8。

**教训：** 旧规则「一律写脚本文件」是对错误根因的过度补偿——真解法是别套壳，不是每次 write 文件。
通知文案：禁占位符N/M/X、`[COORDINATED]`、Reply Tags `[[reply_to_current]]`，发前自检
子Agent记忆：只存领域知识，不存流程规则，不维护每日日记
浏览器：任务结束关闭所有标签页
文件存储：临时→agent workspace｜最终交付→`C:\Users\zhuyulin\.openclaw\workspace\`｜图片→`~/.openclaw/`
通知规则：一个任务链只有一个通知者，[COORDINATED]→静默，<2min不发，>5min必发，进度→wecom，交付→并行双通道
自主执行🔴：按 R1/R2/R3 风险分级决定是否确认（见 COMMON_RULES_CORE.md），默认偏向直接执行，只在 R3 等确认
R2过程通知🔴：完成中风险动作（改代码/配置/cron、装依赖、重启Gateway、跑写入脚本）后立即发 wecom 通知，含「已执行/变更/验证/回滚」四项；不事前请示，事后告知
Gateway重启：多个修改攒一起重启，能热生效的不重启
国情(SHOULD)：优先国内生态，默认中文、北京时间

## Cron 补跑守卫规则 🔴（所有周期性 agentTurn cron 必加）

**背景：** Gateway 重启后会补跑（catch-up）错过的任务。个人电脑每天关机/休眠是常态，因此每次开机都会触发一批补跑，多个重型 agentTurn job 同时抢单一 LLM 网关 → 竞争资源 → 超时失败。OpenClaw 的补跑参数（missedJobStaggerMs / maxMissedJobsPerRestart / 延迟2min）全部硬编码，config 无法覆盖，也没有 coalesce 合并机制。因此必须在**每个 job 的 payload 里**自带守卫（cron isolated session 用 lightContext，不加载 workspace 规则，只有 payload 文本运行时生效）。

**🔴 关键：必须区分「补跑」与「手动执行」。** 源码证实手动执行（cron run）和补跑传给 agent 的 payload 完全相同，无区分标记。唯一可靠判别器是 **Gateway uptime**——补跑只发生在重启后约 2 分钟内，手动执行时 uptime 必然较大。守卫用 `workspace\cron-uptime.ps1`（输出 `UPTIME_MIN=<分钟>`，失败返回 999 偏向执行）探测，仅当「时间差 > grace」且「UPTIME_MIN < 3」两条件同时成立才跳过。这样手动执行永不被误杀。

**🔴 铁律：创建任何新的周期性 agentTurn cron job 时，payload.message 开头必须加「补跑守卫」段。**

**守卫模板 v2（放在 payload.message 最开头，`<...>` 按 job 替换）：**
```
【补跑守卫｜MUST 最先执行，先于一切其他步骤】
本任务的计划调度：<用中文描述 + cron 表达式>。
背景：Gateway 重启后会补跑（catch-up）错过的任务。补跑只发生在 Gateway 刚重启后约 2 分钟内；手动执行（cron run）与正常触发不在此列，不得跳过。
判断步骤：
(1) 时间差：用系统注入的当前时间，算出"最近一个应触发的计划时刻"，求差值（分钟）。若差值 <= <graceMin> 分钟 → 正常触发，直接执行下方原任务，无需下一步。
(2) 仅当差值 > <graceMin> 分钟时，执行 exec: powershell -ExecutionPolicy Bypass -NoProfile -File "C:\Users\zhuyulin\.openclaw\workspace\cron-uptime.ps1"，读取输出中的 UPTIME_MIN 数字（Gateway 已运行分钟数）。
    - 若 UPTIME_MIN < 3：判定为补跑，立即跳过——不执行下方任何步骤、不发任何通知，仅回复一行"补跑跳过：Gateway 重启补跑，距计划触发已超过<graceMin>分钟，等待下一周期"后结束。
    - 若 UPTIME_MIN >= 3（含探测失败返回 999）：这是手动执行或稳定运行中的触发，正常执行下方原任务。
====== 以下为原任务 ======
<原 payload 内容>
```

**grace（宽限分钟）取值指南：**

| 任务周期 | 建议 grace | 理由 |
|----------|-----------|------|
| 高频（≤30min，如保活） | 10 | 补跑一个错过的心跳无意义 |
| 整点/每小时（如北森审批） | 15 | 晚到的审批仍有价值窗口很短 |
| 数小时（如租房 4h 采集） | 30 | 补跑一次错过的采集价值低 |
| 每日（如内存整理） | 60 | 当天补上有意义，隔天无意义 |
| 每月（如技能分析） | 120 | 容忍度最高 |

**例外（不加守卫）：**
- **巡检/监控型 job**（如"每3分钟检查XX是否完成"）：本就需要高频运行且自带完成即自删逻辑，加守卫反而破坏。
- **一次性 job**（`deleteAfterRun:true` 且 `schedule.kind:"at"`）：无补跑概念。

**判断口诀：** 「补跑这一次有没有价值？」有→不加或大 grace；没有→加守卫。

**已落地（2026-07-13）：** 北森(15)/租房(30)/保活(10)/auto-dream(60)/技能月度(120) 共 5 个 job 已加 v2 守卫（uptime 判别，手动执行不误杀）。判别脚本 `workspace/cron-uptime.ps1`。备份 `cron/jobs.json.bak-guardv2-*`。

## 长任务 Cron 巡检规则 🔴

预计执行时间 >5 分钟的后台任务（下载、编译、部署、子 agent 等），必须设置 cron 巡检 job：

**触发条件：** exec background=true 且预估完成时间 >5min

**标准流程：**
1. 启动后台任务
2. 创建 cron job（`schedule.kind: "every"`, `everyMs: 适当间隔`）
3. cron payload 描述：检查什么文件/进程/条件 → 判断是否完成 → 完成则通知+自删
4. 任务完成后 cron 自动清理（payload 中包含 `删除本 cron job` 指令）

**间隔选择：**

| 预估耗时 | 巡检间隔 | 示例 |
|----------|----------|------|
| 5-10min | 2-3min | npm install、小文件下载 |
| 10-30min | 3-5min | 大文件下载、构建 |
| 30min+ | 5-10min | 超大下载、长时编译 |

**Cron payload 模板：**
```
检查 [具体条件]。
完成条件：[文件大小/进程退出/输出文件存在]。
如果完成：1) 执行 [后续步骤] 2) 通过 wecom 通知用户结果 3) 删除本 cron job。
如果未完成：报告当前进度（百分比/已完成量）后结束，等待下次巡检。
如果失败/超时：通知用户失败原因，删除本 cron job。
```

**禁止：** 在主 session 中轮询后台任务状态（每次轮询消耗 LLM 调用，且 compaction 时丢失上下文）。
**收益：** 主 session 释放去做其他事，cron 独立巡检，完成后推送通知无缝衔接。

## Exec 输出裁剪规则 🔴（tokenjuice 思想）

子agent（及主管）执行 exec 后，回传到 context 的输出必须裁剪：

| 场景 | 裁剪策略 |
|------|----------|
| 命令成功 + 输出≤20行 | 原样保留 |
| 命令成功 + 输出>20行 | 保留前5行 + `... (省略N行)` + 后10行 |
| 命令失败 | 保留完整 stderr + 最后20行 stdout |
| 纯状态确认（git status/npm install等） | 只报一句话总结（如「安装成功，0 warnings」） |
| JSON/结构化输出 | 提取关键字段，不贴原始大 JSON |

**实施方式：**
- 不需要安装额外工具
- agent 在引用 exec 结果时自行裁剪（在思考中处理完整输出，回复/写入时只保留精华）
- 写入 .shared-context 的 Output 段同样遵守此规则

**禁止：** 把 `npm install` 的完整依赖树、`git log` 的完整历史、`ls -R` 的完整目录树原封不动塞进对话或文件。

## 并行工具调用规则 🔴（减少 LLM 轮次）

单轮 LLM 响应中应尽可能并行发出多个无依赖的 tool call，而非一个一个串行发出：

| 场景 | 正确做法 | 错误做法 |
|------|----------|----------|
| 需要同时读 2 个文件 | 一轮发出 2 个 read | 轮1 read A，轮2 read B |
| 写完文件 + 写进度 | 一轮发出 edit + write | 轮1 edit，轮2 write |
| read A 然后基于 A 内容 edit B | **不可并行**（有依赖） | 并行发出导致 edit 基于空内容 |

**判断规则：** 后一个工具调用的输入不依赖前一个的输出 → 可并行；否则必须串行。
**目标：** 典型 5 轮任务压缩到 2-3 轮。
