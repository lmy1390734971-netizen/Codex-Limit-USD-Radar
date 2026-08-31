# Token Rader

[![Windows tests](https://github.com/lmy1390734971-netizen/Codex-Limit-USD-Radar/actions/workflows/test.yml/badge.svg)](https://github.com/lmy1390734971-netizen/Codex-Limit-USD-Radar/actions/workflows/test.yml)

Token Rader 是一个只在本机运行的 Windows 桌面程序。它读取 Codex 已写入本机的 JSONL 会话日志，统计任务、模型调用、指定时间段或指定项目的 token 用量，并按 OpenAI 官方 API 标准处理价格计算美元等价成本。

![Token Rader 合成数据预览](artifacts/token-rader-preview.png)

## 项目解决的问题

Codex 日志包含输入、缓存输入、输出、模型和额度百分比等信息，但原始 JSONL 不方便直接查看，也不能直接回答以下问题：

- 某次 Codex 工作消耗了多少 token？
- 缓存输入和未缓存输入分别是多少？
- 同一时间段内多个对话、多个模型一共消耗多少？
- 某个项目累计使用了多少 token 和 API 等价美元？
- 5 小时和周额度使用了多少，能否根据百分比变化反推美元等价额度？

Token Rader 在本机解析这些日志，不要求 API Key，也不会上传提示词、回复正文或工具输出。

## 主要功能

- 显示使用模型、缓存输入、未缓存输入、输出、合计和缓存命中率。
- 提供“整次任务”“最后一次调用”和“所选项目累计”三种统计范围。
- 支持“开始计算—结束计算”，统计指定时间段内全部项目和全部 Codex 会话的增量；开始和结束时分别冻结日志偏移与额度快照，结束后新增日志不改变结果。
- 同一会话切换模型时按每次调用对应的模型分别计价。
- 识别任务树中的父任务、子任务和重复累计记录；仅在祖先—后代链路内去重，保留 token 与时间戳恰好相同的独立兄弟子代理调用。
- 按每次调用判断 272K 长上下文价格倍率。
- 显示 5 小时和周额度百分比、重置时间及满足一致性条件时的 API 等价美元额度；Pro 5x 的百分比已经按 5x 计划归一化，不再额外乘 5。
- 每 5 分钟自动刷新，并保留“立即刷新”和“查看结果”。
- 独立显示最近 7 个连续滚动 24 小时窗口的总 token 与 API 等价美元，并按模型列出缓存输入、未缓存输入、输出、总 token 和美元明细；默认窗口为当前时刻向前 24 小时，不按自然日切分。汇总结果存入项目内 SQLite，不将七天数据常驻内存。
- 仅从本机 JSONL 判别 function/custom、shell、MCP、搜索、computer、code interpreter、图片生成等工具调用，以及输入图片和电脑截图；新日志随增量索引立即识别，旧日志由用户一次性回填最近 7 天。
- 时间段准备、查看、结束冻结和结算均在后台线程执行；“查看结果”会立即保留上一次结果并显示正在更新，首次查看保留零值占位。区间记录由 C# 直接流式聚合为模型/长上下文桶，不在 UI 线程枚举日志，也不把全部行装入 PowerShell。
- 内置 C# + SQLite 两层持久化索引：轻量文件游标长期保留，可清理的 token/模型/额度记录单独存放；普通刷新只处理文件变化队列和新增字节，开始、查看及结束测量会额外执行一次不读取正文的轻量文件游标核对，防止异步文件通知延迟造成漏算。
- 多个 Token Rader 窗口共享同一索引时，项目内无内容锁文件会串行化写入；SQLite 使用 WAL 和等待超时，读取仍可并行，避免两个窗口同时更新导致游标丢失。
- 可选择最近 1、7、30、90 天或全部历史，默认最近 1 天（当前时刻向前滚动 24 小时）；可手动清理30天以前的索引缓存，也可在需要排查索引时点“完整重建”，两者都不修改 Codex 原始日志。
- 所有计算在本机完成，不修改 Codex 日志。

## 软件和硬件环境

### 软件环境

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10/11；GitHub Actions 使用 `windows-latest` |
| PowerShell | Windows PowerShell 5.1，或 Windows 版 PowerShell 7 |
| 图形框架 | WPF（`PresentationFramework`、`PresentationCore`、`WindowsBase`） |
| 构建启动器 | Windows 自带的 .NET Framework C# 编译器；只有重新构建 EXE 时需要 |
| Git | 仅克隆仓库时需要 |
| Python/Node.js | 不需要 |
| OpenAI API Key | 不需要 |

启动器优先使用 PATH 中的 `powershell.exe`，不可用时尝试 `pwsh.exe`。Codex 数据目录优先读取环境变量 `CODEX_HOME`，否则使用当前用户的 `~/.codex`。

### 硬件环境

- 不需要 GPU、CUDA 或专用加速卡。
- 普通 Windows x64 电脑即可运行；其他 Windows 架构尚未验证。
- CPU、内存和读取时间取决于 JSONL 日志数量与大小。
- 程序只读扫描日志；不会重写日志，也不会为日志创建副本。

## 安装方法

### 从 GitHub 克隆

以下命令可直接复制到 PowerShell：

```powershell
git clone https://github.com/lmy1390734971-netizen/Codex-Limit-USD-Radar.git
Set-Location .\Codex-Limit-USD-Radar
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\TokenRader.ps1
```

本项目没有 `requirements.txt`，不需要执行 `pip install`。

### 直接运行

也可以下载完整项目目录，然后使用任一方式启动：

1. 双击 `TokenRader.exe`；
2. 双击 `Start-TokenRader.cmd`；
3. 在项目目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\TokenRader.ps1
```

仓库中的启动器没有商业代码签名。若 Windows 显示 SmartScreen 提示，可以运行 PowerShell 脚本，或审查启动器源码后自行构建：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
```

## 最小运行示例

1. 确保 Codex 至少完成过一次模型调用，使 `~/.codex/sessions` 中存在含 `token_count` 的 JSONL 日志。
2. 启动 Token Rader。
3. 在左侧选择一个会话。
4. 选择“最后一次调用”即可查看模型、token 和 API 等价美元。
5. 若要测量一段新工作，点击“开始计算”后先等待状态从“准备中”变为“计算中”，再启动 Codex；完成后点击“结束计算”。

首次启动会在项目的 `data/private/index/` 中后台建立本地索引，因此历史日志很多时第一次准备可能明显较慢，但窗口仍可响应。“开始计算”始终可以点击；若索引尚未完成，界面进入“准备中”，状态栏会显示建库阶段、文件数量和已用时间，完成后自动开始计时。“准备中”时可点击“取消准备”立即解锁界面。已有索引同步最多等待 60 秒，起止位置冻结最多等待 30 秒，实时查看最多等待 15 秒，最终冻结结算最多等待 60 秒；首次建库不使用短总超时，但连续 5 分钟没有进度会失败并允许重试。普通刷新只读取新增/修改内容；冻结测量边界时会枚举文件元数据并比较游标，但不会重读未变化日志正文。界面默认显示最近 1 天，即当前时刻向前滚动 24 小时，可在顶部切换历史范围。

“已显示本次测量的最新结果；测量仍在继续”表示结果已经完成并显示，只是计时尚未结束。界面分别显示“测量时长”和“本次结果计算耗时”，两者不是同一概念。真正计算时会显示后台阶段和已处理记录数，3 秒后提示数据量较大；实时查看 15 秒仍未完成会先取消底层查询并等待工作线程退出，再允许重试，测量和上一次结果不会失效。最终结算保留 60 秒保护，失败时保留冻结结束边界，可再次点击“查看结果”重试。重复的同类查看请求会合并；若自动刷新正在执行，手动查看会随后补一次带冻结额度快照的更新。5 分钟自动刷新只更新 token 与成本时会保留最近一次已校准的美金额度，不会用空额度快照将其清除。

启动命令与完整克隆示例见上方“安装方法”，不需要额外依赖安装步骤。

## 输入与输出

### 输入

默认输入目录：

```text
%CODEX_HOME%\sessions               # 设置了 CODEX_HOME 时
%USERPROFILE%\.codex\sessions       # 默认位置
```

程序主要读取以下 JSONL 记录：

| 记录/字段 | 用途 |
|---|---|
| `session_meta.payload.cwd` | 识别项目目录 |
| `session_meta.payload.parent_thread_id`、`forked_from_id` | 构建任务树并处理继承历史 |
| `turn_context.payload.model` | 识别每次调用使用的模型 |
| `token_count.info.total_token_usage` | 显示会话累计 token |
| `token_count.info.last_token_usage` | 逐调用、逐模型计价 |
| `cached_input_tokens` | 计算缓存输入和缓存命中率 |
| `rate_limits.primary`、`rate_limits.secondary` | 识别 5 小时与周额度窗口 |
| `window_minutes`、`used_percent` | 读取窗口长度和已用百分比 |
| `reset_at`、`resets_at`、`resets_in_seconds` | 规范化绝对或相对重置时间；支持 Unix 秒、Unix 毫秒和 ISO 时间表示 |

可选账号标签来自 `~/.codex/.cockpit_codex_auth.json`。程序不会读取包含访问令牌的 `~/.codex/auth.json`。

### 输出

输出只显示在桌面界面中，不会默认写入结果文件：

- 模型或模型数量；
- 缓存输入、未缓存输入、输出、合计；
- 缓存命中率；
- 未缓存输入、缓存输入、输出和总美元等价成本；
- 统计时间、唯一调用数、去重数量；
- 5 小时与周额度百分比、重置时间和满足一致性条件时的 API 等价美元估算；
- 当前内置官方 API 价格表。

## 算法流程

```text
发现 JSONL 日志
    ↓
启动时后台核对一次文件目录，之后由变化监视器把新增/修改路径加入队列
    ↓
SQLite 保存轻量文件游标；只把变化文件的新增完整 JSONL 行写入可查询记录层
    ↓
点击“开始计算”：进入准备中，同步变化队列并冻结索引 Revision、起始字节偏移和额度快照；随后才开始计时
    ↓
读取 session_meta，建立会话、项目和父子任务关系；按顺序读取 turn_context 与 token_count
    ↓
将 last_token_usage 绑定到当时使用的模型；以 total_token_usage 的累计变化识别真实新调用，剔除状态刷新产生的重复快照、基线继承记录和任务树中的共享重复记录
    ↓
计算缓存/未缓存输入、输出、总 token 和缓存命中率
    ↓
按模型价格和长上下文倍率逐调用计价
    ↓
点击“结束计算”：后台同步变化队列并一次冻结结束 Revision、偏移和同边界额度快照
    ↓
校验计划、窗口长度、重置标识和账号连续性；通过后汇总时间段结果和额度估算，否则清除旧估算
```

核心 token 关系：

```text
缓存输入 = cached_input_tokens
未缓存输入 = input_tokens - cached_input_tokens
输出 = output_tokens
合计 = input_tokens + output_tokens
缓存命中率 = cached_input_tokens / input_tokens
```

`output_tokens` 已包含推理输出明细，因此不会再次加上 `reasoning_output_tokens`。

成本公式：

```text
成本 = 未缓存输入 / unitTokens × 输入价
     + 缓存输入 / unitTokens × 缓存输入价
     + 输出 / unitTokens × 输出价
```

`unitTokens` 默认是 1,000,000。超过模型价格表中 `longContextThreshold` 的单次调用会应用相应输入和输出倍率。

## 数据集与数据预处理

### 数据集如何获得

本项目不提供、下载或上传真实用户日志。数据有两种来源：

1. **真实只读数据**：Codex 在正常使用过程中自动生成的本机 `sessions/*.jsonl`；
2. **合成测试数据**：`tests/Run-Tests.ps1` 在系统临时目录动态生成，测试完成后删除，不含真实账号、提示词或回复。

运行普通回归测试不需要真实 Codex 数据。只有 `-Live` 测试要求本机已经存在 Codex 会话日志。

### 数据预处理方法

- 只解析 `session_meta`、`turn_context` 和 `token_count`，忽略提示词与回复正文。
- 将缓存输入限制在 `[0, input_tokens]` 范围内，避免异常日志产生负数。
- 将项目路径正规化并按不区分大小写的完整路径分组。
- 时间段测量在开始时记录每个日志的字节偏移，在结束时只处理各文件截至结束偏移的新增内容；结束后写入的日志不会进入已冻结结果。
- 额度快照与 token 成本使用相同的起止边界；5 小时和周窗口独立保存观察时间、窗口长度、重置时间和来源文件。
- 解析 `window_minutes` 时，240–360 分钟归为 5 小时窗口，9000–11520 分钟归为周窗口；其他窗口不用于周额度反推。
- 绝对重置时间支持 Unix 秒、Unix 毫秒和 ISO 时间；`resets_in_seconds` 按日志事件时间换算为绝对时间。
- 所有日志文件首次写入项目内的持久化索引；后续普通同步使用 `FileSystemWatcher` 变化队列，只重读新增或发生变化文件在 `parsed_offset` 之后的完整行。开始、查看和结束测量会由 C# 连续比较轻量目录游标，处理变化后必须再获得一次无变化目录快照；暂时不可读的日志会重新入队，未同步完整时不会冻结结果。
- 索引 Revision 只在内容或游标实际变化时单调递增；区间查询由每个文件的 `StartOffsets/EndOffsets` 直接限定，不再用全目录哈希判断变化。C# 使用 `SQLiteDataReader` 只读取必要字段，并在编译态完成任务树去重、继承过滤、模型与长上下文分桶；旧格式中缺少来源路径或偏移的记录不会进入冻结区间。
- 通过任务根 ID、事件时间、模型、累计 token 和单次 token 组成指纹识别共享记录，再结合父子关系仅去除祖先—后代之间的复制事件；不同时间的调用以及恰好同时间同 token 的独立兄弟子代理调用均会保留。父任务关系晚于孙任务到达时，会事务性回填文件游标和 token 记录的规范任务根。
- 新建分支匹配父任务实际存在的事件，剔除测量前继承历史，避免仅按累计量比较造成漏计。
- 未知模型价格标记为“无法估算”，不会按 `$0` 处理。

## 科研与实验复现信息

本项目是确定性桌面日志分析软件，不是机器学习训练项目。为便于科研归档，相关字段说明如下：

| 项目 | 配置 |
|---|---|
| 论文名称 | 无对应论文 |
| 算法类型 | 确定性 JSONL 解析、任务树去重、逐调用价格汇总 |
| 训练过程 | 不适用 |
| 训练/验证/测试划分 | 不适用；没有训练数据集 |
| 随机种子 | 不适用；算法和测试不使用随机采样 |
| 数据预处理 | 字段筛选、路径正规化、区间基线、任务树指纹去重 |
| 主要参数 | `unitTokens=1,000,000`、自动刷新 5 分钟、日志行上限 4 MB、长上下文阈值由 `pricing.json` 指定 |
| 评价指标 | token 字段解析正确性、价格公式误差、去重事件数、模型归属、额度反推结果、XAML 控件完整性 |
| 数值容差 | 不同断言按量纲使用 `1e-7` 至 `1e-4` 的指定误差 |
| 预期结果 | 回归测试输出 `ALL_TESTS_PASSED` |

## 如何复现实验结果

### 1. 运行确定性回归测试

在已经克隆的项目目录中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Run-Tests.ps1
```

预期输出：

```text
ALL_TESTS_PASSED
```

测试覆盖：

- token、模型、账号计划和额度窗口解析；
- Unix 秒、Unix 毫秒、ISO 时间和 `resets_in_seconds` 重置时间解析；
- 缓存与未缓存输入计算；
- Terra、Luna 等官方价格回归；
- 272K 长上下文倍率；
- 同一会话多模型逐调用计价；
- 开始/结束时间段增量、起止偏移与额度快照同边界冻结；
- 结束后追加日志不改变已冻结结果，新测量开始时清除旧额度估算；
- 超过原有限制数量的日志文件、缺失额度记录时向前寻找有效快照；
- 跨重置、窗口类型或计划变化时拒绝额度反推；
- 父子任务继承过滤和重复记录去重；
- C# 流式区间聚合、取消令牌、相同 token 不同时间保留、多模型/长上下文/未知模型与旧算法计价一致；
- 项目识别和项目累计；
- WPF XAML 控件加载。

### 2. 运行可选性能回归

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Run-Tests.ps1 -Performance
```

该测试在系统临时目录生成 2,000 和 5,000 个合成日志，每档只修改 2 或 4 个文件，验证热启动准备、冻结、区间查询、变化文件数量、新增字节读取量及结束后追加不改变结果；还会在内存 SQLite 中生成 108,010 条有效记录和 1,885,000 条无来源偏移的旧格式干扰记录，验证 25,815 条聚合不超过 1 秒、108,010 条不超过 3 秒。首次冷建库耗时受磁盘和杀毒软件影响，程序会在后台执行；验收重点是建库后的交互路径和 UI 不阻塞。预期最终仍输出 `ALL_TESTS_PASSED`。

若只需单独验证编译态聚合器：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AggregatePerformanceTests.ps1 -IncludeLegacyInterference
```

### 3. 验证 Windows PowerShell 5.1 / PowerShell 7 UI 回调

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-UiCallbackTests.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-UiCallbackTests.ps1
```

该测试只使用合成后台任务，验证 `Starting → Measuring`、开始后不执行无意义的零区间查询、超时后等待底层线程停止再解锁、异步取消和迟到回调丢弃，不读取本机 Codex 日志。预期输出 `UI_CALLBACK_TESTS_PASSED`。

### 4. 运行本机日志只读检查

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Run-Tests.ps1 -Live
```

本机有可解析日志时，预期输出类似：

```text
LIVE_OK model=gpt-5.6-luna price=True
ALL_TESTS_PASSED
```

模型名称取决于本机最新日志。如果没有日志，`-Live` 检查会明确失败；这不影响普通合成回归测试。

### 3. 重新构建启动器

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
```

预期生成项目根目录下的 `TokenRader.exe`。

### 4. 重新生成合成预览图（可选）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Render-Preview.ps1
```

预期生成 `artifacts/token-rader-preview.png`。预览使用合成账号和 token 数据。

## 使用说明

### 统计范围

- **整次任务**：显示最新 `total_token_usage`；根会话金额按每条 `last_token_usage` 的实际模型和长上下文规则计价。
- **最后一次调用**：只统计最新 `last_token_usage`。
- **所选项目累计**：根据 `session_meta.cwd` 汇总同一项目的全部本机会话。

顶部“历史显示范围”只过滤会话列表与项目累计的候选日志，默认最近 1 天；这里的“一天”是当前时刻向前滚动 24 小时，不是自然日。测量进行中也可切换该范围，不会改变开始/结束时间段的计量边界。“立即刷新结果”在后台同步新增/修改日志；“清理30天前索引”只删除旧 token、模型、额度和调用缓存，保留路径、会话关系、长度、修改时间与 `parsed_offset` 轻量游标；“完整重建”才会重建两层索引。开始/结束指定时间段始终覆盖测量起止偏移间的新记录，不受历史范围和项目选择影响。

被清理的旧会话如果之后重新打开并写入新内容，程序从保留的 `parsed_offset` 继续解析，只导入追加内容，不重扫旧文件。清理和完整重建均只操作 `data/private/index/index.db`，不会删除或改写 `~/.codex/sessions`。

派生/子任务的累计 token 可能包含父任务历史。为避免重复，程序保留 token 原值显示，但不会直接把派生任务的累计值换算成美元。

### 周期用量

主界面的“周期用量”卡片默认显示当前时刻向前 24 小时的全部项目总 token 和 API 等价美元。明细表按模型分别显示缓存输入、未缓存输入、输出、总 token 和 API 等价美元，末行显示所有模型总计。下拉菜单还可选择“24–48 小时前”直至“6–7 天前”；每项都是连续 24 小时区间，不是本地自然日。主结果的 API 等价美元与 5 小时/周额度卡片排列在“周期用量”之前。

每次查询会先通过轻量文件游标核对并导入最新日志字节，再由 C# 流式读取 SQLite 时间范围，因此切换下拉选项不依赖此前是否点击过“立即刷新”。测量进行中的5分钟自动预览或手动“查看结果”完成后，也会异步更新该卡片。计算沿用多模型价格、长上下文倍率和任务血缘去重规则；每次只把当前选中的紧凑汇总返回界面，窗口总计和模型明细分别以 `usage_history`、`usage_history_models` 表保存在项目的 `data/private/index/index.db`。相同时间边界、索引 Revision 和包含模型别名的价格缓存键会复用磁盘结果；索引、价格或别名变化时重新计算。每次成功结束一次指定时间段测量后，程序会在后台更新当前选择并自动删除窗口结束时间早于 7 天前的历史汇总，不删除 Codex 原始日志。

### 图片与工具用量

“图片与工具用量”卡片与上方“周期用量”下拉框使用同一时间边界，显示工具调用总数、完成/失败数、输入图片、生成图片和 computer 截图，并按工具名称汇总。识别依据是本地 JSONL 中可确认的结构化调用类型；[OpenAI Responses 参考](https://developers.openai.com/api/reference/cli/resources/beta/subresources/responses)也将 function、custom、shell、MCP、computer、file search、code interpreter、image generation 和 input image 区分为不同项目类型。

界面将两类数据明确分开：`API 等价美元（仅可观察 Token）：$X`，以及`未单独计价：工具 M 次 · 输入图片 N 张 · 生成图片 G 张`。后者只报告次数，不暗示费用为零，也不混入 Token 美元估算。

性能与保留策略固定为：

- **新日志**：增量解析新增字节时立即识别，不重扫历史文件；
- **旧日志**：用户点击一次“回填最近7天工具记录”，后台只扫描最近 7 天有更新的日志；完成标记保存在 SQLite，默认不能重复执行；
- **保存内容**：`tool_records` 只保存时间、会话/任务根、模型、工具类型、工具名称、状态、图片数量、源文件和字节偏移等元数据；不保存参数、命令、提示词、URL、图片、工具输出或文件内容；
- **清理**：每次成功结束指定时间段测量时，与 24 小时缓存一起删除 7 天以前的工具元数据。

工具调用可能按调用次数、图片尺寸/质量或其他指标收费，[官方价格页](https://developers.openai.com/api/docs/pricing)也明确区分 token 价格与工具专项价格。本机日志没有统一、稳定且足够完整的计费参数，因此工具/图片次数不会加入现有 API 等价美元总额；程序不会为凑金额而猜测价格。

### 指定时间段

1. 工作开始前点击“开始计算”；界面先显示“准备中”，后台同步变化队列并冻结起始 Revision、偏移和额度快照；
2. 等状态变为“计算中”后再启动 Codex；准备阶段产生的调用不属于本次测量；
3. 正常使用 Codex；
4. 点击“查看结果”会立即保留上一次结果并在后台更新截至当前 Revision 的临时增量，同时读取该冻结结束点的额度快照，但不会结束测量；
5. 工作完成后点击“结束计算”；程序进入“冻结中/结算中”，后台一次冻结结束 Revision、偏移、token、成本和额度快照。

指定时间段始终统计该账号本机日志中的全部项目和全部 Codex 会话，不受项目下拉框影响。结束后新写入的日志不会改变结果；开始新的测量会立即清除上一次的时间段结果和额度估算。计量期间应保持 Token Rader 窗口运行。

### 5 小时与周额度

程序从日志的 `rate_limits` 中读取 `used_percent`：

- `window_minutes` 在 240–360：5 小时额度；
- `window_minutes` 在 9000–11520：周额度；其他窗口（例如月度窗口）不参与周额度反推。

重置时间可来自 `reset_at`、`resets_at` 或 `resets_in_seconds`，并支持 Unix 秒、Unix 毫秒和 ISO 时间。程序会将它们规范化为绝对时间，并分别保存 5 小时和周窗口的观察时间、窗口长度、重置时间和来源文件。

只有在起止快照同时存在、计划类型和窗口类型一致、重置标识一致且没有跨重置时，才会在同一重置周期内按百分比增量计算：

```text
反推总 API 等价美元 = 本次 API 等价成本 / ((结束已用百分比 - 开始已用百分比) / 100)
预计已用美元 = 反推总额 × 当前已用百分比
预计剩余美元 = 反推总额 × 当前剩余百分比
```

有效反推会直接显示“美金额度≈$X · 从 Y% 开始 · 已用≈$A · 剩余≈$B”，其中 Y 是本次测量冻结的起始用量百分比。这里的“美元”是按官方 API token 价格换算的等价金额，不是 ChatGPT/Codex 套餐实际账单，也不是官方公布的固定周美元额度。Pro 5x 的百分比已经相对于 5x 计划额度计算，不能再把结果乘以 5。百分比不变、窗口重置、计划/窗口/重置标识不一致、未知模型价格或起止边界不完整时显示“尚无有效反推结果”，并清除该窗口的旧估算。

Codex、ChatGPT Work、Excel 和 Workspace Agents 可能共享 agentic usage，因此其他客户端、Fast mode 或图片/工具操作同时产生的消耗，可能没有对应的本机 token 记录并影响反推精度。

## 官方价格与计价边界

`pricing.json` 保存标准 API 处理价格，最近核对日期为 **2026-08-28**：

| 模型 | 输入 | 缓存输入 | 输出 |
|---|---:|---:|---:|
| GPT-5.6 Sol | $4.00 | $0.40 | $20.00 |
| GPT-5.6 Terra | $2.00 | $0.20 | $12.00 |
| GPT-5.6 Luna | $0.20 | $0.02 | $1.20 |

单位均为每百万 token。GPT-5.6 Sol 当前为官方促销价，官方说明至少持续至 **2026-11-21**；到期后应重新核验，程序不会擅自恢复旧价。完整模型表及来源 URL 见 `pricing.json`。

主要官方来源：

- [GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol)
- [GPT-5.6 Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra)
- [GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna)
- [GPT-5.5](https://developers.openai.com/api/docs/models/gpt-5.5)
- [GPT-5.4](https://developers.openai.com/api/docs/models/gpt-5.4)
- [GPT-5.4 mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini)
- [GPT-5.3-Codex](https://developers.openai.com/api/docs/models/gpt-5.3-codex)
- [GPT-5.2-Codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex)
- [GPT-5.2](https://developers.openai.com/api/docs/models/gpt-5.2)
- [GPT-5-Codex](https://developers.openai.com/api/docs/models/gpt-5-codex)
- [GPT-5](https://developers.openai.com/api/docs/models/gpt-5)

金额是标准 API 等价估算，不是 ChatGPT/Codex 套餐的实际账单，也不能用来推断一个官方固定的 Pro 周美元池。Pro 5x 的百分比不需要再乘 5。估算不包含工具调用费、Fast mode、图片生成、其他共享客户端消耗、区域处理加价和 Priority/Batch/Flex 差异。GPT-5.6 缓存写入按未缓存输入价格的 1.25 倍计费，但 Codex JSONL 无法区分缓存写入 token，因此本地估算不含该项；这些不可观测消耗也会降低额度反推的准确性。

## 项目目录结构

```text
Codex-Limit-USD-Radar/
├─ .gitattributes                   # 行尾与编码约定
├─ .gitignore                       # 忽略规则
├─ .github/workflows/test.yml       # Windows CI
├─ artifacts/
│  └─ token-rader-preview.png       # 合成数据界面预览
├─ data/private/index/              # 运行时索引、7天滚动汇总与工具元数据（Git 忽略）
├─ indexer/
│  ├─ TokenRader.Indexer.cs         # C# JSONL→SQLite 索引引擎源码
│  ├─ TokenRader.Indexer.dll        # 预构建增量索引引擎
│  └─ System.Data.SQLite.dll        # SQLite 提供程序（构建依赖）
├─ launcher/
│  └─ TokenRader.Launcher.cs        # 无控制台启动器源码
├─ tests/
│  ├─ Run-Tests.ps1                 # 回归测试与可选 Live 检查
│  ├─ Run-AggregatePerformanceTests.ps1 # 编译态聚合语义与大批量性能测试
│  ├─ Run-UiCallbackTests.ps1        # 后台回调、超时与取消测试
│  └─ Render-Preview.ps1             # 合成预览图生成
├─ Build.ps1                         # 构建 TokenRader.exe
├─ LICENSE                           # MIT 许可证
├─ MainWindow.xaml                   # WPF 布局与样式
├─ pricing.json                      # 模型价格、阈值和官方来源
├─ Start-TokenRader.cmd              # PowerShell 宿主回退启动脚本
├─ THIRD_PARTY_NOTICES.md            # 第三方参考与声明
├─ TokenRader.Core.psm1              # 日志解析、去重、计价和额度算法
├─ TokenRader.exe                    # 预构建启动器
└─ TokenRader.ps1                    # 主界面和交互流程
```

## 已知限制

- 仅支持 Windows WPF，不支持 macOS 或 Linux 图形界面。
- 依赖 Codex 当前 JSONL 日志结构；上游字段变化可能需要更新解析器。
- 历史日志没有稳定账号 ID，切换账号前后的日志无法完全自动归属。
- 没有 `session_meta.cwd` 的旧日志不能归入项目。
- 跨项目派生任务缺少父日志时，继承历史的项目归属可能不完整。
- 派生/子任务累计量包含父历史，因此不直接显示累计美元。
- 价格表为人工核对的静态快照；官方调价后需要更新 `pricing.json`。
- API 等价美元不等于套餐账单；官方未公布固定的 Pro 5x 周美元额度，Fast mode、图片/工具调用、共享额度和其他客户端会影响额度反推。
- 额度反推要求起止快照属于同一计划、同一窗口和同一重置周期；缺失或不一致时不会输出旧的估算值。
- 百分比快照和本机 token 记录可能不是一一对应；共享 agentic usage 等不可观测消耗会使 API 等价反推与实际额度变化存在差异。
- 开始/结束测量状态和冻结快照只保存在内存中；程序关闭后不能恢复未完成测量。
- 周期用量只统计本机日志中可观察到的 token 调用；其他客户端、工具或共享额度消耗不会自动进入该卡片。
- Codex 本地 JSONL 不是公开稳定 API；上游新增工具事件形态可能先显示为未识别，需通过合成日志更新识别规则。工具和图片卡片只报告可确认次数，不代表完整账单。
- 第一次冷建库仍需逐个读取历史日志；数千个小文件时可能持续数十秒到数分钟，但在后台运行。索引完成后的普通刷新只处理变化队列与新增字节；开始、查看和结束会额外枚举文件元数据以校验冻结边界，不重读未变化正文。异常大批次实时查看超过 15 秒会取消并保留上次结果，最终冻结结算仍以准确边界优先。
- 本程序不会删除 Codex 会话历史；删除 `~/.codex/sessions` 属于不可逆操作，应由用户单独确认并备份。

## 隐私与安全

- 所有解析和计算都在本机完成；运行时没有网络请求代码。
- 不读取 `~/.codex/auth.json`，不接触 API Key 或访问令牌。
- 不保存、不显示、不上传提示词、回复正文或工具输出。
- 会在项目的 `data/private/index/index.db` 创建**持久 SQLite 索引**，保存日志路径、项目工作目录、会话关系、时间、模型、token 数值、最近 7 天的紧凑滚动窗口汇总和工具/图片元数据，不保存提示词、回复正文、工具参数、URL、图片或工具输出。
- 程序没有反向代理、HTTP 监听器、API 请求或远程上报路径；“查看官方价格”只调用系统浏览器打开公开链接，统计逻辑始终仅读取本机日志和项目内 SQLite。
- 索引随程序关闭保留，以便下次只同步新增/修改日志；`data/private/` 已由 `.gitignore` 排除，不会被正常 Git 提交。“清理30天前索引”删除旧内容记录但保留轻量文件游标，“完整重建”删除并重建整个可恢复索引，两者都不接触原始日志。
- 不修改、删除或重写任何 Codex 日志。
- 仓库通过 `.gitignore` 排除环境文件、凭据、IDE 配置、日志、临时输出和私有数据目录。

## 引用方式

本项目暂时没有对应论文。若在报告、论文或软件清单中使用，可引用软件仓库：

```bibtex
@software{token_rader_2026,
  author  = {lmy1390734971-netizen},
  title   = {Token Rader: Local Codex Token Usage and API-Equivalent Cost Dashboard},
  year    = {2026},
  url     = {https://github.com/lmy1390734971-netizen/Codex-Limit-USD-Radar}
}
```

引用具体结果时，建议同时记录提交哈希、`pricing.json` 的 `verifiedAt`、Windows 版本和 PowerShell 版本。

## 许可证状态

本项目以 [MIT License](LICENSE) 发布（Copyright (c) 2026 lmy1390734971-netizen）。`THIRD_PARTY_NOTICES.md` 中的声明只适用于所参考的上游项目，与本项目自身的 MIT 许可证互不影响。

## 联系方式

- 问题、建议与错误报告：[GitHub Issues](https://github.com/lmy1390734971-netizen/Codex-Limit-USD-Radar/issues)
- 项目主页：[Codex-Limit-USD-Radar](https://github.com/lmy1390734971-netizen/Codex-Limit-USD-Radar)

为避免泄露隐私，请勿在 Issue 中上传真实 Codex 日志、账号 ID、邮箱、访问令牌、提示词或回复正文。提交问题时优先使用合成日志和脱敏截图。

## 参考项目

本程序的本地日志读取思路和记账口径参考了 MIT 许可的 [LH-03/codex-token-hud](https://github.com/LH-03/codex-token-hud)，并针对会话选择、账号标签、项目累计、指定时间段、官方 API 价格和额度估算重新实现了独立界面与逻辑。详情见 `THIRD_PARTY_NOTICES.md`。
