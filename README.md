# Token Rader

[![Windows tests](https://github.com/lmy1390734971-netizen/Codex-Token-Rader/actions/workflows/test.yml/badge.svg)](https://github.com/lmy1390734971-netizen/Codex-Token-Rader/actions/workflows/test.yml)

Token Rader 是一个只在本机运行的 Windows 桌面程序。它读取 Codex 已写入 `~/.codex/sessions` 的 JSONL 会话日志，显示某次任务或最后一次模型调用的 token 用量，并按 OpenAI 官方 API 标准处理价格计算美元等价成本。

![Token Rader 合成数据预览](artifacts/token-rader-preview.png)

## 启动

双击 `TokenRader.exe` 启动。也可以双击 `Start-TokenRader.cmd`，或在 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\TokenRader.ps1
```

要求 Windows 10/11 和 Windows PowerShell 5.1 或更高版本；无须安装 npm 包、Python 包或填写 API Key。

如果修改了启动器源代码，可运行 `.\Build.ps1` 重新生成 `TokenRader.exe`。该 EXE 只是无控制台窗口的本地启动器，解析和界面逻辑仍位于项目中的 PowerShell/XAML 文件，方便审查。

仓库中的启动器未使用商业代码签名证书；如果 Windows 显示 SmartScreen 提示，可以直接运行上述 PowerShell 命令，或在审查 `launcher/TokenRader.Launcher.cs` 后自行执行 `.\Build.ps1`。

## 主界面数据

- 使用模型：来自最近的 `turn_context.payload.model`。
- 缓存输入：`cached_input_tokens`。
- 未缓存输入：`input_tokens - cached_input_tokens`。
- 输出：`output_tokens`，其中已经包含推理输出；不会再重复加上 `reasoning_output_tokens`。
- 合计：`input_tokens + output_tokens`。
- 缓存命中率：`cached_input_tokens / input_tokens`。
- 美元等价成本：

```text
(未缓存输入 × 官方输入价
 + 缓存输入 × 官方缓存输入价
 + 输出 × 官方输出价) / 1,000,000
```

左侧“统计范围”可切换：

- `整次任务` 使用最新 `total_token_usage`，代表所选 Codex 会话的累计用量。若所选日志是派生/子任务，其累计值会包含父任务历史；程序仍显示原始 Token，但不会把这份含继承的累计值直接换算美元，以免重复计费。此时请改用“最后一次调用”或指定时间段计算。
- `最后一次调用` 使用最新 `last_token_usage`。如果这一调用超过模型官方公布的 272K 输入阈值，程序会应用相应的长上下文输入/输出倍率。
- `所选项目累计` 根据日志中的 `session_meta.cwd` 自动归类项目，汇总项目关联的全部本地会话。不同模型按每次调用分别计价，同一任务树中的父任务/子任务复制记录只计算一次。

项目下拉框会优先选中 Token Rader 自身所在目录。选择其他项目时会自动切换到“所选项目累计”；项目结果在相关日志发生变化后重新计算，没有变化时使用内存缓存。项目统计同样每 5 分钟自动更新，也可以点击右上角“立即刷新”。没有 `cwd` 元数据的旧日志不会被猜测归入任何项目。

## 指定时间段计算

主界面左侧提供“开始计算”“结束计算”和“查看结果”：

> 指定时间段始终统计该账号本机日志中的全部项目、全部 Codex 会话，不受项目下拉框当前选择影响。开始计算后项目选择会暂时禁用，结束后恢复。

1. 在运行工作前点击 `开始计算`。程序会记录当前所有 Codex 日志的结束位置，不会把之前的用量算入。
2. 启动 Codex 并完成工作。界面每 5 分钟自动刷新一次新增 token 和 API 等价美元成本；也可以随时点击“立即刷新结果”或“查看结果”。每次查看都会同步更新可反推的 5 小时/周美金额度。
3. 暂停或完成 Codex 工作后点击 `结束计算`。结果会冻结在主界面。
4. 之后如果查看了其他会话，可以点击 `查看结果` 返回刚才的时间段汇总。

时间段模式采用逐调用计量：

- 解析区间内每条 `token_count` 的 `last_token_usage`，不再直接相减多个日志的累计总数。
- 同一父任务下的并行对话或子代理可能复制相同累计记录；程序按任务树和完整 Token 指纹去重，只计算一次。
- 开始后新建的分支日志会剔除父任务在开始前已经产生的继承记录，不再把历史累计值从 0 重新计算。
- 不同根对话即使 Token 数值恰好相同也会分别统计；同一日志中切换模型时按每次调用对应的模型分别计价。

计量期间请保持 Token Rader 窗口运行。

## 5 小时与周额度

主界面会读取 Codex 日志中的额度快照：

- `window_minutes` 约为 300 时显示为“5 小时额度”；日志没有该窗口时显示“暂无”。
- `window_minutes` 为 10080 时显示为“周额度”。
- 百分比显示日志的 `used_percent`，并同时显示预计重置时间。

日志只提供百分比，不提供订阅内含额度的美元总额。Token Rader 因此使用一次完整的“开始计算—结束计算”区间进行校准：

```text
反推总美元额度 = 本次 API 等价成本 / (结束已用百分比 - 开始已用百分比)
预计已用美元 = 反推总额 × 当前已用百分比
预计剩余美元 = 反推总额 × 当前剩余百分比
```

只有同一重置周期内百分比确实上升时才显示反推金额；百分比没有变化、窗口发生重置或存在未知模型价格时显示“待校准”，不会猜测。由于 Codex、ChatGPT Work、Excel 和 Workspace Agents 在部分计划上可能共用 agentic usage，其他客户端或功能同时产生的消耗会影响反推精度。官方说明见 [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-chatgpt) 和 [Codex rate card](https://help.openai.com/en/articles/20001106-codex-rate-card)。

## 账号识别边界

程序只从 `~/.codex/.cockpit_codex_auth.json` 读取当前账号的 `email`、`account_id` 和标签更新时间。它**不会读取**包含访问令牌的 `~/.codex/auth.json`。

Codex 的会话日志目前没有稳定写入账号 ID。因此：

- 当前账号标签可用于确认“现在登录的是哪个账号”；
- 所选会话的 token 用量来自该会话文件本身；
- 如果曾切换账号，切换前的历史日志无法仅凭日志可靠地归属到某个账号，界面会明确提示这一点。

## 价格与金额说明

`pricing.json` 保存界面显示的官方 API 标准处理价格，核对日期为 **2026-07-27**。内置模型包括 GPT-5、GPT-5-Codex、GPT-5.2、GPT-5.2-Codex、GPT-5.3-Codex、GPT-5.4、GPT-5.4 mini、GPT-5.5、GPT-5.6 Sol/Terra/Luna。

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

金额是“如果相同 token 通过标准 API 处理”的等价估算，不是 ChatGPT/Codex 套餐的实际账单或扣除额度。以下项目未计入：工具调用费、区域处理加价、Priority/Batch/Flex 差异，以及日志无法区分的 GPT-5.6 缓存写入加价。时间段模式按每次调用判断长上下文倍率；单独查看“整次任务”时仍无法从累计值还原每次调用，因此不会猜测长上下文附加费。

当模型没有公开价格或未收录在 `pricing.json` 时，程序显示“无法估算”，不会错误地按 `$0` 计算。价格发生变化后，可以直接编辑 `pricing.json`；每个条目都包含官方来源 URL。

## 隐私

- 所有解析和计算都在本机完成；程序没有网络请求代码。
- 只解析 `token_count`、`turn_context` 和不含密钥的账号元数据。
- 不保存、不显示、不上传提示词、回复正文或工具输出。
- 不修改、删除或重写任何 Codex 日志。

## 测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Run-Tests.ps1
```

加入 `-Live` 会额外对本机最新 Codex 日志执行只读解析检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Run-Tests.ps1 -Live
```

## 项目结构

- `TokenRader.ps1`：WPF 界面、刷新流程和交互状态。
- `TokenRader.Core.psm1`：日志解析、任务树去重、项目汇总、价格与额度计算。
- `MainWindow.xaml`：桌面界面布局与样式。
- `pricing.json`：经官方模型页面核对的标准 API 价格。
- `launcher/`、`Build.ps1`：无控制台窗口启动器及构建脚本。
- `tests/`：回归测试与合成数据预览生成脚本。
- `artifacts/token-rader-preview.png`：不含真实账号或日志内容的界面预览。

## 参考项目

本程序的本地日志读取思路和记账口径参考了 MIT 许可的 [LH-03/codex-token-hud](https://github.com/LH-03/codex-token-hud)，并针对“会话选择、账号标签、官方 API 价格展示和美元估算”重新实现了独立界面与逻辑。详情见 `THIRD_PARTY_NOTICES.md`。
