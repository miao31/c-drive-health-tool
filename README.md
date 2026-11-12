# C 盘健康工具

**c-drive-health-tool** ｜ 面向 Windows 的 C 盘体检与清理 PowerShell 脚本

先用**只读扫描**把空间占用、风险分级、Top 大文件查清楚，再由你**逐项确认**是否清理 —— 脚本自己不会静默删除任何东西。

单文件、零第三方依赖、无需安装。放在任意目录，用管理员 PowerShell 运行即可。

---

## 目录

- [项目简介](#项目简介)
- [项目沿革](#项目沿革)
- [核心特性](#核心特性)
- [工作原理](#工作原理)
- [环境要求](#环境要求)
- [使用方法](#使用方法)
- [输出文件](#输出文件)
- [目录结构](#目录结构)
- [安全设计](#安全设计)
- [定时自动体检](#定时自动体检)
- [已知限制](#已知限制)
- [免责声明](#免责声明)

---

## 项目简介

Windows 的 C 盘会被各种缓存、日志、临时文件慢慢吃掉，但市面上的"一键清理"工具普遍有两个问题：**你不清楚它删了什么**，以及**它可能误删系统组件**（WinSxS、Windows\Installer 被第三方工具清坏的案例非常多，后果往往是只能重装系统）。

本工具采取相反的思路：

1. **先看清楚** —— 一次只读扫描，把 33 个目录项的占用、文件数、风险等级、Top 大文件全部列出来，生成可存档的报告；
2. **再决定** —— 想清理时显式加 `-Clean`，脚本对每个可清理项单独询问，只有你按 `Y` 的项才会被删除。

设计取向：**默认只读、删除必须显式开启、每一步都要人确认**。宁可麻烦一点，也不让脚本自己拿主意。

---

## 项目沿革

本项目从一个自用脚本起步。公开历史始于合并版，更早的形态依据仓库内可核对的材料说明，**不补造提交**。

| 阶段 | 时间 | 形态 | 关键变化 | 依据 |
|---|---|---|---|---|
| 起点 | 首条提交之前 | 两份独立脚本 | `c_drive_readonly_scan.ps1` 负责分层只读扫描，`clean-interactive.ps1` 负责交互式清理 | 主脚本头注释 |
| 合并 | 2026-09-10 | 单一入口 `c_drive_tool.ps1` | 一次运行先只读体检，再由人决定是否进入逐项确认清理；33 项固化清单、三级风险分级、三层护栏在此版本已成型 | 首条提交及其脚本、README |
| 产品化起步 | 2026-11-12 · 1.1.0 | 单文件工具 + 可选配置 | 阶段 A：版本与运行标识、可选配置、报告归档、追加式状态契约；阶段 B：`-AssessSystemChannels` 官方通道只读评估 | 第二条提交与[版本记录](#版本记录) |

一以贯之的设计主线：**默认只读、删除必须显式开启、每一步都要人确认**。后续阶段继续在守住这条底线的前提下扩大可释放空间，见[定位与演进方向](#定位与演进方向)。

> 合并前的两份脚本未单独入库，因此这里不提供更细的时间线，也不回填历史提交。后续每完成并验证一个阶段，提交一次、推送一次，逐步公开演进过程。

---

## 核心特性

| 特性 | 说明 |
|---|---|
| **33 项目录清单** | 每项带独立的风险等级与处理方式，不是简单的"列个目录大小" |
| **三级风险分类** | 低风险可清理 / 需人工确认 / 已保护禁止操作 |
| **分层扫描 + 超时降级** | 单个目录超时即降级，只记总大小并标注"明细不足"，不会卡死整个脚本 |
| **三层安全护栏** | 清单固化、运行时路径守卫、降级目录禁止清理（详见[安全设计](#安全设计)）|
| **交互式清理** | 逐项 `Y/N/L/Q`，回车即跳过，`L` 可先看内容再决定 |
| **零依赖** | 只用 .NET Framework 与 PowerShell 内置能力，不需要装任何模块 |
| **可存档** | 报告、结构化 JSON、状态文件、清理日志全部落盘，便于回溯 |

### 风险分级说明

| 等级 | 前缀 | 数量 | 含义 | 脚本行为 |
|---|---|---|---|---|
| 低风险 | `L01`–`L16` | 16 | 缓存、日志、临时文件，删除可重建 | 其中 **14 项可脚本清理**，逐项确认 |
| 需确认 | `C01`–`C10` | 10 | 个人文件区、IDE 缓存、AI 模型、聊天记录等 | **只统计、只提示，绝不删除** |
| 已保护 | `P01`–`P07` | 7 | 系统核心目录、浏览器凭据、密钥、页面文件等 | **只统计、只提示，绝不删除** |

> 低风险里有 2 项不做自动清理：`L06 Chrome 缓存`（需在浏览器内清除）与 `L15 WER 错误报告`（手动处理）。

---

## 工作原理

脚本分两个阶段，**阶段 2 只在带 `-Clean` 时才会进入**。

### 阶段 1：只读扫描

- 遍历 33 项目录清单，用内嵌 C# 迭代枚举（`Stack` 显式栈，避免深目录递归爆栈），**跳过重解析点**防止符号链接导致重复计数或死循环；
- 普通项单目录超时 20 秒，受保护项放宽到 60 秒；超时即降级，标注"明细不足（超时降级）"；
- 对可操作项额外取 Top-N 子目录（默认 10）与 Top-N 大文件（默认 20），含最后修改时间；
- 输出 Markdown 报告 + 结构化 JSON + 状态文件。

### 阶段 2：交互式清理

带 `-Clean` 时，扫描完成后按**占用从大到小**遍历 14 个可清理项，每项：

1. 显示当前占用与文件数；
2. 询问 `[Y]执行 / [N]跳过(默认) / [L]列出内容 / [Q]退出`；
3. 按 `Y` 才执行删除，并统计实际释放量。

清理前后各测一次目录大小，差值即真实释放量；失败的文件单独计数并在结尾提示。

### 安全护栏

见[安全设计](#安全设计)一节。

---

## 环境要求

- **操作系统**：Windows 10 / 11（已在 Windows 11 build 26200 上验证）
- **PowerShell**：Windows PowerShell 5.1 或 PowerShell 7+
- **权限**：
  - 只读扫描：普通权限即可运行（受保护目录可能测不全）
  - 清理模式：**建议管理员**，否则需管理员权限的 6 个项会被自动跳过
- **无需**安装任何模块或第三方工具

---

## 使用方法

打开 PowerShell，切到脚本所在目录（或直接用完整路径调用）：

```powershell
cd "路径\cdrive-report"
```

### 四种常用调用

```powershell
# 1. 只读扫描（默认）—— 只出报告，零删除
.\c_drive_tool.ps1

# 2. 交互式清理 —— 扫描后逐项确认，只有按 Y 的项会删
.\c_drive_tool.ps1 -Clean

# 3. 演练清理 —— 走完整个流程但不实际删除，用来预览
.\c_drive_tool.ps1 -Clean -DryRun

# 4. 汇总下载/桌面的安装包 —— 只列出，不删除
.\c_drive_tool.ps1 -ListPersonalFiles
```

### 参数说明

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `-Clean` | 开关 | 关 | 进入清理模式。不加则纯只读 |
| `-DryRun` | 开关 | 关 | 演练：走流程但不真删（仅在清理模式生效）|
| `-ListPersonalFiles` | 开关 | 关 | 列出下载/桌面 ≥5 MB 的安装包及手动处理指引 |
| `-Archive` | 开关 | 关 | 只读扫描结束时另存 `weekly-report-<yyyyMMdd>.md` |
| `-AssessSystemChannels` | 开关 | 关 | 只读评估系统官方通道，报告追加第 11 节、状态文件追加评估标记 |
| `-SystemClean` | 开关 | 关 | 进入系统官方通道确认执行；**独立于 `-Clean`**，每条命令单独询问 |
| `-OutDir` | 字符串 | 脚本所在目录 | 报告输出目录 |
| `-Config` | 字符串 | 空（不加载） | 可选配置文件的路径，见「版本、配置与演进」 |
| `-DirTimeoutSec` | 整数 | `20` | 单个目录扫描超时（秒），超时即降级 |
| `-TopFiles` | 整数 | `20` | 每项最多列出的大文件数 |
| `-TopSubdirs` | 整数 | `10` | 每项最多列出的子目录数 |

### 交互按键

清理模式下每一项会停下来等你输入：

| 按键 | 含义 |
|---|---|
| `Y` | 执行这一项的删除 |
| `N` 或**直接回车** | 跳过这一项（默认行为，所以乱按回车是安全的）|
| `L` | 先列出该目录内最大的文件/子目录，再重新询问 |
| `Q` | 立即停止，后续所有项不再询问 |

### 典型场景

```powershell
# 第一次用：先演练一遍看会删什么
.\c_drive_tool.ps1 -Clean -DryRun

# 确认没问题后正式清理（管理员）
.\c_drive_tool.ps1 -Clean

# 平时只想看看空间，随时裸跑
.\c_drive_tool.ps1

# 想自定义报告目录与扫描深度
.\c_drive_tool.ps1 -OutDir D:\reports -DirTimeoutSec 30 -TopFiles 10
```

---

## 输出文件

| 文件 | 产生时机 | 是否覆盖 | 说明 |
|---|---|---|---|
| `c_drive_analysis_report.md` | 每次运行 | **是**（每次覆盖）| Markdown 分析报告，10 个小节；带 `-AssessSystemChannels` 时追加第 11 节 |
| `c_drive_scan_<时间戳>.json` | 每次运行 | 否 | 结构化扫描数据，含每项大小/文件数/Top 文件 |
| `c_drive_scan_status_<时间戳>.txt` | 每次运行 | 否 | 机器可读的状态摘要（供自动化判断）|
| `cleanup-log-<时间戳>.txt` | 仅清理模式 | 否 | 逐项确认与释放量日志，含 `DONE/SKIP` 记录 |

状态文件字段：

```
SCAN_DONE
REPORT_MD=<报告路径>
SCAN_JSON=<JSON 路径>
OUT_DIR=<输出目录>
ITEMS=<总项数>  LOW=<低风险>  CONFIRM=<需确认>  PROTECTED=<已保护>
LOW_SUM_GB=<低风险可释放合计>
HEALTH=<健康状态>
REPORT_OK=<报告是否正常生成>
```

健康状态阈值：可用空间 **<10 GB 为紧急**、**<15 GB 为偏低**、否则正常。

---

## 目录结构

```
.
├── README.md                          # 本文件
├── .gitignore                         # 排除生成物与个人数据
└── cdrive-report/
    ├── c_drive_tool.ps1               # 主脚本（唯一入口）
    ├── c_drive_analysis_report.md     # 生成的报告（已忽略 → 每次覆盖）
    ├── c_drive_scan_<时间戳>.json      # 结构化数据（已忽略 → 含本机路径）
    ├── c_drive_scan_status_<时间戳>.txt# 状态摘要（已忽略）
    ├── cleanup-log-<时间戳>.txt        # 清理日志（已忽略）
    └── weekly-report-<日期>.md         # 每周体检存档（已忽略）
```

> **重要**：`cdrive-report/` 下的报告与日志包含**本机用户名、完整文件路径、已安装软件与文件名清单**。这些文件默认已在 `.gitignore` 中排除，请勿为了"展示效果"而手动提交。

---

## 安全设计

三层相互独立的护栏，任一层都能拦住误删：

### 第一层：目录清单固化

- 只扫描清单里写死的 33 个路径，不接受外部传入的任意路径；
- 受保护项（`P01`–`P07`）**只统计总大小，不展开明细**；
- 其中密钥凭据项（`.ssh` / `.gnupg` / `.aws`）标记 `noscan`，**连 `Test-Path` 都不执行**，完全不触碰磁盘。

### 第二层：运行时路径守卫（Guard-Path）

清理前对每个目标路径做前缀匹配检查，命中以下根目录直接拒绝执行：

```
Windows\WinSxS            Windows\Installer        Windows\System32\config
C:\Program Files          C:\Program Files (x86)   C:\ProgramData
Windows\Fonts             Windows\Microsoft.NET    Windows\SystemApps
Windows\SysWOW64          Windows\servicing        Windows\SystemResources
C:\Boot                   C:\Recovery              C:\EFI
C:\System Volume Information                       C:\Windows\CSC
```

仅放行两个白名单例外：`System32\LogFiles`、`System32\SleepStudy`。

### 第三层：降级目录禁止清理

扫描时超时降级的项（标注"明细不足"）在清理阶段会被**直接拒绝**，因为它们的大小与内容都不完整，不适合据此删除。

### 其他约束

- 清理模式对每个需管理员的项单独检查权限，达不到就跳过而非报错中断；
- 清理不碰个人文件，`-ListPersonalFiles` 也只列出安装包并给出手动处理指引；
- 删除失败的文件会被计数，在结尾以 `[注意] N 个对象未能删除` 提示，不会静默失败。

---

## 定时自动体检

仓库之外，可以配一个每周自动体检任务（例如 Windows 任务计划程序，或任意能定时执行命令的调度器）：

```powershell
# 每周执行一次只读扫描，并把报告另存为带日期的存档
& "路径\cdrive-report\c_drive_tool.ps1"
Copy-Item "路径\cdrive-report\c_drive_analysis_report.md" `
          "路径\cdrive-report\weekly-report-$(Get-Date -Format yyyyMMdd).md" -Force
```

要点：

- **绝对不要给定时任务加 `-Clean`** —— 无人值守时没人按键，加了也不会删，但会白白阻塞等待输入；
- 之后读取最新的 `c_drive_scan_status_*.txt` 即可拿到可用空间、健康状态与可释放量，据此决定是否人工介入。

---

## 版本、配置与演进

### 版本记录

| 版本 | 内容 |
|---|---|
| 1.1.0 | 阶段 A：版本与运行标识、可选配置、报告归档、追加式状态契约；阶段 B：`-AssessSystemChannels` 系统官方通道只读评估（报告第 11 节） |
| 1.2.0 | 阶段 C1：`-SystemClean` 独立开关、硬编码命令白名单、逐条确认、执行前后可用空间实测、`-DryRun` 零执行、结果追加到状态文件 |
| 1.3.0 | 阶段 C2：权限预检前置（避免确认后才被拒）、`740 需要提升权限` 单独判定、结果回写 JSON 与报告第 12 节 |
| 1.4.0 | 阶段 C3：真实执行后修正判定——`5 E_ACCESSDENIED` 单独判定、负差值不判 `ok`、失败保留命令输出尾部 |
| 1.5.0 | 阶段 C4：`RUN_MODE` 区分系统通道执行与演练；补充两次真实执行的差值对照与噪声阈值边界 |

> 1.1.0 之前的提交未使用版本号。从本版本起按阶段记录变更。
> 本版本包含阶段 A 与阶段 B 两个阶段的合并改动；分阶段提交从下一阶段起执行。
> 后续约定：每完成并验证一个阶段，提交一次 commit、推送一次，并打一个版本 tag。

当前版本 `1.5.0`（脚本内 `$ScriptVersion`）。输出 JSON 与状态文件带 `toolVersion`、`schemaVersion`、`runId`、`configSource`、`runMode`、`scanSeconds`。

**状态文件是追加式契约**：`SCAN_DONE`、`HEALTH`、`LOW_SUM_GB`、`REPORT_OK` 等既有字段不变，只新增以下字段，现有自动化读取方式无需改动：

```
TOOL_VERSION=<版本>   SCHEMA_VERSION=<整数>   RUN_ID=<时间戳>
CONFIG_SOURCE=<来源>  RUN_MODE=<readonly|clean|clean-dryrun|system-clean|system-clean-dryrun>   SCAN_SECONDS=<秒>
SYSTEM_CLEAN_COUNT=<白名单条数>   SYSTEM_CLEAN_DRYRUN=<0|1>
SYSTEM_CLEAN_EXECUTED=<实际执行条数>
SYSTEM_CLEAN_PRECHECK=admin=<0|1>;exe=<0|1>;canRun=<0|1>
SYSTEM_CLEAN_ITEM=<id>:<结果>:exit=<退出码>:deltaGB=<差值>
```

`SYSTEM_CLEAN_*` 只在带 `-SystemClean` 时追加，其余字段一字不改。结果同时写入 JSON 的 `systemClean` / `systemCleanPrecheck` 字段，以及报告第 12 节。

结果取值：`dryrun`（演练零执行）、`blocked`（权限预检未通过）、`skipped`（用户跳过）、`elevation-required`（退出码 740）、`access-denied`（退出码 5，组件存储事务未提交）、`failed`（其它非零退出码）、`space-decreased`（命令成功但可用空间反而减少）、`unknown`（差值落在噪声带，不判定释放量）、`ok`。

**权限预检**在询问之前执行：只判断当前是否管理员、DISM 是否存在，不运行任何命令。普通权限下直接标 `blocked` 并说明原因，不会先让你按 `Y` 再拒绝。本机实测：非管理员运行 DISM 返回 `740 需要提升权限`，0.1 秒即失败。

**真实执行实测（2026-11-12）**：管理员会话中 `Dism /StartComponentCleanup` 返回退出码 `5`（`0x80070005 E_ACCESSDENIED`），CBS 日志显示删除 `WinSxS\Catalogs\*.cat` 时 `STATUS_CANNOT_DELETE`、事务提交失败；会话收尾为 `Reboot required: no, RepairNeeded: no`。三个独立测源（CIM / DriveInfo / fsutil）一致记录可用空间**减少 937.6 MB**，工具自报 `deltaGB=-0.918`，与独立差值偏差 2.4 MB（来自两次 `Round(x/1GB,3)` 舍入）。

这条实测说明两件事：

- 命令失败时可用空间可能**不增反减**（清理过程产生临时文件与日志），所以退出码 0 也不能把负差值判成 `ok`；
- 判定「是否释放更多空间」不能只看差值，必须同时看退出码。`access-denied` 与 `space-decreased` 都会保留命令输出尾部写入日志，便于定位。

**第二次真实执行（2026-11-12）**：同样在管理员权限下执行，`SYSTEM_CLEAN_PRECHECK=admin=1;exe=1;canRun=1`、`EXECUTED=1`，退出码仍为 `5`、`result=access-denied`。三个独立测源一致记录可用空间**增加 54.3 MB**，工具自报 `deltaGB=0.053`，与独立差值偏差小于 0.03 MB。CBS 日志显示为 `Failed to FinalizeEx using worker session`、`StartComponentCleanupEx(hr:0x80070005)`。

两次失败的空间变化方向相反（-937.6 MB 与 +54.3 MB），幅度都超过 `0.05 GB` 阈值，退出码却都是 5。所以差值必须在退出码为 0 之后才参与判定：即使差值为正且越过噪声带，命令失败时也不能当作释放量。当前判定顺序为 `740 → 5 → 其它非 0 → 负差值 → 噪声 → ok`，已满足这一点。

> 噪声阈值 `0.05 GB` 尚未经成功清理案例校准：两次执行退出码都非零，差值分支没有走到。第二次的 +54.3 MB 是失败命令产生的空间波动，不是释放量。保持该值直至有成功样本。

**E_ACCESSDENIED 是什么、怎么重试**：这是 Windows 组件存储的事务提交失败，**不是本工具权限不足**（会话已是管理员，`SYSTEM_CLEAN_PRECHECK=admin=1;exe=1;canRun=1`）。本机后续只读检查：目标 `.cat` 文件仍存在、所有者 `NT SERVICE\TrustedInstaller`、Administrators 仅 `ReadAndExecute`；`SessionsPending` 有残留会话键但 `Exclusive=0`；`RebootPending=false`、`pending.xml` 不存在、无并发 DISM/TiWorker 进程；系统为 26H2 build 26300.9974，卷 `Healthy`。

重试前建议先做这几项只读检查：

- 是否有并发 `Dism` / `TiWorker` 进程；有就等它结束再重试；
- `CBS.log` 是否还在写入；`SessionsPending` / `RebootPending` / `pending.xml` 的状态；
- 上一次失败的 `access-denied` 是否仍记在状态文件里。

若以上都干净，可在管理员会话中重试。重试**不会**自动修改 ACL、不会强删 catalog 文件、不会重启系统——遇到 `access-denied` 仍会如实记录并停止。重试成功的判据是 `result=ok` 且独立测源差值为正；只有那一次才能用来校准 `0.05 GB` 阈值。

### 可选配置

`cdrive-report/tool.config.psd1` 是配置模板，**默认不加载**，需显式传入：

```powershell
.\c_drive_tool.ps1 -Config .\tool.config.psd1
```

只含 5 个非安全关键项：`DirTimeoutSec`、`TopFiles`、`TopSubdirs`、`ArchiveOnScan`、`AssessSystemChannelsOnScan`。配置文件缺失、解析失败、数值越界时自动回退内置默认值，并在 `CONFIG_SOURCE` 标出原因。`$catalog`、`Guard-Path` 与删除逻辑**永不从配置读取**——配置化不等于把安全边界交出去。

### 报告归档

`-Archive`（或配置 `ArchiveOnScan = $true`）在只读扫描结束时把报告另存为 `weekly-report-<yyyyMMdd>.md`。文件名与既有每周体检任务一致，重复执行幂等；原先写在调度器里的 `Copy-Item` 胶水逻辑由此收进工具自身。归档失败只提示、不中断扫描。

### 系统官方通道评估（只读）

`-AssessSystemChannels`（或配置 `AssessSystemChannelsOnScan = $true`）在只读扫描结束后，把**系统官方通道**汇总成报告第 11 节：组件存储清理、旧版驱动包、更新下载缓存、系统日志、回收站、旧系统残留、休眠/页面文件、存储感知，逐条给出对应清单项、当前占用、官方命令或入口、可逆性、权限与计划阶段。

严格边界：

- **不执行** `Dism` / `cleanmgr` / `powercfg` / `vssadmin` 等任何外部命令，不修改系统设置，不代配置 `cleanmgr /sageset`；
- 复用本次扫描结果，不重复枚举目录；合并统计项（如 `P01`）**不拆分到单个通道**，占用标 `unknown`；
- **占用 ≠ 可回收量**，本工具不估算、不伪造释放量；
- 状态文件只在开关开启时追加 `SYSTEM_CHANNEL_COUNT` / `SYSTEM_CHANNEL_ASSESSED`，其余字段一字不改。

### 系统官方通道确认执行（`-SystemClean`）

`-SystemClean` 是**独立于 `-Clean`** 的开关，只处理系统官方通道，不碰 33 项目录清单。当前白名单硬编码 1 条，不接受外部输入：

```
Dism.exe /Online /Cleanup-Image /StartComponentCleanup
```

执行链路：

1. **权限预检**（只读判断，不执行命令）：管理员身份、DISM 是否存在；不通过即标 `blocked`，不再询问；
2. 逐条显示命令与说明，单独询问 `Y/N/L/Q`（回车默认跳过）；
3. 执行前后各测一次 C 盘可用空间，差值即实测释放量；
4. 退出码 `740` → `elevation-required`；`5` → `access-denied`；其它非零 → `failed`；差值 ≤ -0.05 GB → `space-decreased`；|差值| < 0.05 GB → `unknown`，**不判定释放量**；否则 `ok`；
5. 结果追加到状态文件、JSON 与报告第 12 节，并写入 `cleanup-log-<时间戳>.txt`。

严格边界：

- **不进白名单**：`/ResetBase`、删除 `Windows.old`、`powercfg /h off`、`vssadmin delete shadows`、任何第三方工具；
- `-SystemClean -DryRun` **零执行**：不询问、不启动任何外部进程，只验证链路并写状态字段；
- 白名单不接受配置文件或命令行传入；`-SystemClean` 也不会写进配置文件，避免无人值守触发；
- 两层安全边界不变：默认只读、逐项确认、33 项分级与 `Guard-Path` 一律不动。

> 真实执行（`Dism` 会修改组件存储且不可撤销）需要**管理员权限**并由你逐条按 `Y`。本工具的演练模式可用于先确认链路，实际执行请自行判断时机。

### 定位与演进方向

定位：**在保证安全边界的基础上，实现释放最多空间**。安全是底线，不是天花板。

底线有两层，任何阶段不得削弱：

1. **交互层** —— 默认只读、`-Clean` 才进入清理、逐项 `Y/N/L/Q` 确认、回车默认跳过、`-DryRun` 演练。
2. **目录层** —— 33 项固化清单与三级风险分级不放松，`protected` / `confirm` 不转可清理，Guard-Path 与降级禁止清理保持不变。

因此空间增量优先从**系统官方通道**取得（DISM 组件存储清理、cleanmgr、存储感知），由用户逐项确认后执行，而不是靠放宽目录分级。路线：规范化地基 ✅ → 官方通道只读评估 ✅（`-AssessSystemChannels`）→ 官方通道确认执行 ✅（`-SystemClean` 链路，C1）→ 覆盖与只读报告增强 → 模块化 → 独立软件 → 商用预留。图形界面与降低确认摩擦在守住两层底线的前提下可以评估，**不预先排除**。

---

## 已知限制

1. **扫描耗时随磁盘状态变化**。本机实测：管理员下约 54 秒，普通权限约 86 秒。目录特别大的机器可能更久。
2. **大小为逻辑大小**。硬链接（如 `DriverStore`）会被重复累加，因此本工具报出的数字可能大于资源管理器的"实际占用"，两者口径不同，均属正常。
3. **`DriverStore` 通常不可回收**。若每个硬件只有一个驱动版本，就不存在旧版冗余，`cleanmgr` 也会显示 0 字节。强行删除会导致显卡失效。
4. **`WinSxS` 需要 DISM 处理**，本工具不做，也不建议用第三方工具碰它。
5. **报告会被覆盖**。`c_drive_analysis_report.md` 每次运行都重写；需要存档请按上一节的方式另存带日期的副本。
6. **仅面向 Windows**，依赖 .NET Framework 与 WMI（`Win32_LogicalDisk`）。

---

## 免责声明

本工具按"现状"提供，不附带任何担保。

脚本已内置三层安全护栏，且默认不执行任何删除，但**任何磁盘清理都存在风险**。请务必：

- 首次使用先跑 `-Clean -DryRun` 预览；
- 正式清理时逐项读清楚再按 `Y`；
- 重要数据保持独立备份。

因使用本工具造成的任何数据丢失或系统损坏，作者不承担责任。

---

## 许可

本项目采用 [MIT 许可证](LICENSE)，Copyright (c) 2026 miao31。

可自由使用、修改、分发，只需保留版权声明与许可证原文。
