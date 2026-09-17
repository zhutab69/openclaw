# workspace-custom

> ⚠️⚠️⚠️ **只读镜像，禁止在此目录改代码！** ⚠️⚠️⚠️
>
> 本目录是 `C:\Users\zhuyulin\.openclaw\workspace\` 的**单向发布镜像**（live → mirror）。
> **真源是 live 工作区，不是这里。** 8899 面板等服务加载的是 live 目录的文件，不是本镜像。
>
> 在本目录里改任何白名单内文件（如 `dashboard-server.cjs` / `bgtasks-manifest.json` / `*.ps1`）**都不会生效** ——
> 服务读的是 live 目录，改这里等于没改。
>
> **正确做法：** 一律改 `C:\Users\zhuyulin\.openclaw\workspace\` 下的源文件，再跑 `sync-workspace-custom.py --apply` 同步过来。
>
> sync 脚本带反向漂移保护：镜像比 live 新时报 `REVERSE DRIFT`，并把这些文件列入 `HELD BACK`
> **跳过复制**，所以误改不会被 live 的旧版静默冲掉，退出码为 1。
> 确认镜像里的改动不要了，再用 `--apply --force` 覆盖。
>
> （2026-09-17 教训：曾误在本镜像编辑 dashboard-server.cjs 做「配置驱动重构」，改动全落镜像、8899 从未加载，白忙一场。）

---

`C:\Users\zhuyulin\.openclaw\workspace\` 里**可公开的基础设施文件**的版本化镜像。

## 为什么是镜像,不直接跟踪原目录

原目录 **2649 文件 / 607MB**,其中:

| 内容 | 体积 | 处理 |
|---|---|---|
| `node_modules/` | 114MB | 不跟踪 |
| `overseas-source-backup/` | 85MB | 不跟踪 |
| `news-*.json` 等日期快照 | ~40MB | 不跟踪 |
| 个人记忆 / 身份 / 通道标识 | — | **刻意排除**,见下 |
| 基础设施脚本与规则 | 153KB | **本目录** |

## 刻意排除的内容(不要"顺手"加进来)

本仓库的 GitHub 远端是**公开的**(已实测:匿名访问 `github.com/zhutab69/openclaw` 返回 HTTP 200)。
因此以下文件即使属于核心定制,也**不入库**:

| 文件 | 原因 |
|---|---|
| `MEMORY.md` / `MEMORY-blocks.md` / `MEMORY.archive.md` | 个人与业务记忆 |
| `MEMORY-synonyms.json` | 由记忆内容派生 |
| `USER.md` / `IDENTITY.md` / `SOUL.md` / `AGENTS.md` | 用户画像与 agent 人设 |
| `config.json` / `channels.json` / `bindings.json` | 含 `botId`、`allowFrom` 企微用户标识 |
| `skill-health-report.json` / `.md` | 内部审计数据 |
| `_*.ps1` / `_*.cjs` / `test-*` | 一次性探查脚本(142 个) |

这些文件目前仍只有 `C:\Users\zhuyulin\.openclaw\backups\` 下的时间戳备份,**没有版本历史**。
若将来需要纳管,应先把 GitHub 仓库改为 private,或另建仅连本地 GitLab 的独立仓。

## 同步方式

镜像不会自动更新。改完 workspace 里的文件后,在仓库根目录执行:

```powershell
python sync-workspace-custom.py                  # 只报告差异,不写入
python sync-workspace-custom.py --apply          # 写入镜像
python sync-workspace-custom.py --apply --force  # 连反向漂移的文件一起覆盖(慎用)
```

白名单写在 `sync-workspace-custom.py` 的 `WHITELIST` 里,**刻意用显式列表而非通配符** ——
否则下一个落进 workspace 的数据文件或记忆文件会被静默带入公开仓。

两道保护,命中都以非零码退出:

| 分类 | 触发条件 | `--apply` 行为 |
|---|---|---|
| `BLOCKED` | 文件含 `refreshToken`/`clientSecret`/真实 ARN/带密码 URL 等 | 拒绝复制 |
| `HELD BACK` | 镜像 mtime 比 live 新 1 秒以上(反向漂移) | 跳过复制,保住镜像里的改动 |

反向漂移之所以要**跳过**而不只是警告:光警告没用,复制在同一轮循环里已经执行完了,
等看到警告时改动早就没了。`--force` 是明确知道镜像改动无价值时的逃生阀。

> 遗留加固项:`dashboard-server.cjs` 和 `kiro-heartbeat.ps1` 内嵌的网关 key 是
> trae-gateway 上游文档里的默认值(本仓根 `README.md` 已载明),镜像它不构成新增暴露;
> 但它同时是本机网关**实际在用**的 `PROXY_API_KEY`(`.env` 未覆盖)。网关仅绑
> `127.0.0.1`,风险有限,轮换时需同步改上述两个消费方,否则会 401。

## 恢复

镜像文件与 workspace 里的原文件**内容逐字节一致**(二进制复制,保持 UTF-8 无 BOM)。
恢复时直接覆盖回去即可:

```powershell
Copy-Item workspace-custom\dashboard-server.cjs "$env:USERPROFILE\.openclaw\workspace\" -Force
```
