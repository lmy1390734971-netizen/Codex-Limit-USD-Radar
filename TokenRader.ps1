[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $PSCommandPath + '"'))
    $hostExecutable = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    Start-Process -FilePath $hostExecutable -ArgumentList $arguments | Out-Null
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $PSScriptRoot 'TokenRader.Core.psm1') -Force

$script:Paths = Get-TokenRaderPaths -ProjectRoot $PSScriptRoot
$script:Prices = Get-TokenRaderPrices -PricingPath $script:Paths.PricingPath
$script:State = @{
    Refreshing = $false
    CurrentPriceUrl = ''
    LastSnapshot = $null
    ViewMode = 'session'
    IsMeasuring = $false
    IntervalBaseline = $null
    IntervalResult = $null
    IntervalComputing = $false
    IntervalComputePending = $false
    IntervalComputePendingRequest = $null
    IntervalCache = $null
    RateLimits = $null
    QuotaEstimates = $null
    QuotaCalibrationMessage = '美元总额需通过一次使额度百分比上升的时间段测量进行反推。'
    Projects = @()
    ProjectCache = @{}
}

$script:WindowClosing = $false
$script:ComputePowerShell = $null

# Runs in a background runspace so interval computation never blocks the UI.
# The baseline and cache tables cross the runspace boundary through PowerShell
# serialization, which preserves DateTimeOffset, DateTime, Int64 and nested
# pscustomobject graphs (verified by tests/Run-Tests.ps1).
$script:IntervalComputeScript = {
    param(
        $Baseline,
        $Snapshots,
        $EventCache,
        $EndOffsets,
        [string]$PricingPath,
        [string]$ModulePath,
        [string]$SessionsRoot,
        [bool]$ScanRateLimits
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module $ModulePath -Force
    $prices = Get-TokenRaderPrices -PricingPath $PricingPath
    $result = Get-TokenRaderIntervalResult -Baseline $Baseline -PricingDocument $prices -BaselineSnapshots $Snapshots -EventCache $EventCache -EndOffsets $EndOffsets
    $latest = $null
    if ($ScanRateLimits) {
        $latest = Get-TokenRaderLatestRateLimits -SessionsRoot $SessionsRoot
    }
    [pscustomobject]@{
        Result = $result
        LatestRateLimits = $latest
    }
}

[xml]$xaml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'MainWindow.xaml')
$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    'AutoRefreshCheckBox', 'RefreshButton', 'AccountNameText', 'PlanText', 'AccountIdText', 'AccountHintText',
    'SessionCountText', 'OpenLogsButton', 'ProjectComboBox', 'ScopeComboBox', 'SessionListBox', 'SelectedSessionText', 'UpdatedText',
    'ScopeBadgeText', 'ModelMetricText', 'CachedMetricText', 'UncachedMetricText', 'OutputMetricText',
    'TotalMetricText', 'HitRateMetricText', 'HitRateProgress', 'UsdCostText', 'CostBreakdownText',
    'LongContextText', 'PricingVerifiedText', 'OpenPricingButton', 'InputPriceText', 'CachedPriceText',
    'OutputPriceText', 'FormulaText', 'PricingDataGrid', 'CaveatText', 'StatusText'
    'IntervalStatusText', 'IntervalTimeText', 'StartMeasureButton', 'StopMeasureButton', 'ViewIntervalButton'
    'FiveHourUsageText', 'FiveHourProgress', 'FiveHourDollarText', 'FiveHourResetText',
    'WeeklyUsageText', 'WeeklyProgress', 'WeeklyDollarText', 'WeeklyResetText', 'QuotaEstimateHintText'
)
foreach ($name in $controlNames) {
    Set-Variable -Name $name -Scope Script -Value $script:Window.FindName($name)
}

function Open-TokenRaderUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Url
    $startInfo.UseShellExecute = $true
    [Diagnostics.Process]::Start($startInfo) | Out-Null
}

function Get-SelectedScope {
    $item = $script:ScopeComboBox.SelectedItem
    if ($null -ne $item -and $null -ne $item.Tag) {
        $tag = [string]$item.Tag
        if ($tag -eq 'call' -or $tag -eq 'project') { return $tag }
    }
    return 'task'
}

function Set-EmptyMetrics {
    param([string]$Message = '等待日志数据')
    $script:ModelMetricText.Text = '—'
    $script:CachedMetricText.Text = '0'
    $script:UncachedMetricText.Text = '0'
    $script:OutputMetricText.Text = '0'
    $script:TotalMetricText.Text = '0'
    $script:HitRateMetricText.Text = '0.0%'
    $script:HitRateProgress.Value = 0
    $script:UsdCostText.Text = '—'
    $script:CostBreakdownText.Text = $Message
    $script:LongContextText.Text = '等待可计价记录'
    $script:InputPriceText.Text = '—'
    $script:CachedPriceText.Text = '—'
    $script:OutputPriceText.Text = '—'
    $script:OpenPricingButton.IsEnabled = $false
    $script:State.CurrentPriceUrl = ''
    Update-QuotaCards
}

function Set-UsageMetrics {
    param([Parameter(Mandatory = $true)]$Usage, [Parameter(Mandatory = $true)][string]$Model)
    $script:ModelMetricText.Text = $Model
    $script:CachedMetricText.Text = Format-TokenRaderNumber ([Int64]$Usage.Cached)
    $script:UncachedMetricText.Text = Format-TokenRaderNumber ([Int64]$Usage.Uncached)
    $script:OutputMetricText.Text = Format-TokenRaderNumber ([Int64]$Usage.Output)
    $script:TotalMetricText.Text = Format-TokenRaderNumber ([Int64]$Usage.Total)
    $script:HitRateMetricText.Text = ('{0:0.0}%' -f [double]$Usage.CacheHitRate)
    $script:HitRateProgress.Value = [Math]::Max(0, [Math]::Min(100, [double]$Usage.CacheHitRate))
}

function Format-IntervalDuration {
    param([Parameter(Mandatory = $true)][TimeSpan]$Duration)
    if ($Duration.TotalHours -ge 1) { return ('{0} 小时 {1} 分 {2} 秒' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds) }
    if ($Duration.TotalMinutes -ge 1) { return ('{0} 分 {1} 秒' -f [int]$Duration.TotalMinutes, $Duration.Seconds) }
    return ('{0} 秒' -f [Math]::Max(0, [int]$Duration.TotalSeconds))
}

function Merge-LatestRateLimits {
    param($Candidate)
    if ($null -eq $Candidate) { return }
    $current = $script:State.RateLimits
    if ($null -eq $current) {
        $script:State.RateLimits = $Candidate
        return
    }
    $candidateIsNewer = $Candidate.ObservedAt -ge $current.ObservedAt
    $fiveHour = if ($null -ne $Candidate.FiveHour -and ($candidateIsNewer -or $null -eq $current.FiveHour)) { $Candidate.FiveHour } else { $current.FiveHour }
    $weekly = if ($null -ne $Candidate.Weekly -and ($candidateIsNewer -or $null -eq $current.Weekly)) { $Candidate.Weekly } else { $current.Weekly }
    $planType = if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.PlanType)) { [string]$Candidate.PlanType } else { [string]$current.PlanType }
    $script:State.RateLimits = [pscustomobject]@{
        ObservedAt = if ($candidateIsNewer) { $Candidate.ObservedAt } else { $current.ObservedAt }
        PlanType = $planType
        FiveHour = $fiveHour
        Weekly = $weekly
    }
}

function Set-QuotaWindowCard {
    param(
        $Window,
        $Estimate,
        [Parameter(Mandatory = $true)]$UsageText,
        [Parameter(Mandatory = $true)]$Progress,
        [Parameter(Mandatory = $true)]$DollarText,
        [Parameter(Mandatory = $true)]$ResetText
    )

    if ($null -eq $Window) {
        $UsageText.Text = '暂无'
        $Progress.Value = 0
        $DollarText.Text = '美金额度：当前日志未提供'
        $ResetText.Text = '暂无窗口'
        return
    }
    $UsageText.Text = ('{0:0.#}%' -f [double]$Window.UsedPercent)
    $Progress.Value = [Math]::Max(0, [Math]::Min(100, [double]$Window.UsedPercent))
    $ResetText.Text = if ($null -ne $Window.ResetsAt) { ('重置 {0:MM-dd HH:mm}' -f $Window.ResetsAt) } else { ('{0} 分钟窗口' -f $Window.WindowMinutes) }
    if ($null -ne $Estimate) {
        $DollarText.Text = ('总额≈{0} · 已用≈{1} · 剩余≈{2}' -f
            (Format-TokenRaderUsd ([double]$Estimate.TotalUsd)),
            (Format-TokenRaderUsd ([double]$Estimate.UsedUsd)),
            (Format-TokenRaderUsd ([double]$Estimate.RemainingUsd)))
    } else {
        $DollarText.Text = '美金额度：待时间段校准'
    }
}

function Update-QuotaCards {
    $rateLimits = $script:State.RateLimits
    $estimates = $script:State.QuotaEstimates
    $fiveWindow = if ($null -ne $rateLimits) { $rateLimits.FiveHour } else { $null }
    $weeklyWindow = if ($null -ne $rateLimits) { $rateLimits.Weekly } else { $null }
    $fiveEstimate = if ($null -ne $estimates) { $estimates.FiveHour } else { $null }
    $weeklyEstimate = if ($null -ne $estimates) { $estimates.Weekly } else { $null }
    Set-QuotaWindowCard -Window $fiveWindow -Estimate $fiveEstimate -UsageText $script:FiveHourUsageText -Progress $script:FiveHourProgress -DollarText $script:FiveHourDollarText -ResetText $script:FiveHourResetText
    Set-QuotaWindowCard -Window $weeklyWindow -Estimate $weeklyEstimate -UsageText $script:WeeklyUsageText -Progress $script:WeeklyProgress -DollarText $script:WeeklyDollarText -ResetText $script:WeeklyResetText
    $script:QuotaEstimateHintText.Text = [string]$script:State.QuotaCalibrationMessage
}

function Update-QuotaEstimatesFromInterval {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [bool]$Final = $false
    )

    if ($null -eq $script:State.IntervalBaseline -or $null -eq $Result) { return }
    $newEstimates = Get-TokenRaderQuotaEstimate `
        -StartRateLimits $script:State.IntervalBaseline.RateLimits `
        -EndRateLimits $script:State.RateLimits `
        -IntervalCost ([double]$Result.TotalCost) `
        -CostComplete ([bool]$Result.CostComplete)
    $previousEstimates = $script:State.QuotaEstimates
    $script:State.QuotaEstimates = [pscustomobject]@{
        FiveHour = if ($null -ne $newEstimates.FiveHour) { $newEstimates.FiveHour } elseif ($null -ne $previousEstimates) { $previousEstimates.FiveHour } else { $null }
        Weekly = if ($null -ne $newEstimates.Weekly) { $newEstimates.Weekly } elseif ($null -ne $previousEstimates) { $previousEstimates.Weekly } else { $null }
    }

    $calibrated = @()
    if ($null -ne $newEstimates.FiveHour) { $calibrated += ('5 小时 +{0:0.#}%' -f $newEstimates.FiveHour.DeltaPercent) }
    if ($null -ne $newEstimates.Weekly) { $calibrated += ('周 +{0:0.#}%' -f $newEstimates.Weekly.DeltaPercent) }
    $phase = if ($Final) { '最终' } else { '实时' }
    $script:State.QuotaCalibrationMessage = if ($calibrated.Count -gt 0) {
        ('{0}反推已同步：{1}。' -f $phase, ($calibrated -join '，'))
    } elseif (-not [bool]$Result.CostComplete) {
        '存在未收录价格的模型，暂时无法反推完整美金额度。'
    } elseif ([double]$Result.TotalCost -le 0) {
        '当前时间段尚无可计价消耗，点击“查看结果”会再次检查。'
    } elseif ($null -ne $previousEstimates) {
        '本次额度百分比尚未继续上升；继续显示最近一次反推结果。'
    } else {
        '开始与当前额度百分比尚无增量；额度上升后点击“查看结果”即可同步反推。'
    }
    Update-QuotaCards
}

function Show-IntervalResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [bool]$Running
    )

    $script:SelectedSessionText.Text = if ($Running) { '全部项目 · 指定时间段消耗（计算中）' } else { '全部项目 · 指定时间段消耗' }
    $script:ScopeBadgeText.Text = if ($Running) { '全部项目实时计算' } else { '全部项目时间段' }
    $duration = $Result.EndedAt - $Result.StartedAt
    $durationText = Format-IntervalDuration $duration
    $script:UpdatedText.Text = ('{0:HH:mm:ss} → {1:HH:mm:ss} · {2} · {3} 个活跃会话' -f $Result.StartedAt, $Result.EndedAt, $durationText, $Result.ChangedSessions)
    $script:IntervalTimeText.Text = if ($Running) {
        ('开始于 {0:HH:mm:ss} · 已计时 {1}' -f $Result.StartedAt, $durationText)
    } else {
        ('{0:HH:mm:ss} — {1:HH:mm:ss} · 共 {2}' -f $Result.StartedAt, $Result.EndedAt, $durationText)
    }

    Set-UsageMetrics -Usage $Result.Usage -Model ([string]$Result.ModelDisplay)
    $costLabel = Format-TokenRaderUsd ([double]$Result.TotalCost)
    $script:UsdCostText.Text = if ($Result.CostComplete) { $costLabel } else { $costLabel + '（部分）' }
    $script:CostBreakdownText.Text = ('未缓存 {0} · 缓存 {1} · 输出 {2}' -f
        (Format-TokenRaderUsd ([double]$Result.InputCost)),
        (Format-TokenRaderUsd ([double]$Result.CachedCost)),
        (Format-TokenRaderUsd ([double]$Result.OutputCost)))
    $script:LongContextText.Text = if ($Result.CostComplete) { '按唯一调用及各自模型 API 价汇总' } else { '存在未收录价格的模型' }

    if (@($Result.Models).Count -eq 1) {
        $price = Resolve-TokenRaderPrice -Model ([string]$Result.Models[0]) -PricingDocument $script:Prices
        if ($null -ne $price) {
            $script:InputPriceText.Text = ('$' + ([double]$price.input).ToString('0.###'))
            $script:CachedPriceText.Text = ('$' + ([double]$price.cachedInput).ToString('0.###'))
            $script:OutputPriceText.Text = ('$' + ([double]$price.output).ToString('0.###'))
            $script:State.CurrentPriceUrl = [string]$price.source
            $script:OpenPricingButton.IsEnabled = $true
        }
    } elseif (@($Result.Models).Count -gt 1) {
        $script:InputPriceText.Text = '多模型'
        $script:CachedPriceText.Text = '多模型'
        $script:OutputPriceText.Text = '多模型'
        $script:State.CurrentPriceUrl = ''
        $script:OpenPricingButton.IsEnabled = $false
    } else {
        $script:InputPriceText.Text = '等待调用'
        $script:CachedPriceText.Text = '等待调用'
        $script:OutputPriceText.Text = '等待调用'
        $script:State.CurrentPriceUrl = ''
        $script:OpenPricingButton.IsEnabled = $false
    }
    $script:FormulaText.Text = '时间段始终统计全部项目和全部 Codex 会话，不受项目下拉框影响；区间内同一任务树的复制记录只计算一次。'
    $script:CaveatText.Text = ('项目选择已忽略。已检查 {0:N0} 条记录，计入 {1:N0} 次唯一调用；去除共享重复 {2:N0} 条、基线前继承 {3:N0} 条。每次调用按当时模型分别计价，仍是 API 等价估算，不是套餐实际账单。' -f
        [Int64]$Result.RawEvents,
        [Int64]$Result.CountedEvents,
        [Int64]$Result.DuplicateEventsDropped,
        [Int64]$Result.InheritedEventsDropped)
    $script:StatusText.Text = if ($Running) { '正在实时统计全部项目在指定时间段内的新消耗…' } else { '全部项目的时间段计算已结束，结果已冻结。' }
    Update-QuotaCards
}

function Reset-TokenRaderComputeHost {
    if ($null -ne $script:ComputePowerShell) {
        try { $script:ComputePowerShell.Dispose() } catch { }
        $script:ComputePowerShell = $null
    }
}

function Start-TokenRaderIntervalComputeAsync {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [hashtable]$EndOffsets = $null,
        [bool]$Final = $false,
        [bool]$ScanRateLimits = $false
    )

    if ($script:WindowClosing) { return }
    if ([bool]$script:State.IntervalComputing) {
        # A computation is already running; coalesce one follow-up request that
        # carries the latest request parameters for the same baseline.
        $script:State.IntervalComputePending = $true
        $script:State.IntervalComputePendingRequest = @{
            BaselineStartedAt = [DateTimeOffset]$Baseline.StartedAt
            EndOffsets = $EndOffsets
            Final = $Final
            ScanRateLimits = $ScanRateLimits
        }
        return
    }

    $script:State.IntervalComputing = $true
    if ($Final) { $script:StatusText.Text = '正在后台结算指定时间段…' }
    else { $script:StatusText.Text = '正在后台计算指定时间段消耗…' }

    $baselineStartedAt = [DateTimeOffset]$Baseline.StartedAt
    $snapshots = @{}
    $eventCache = @{}
    if ($null -ne $script:State.IntervalCache) {
        $snapshots = $script:State.IntervalCache.BaselineSnapshots
        $eventCache = $script:State.IntervalCache.EventCache
    }

    $ps = $null
    try {
        if ($null -eq $script:ComputePowerShell) {
            $script:ComputePowerShell = [powershell]::Create()
        }
        $ps = $script:ComputePowerShell
        $ps.Commands.Clear()
        [void]$ps.AddScript($script:IntervalComputeScript)
        [void]$ps.AddParameter('Baseline', $Baseline)
        [void]$ps.AddParameter('Snapshots', $snapshots)
        [void]$ps.AddParameter('EventCache', $eventCache)
        [void]$ps.AddParameter('EndOffsets', $EndOffsets)
        [void]$ps.AddParameter('PricingPath', $script:Paths.PricingPath)
        [void]$ps.AddParameter('ModulePath', (Join-Path $PSScriptRoot 'TokenRader.Core.psm1'))
        [void]$ps.AddParameter('SessionsRoot', $script:Paths.SessionsRoot)
        [void]$ps.AddParameter('ScanRateLimits', $ScanRateLimits)

        $wasFinal = $Final
        $wasStartedAt = $baselineStartedAt
        $null = $ps.BeginInvoke([System.AsyncCallback]{
            param($AsyncResult)
            $callbackPs = $ps
            try {
                $output = @($callbackPs.EndInvoke($AsyncResult))
                $payload = if ($output.Count -gt 0) { $output[0] } else { $null }
                if (-not $script:WindowClosing -and -not $script:Window.Dispatcher.HasShutdownStarted) {
                    $script:Window.Dispatcher.Invoke([action]{
                        Complete-TokenRaderIntervalCompute -BaselineStartedAt $wasStartedAt -Payload $payload -Final $wasFinal
                    })
                } else {
                    $script:State.IntervalComputing = $false
                }
            } catch {
                try {
                    if ($null -ne $script:ComputePowerShell) {
                        try { $script:ComputePowerShell.Dispose() } catch { }
                        $script:ComputePowerShell = $null
                    }
                    if (-not $script:WindowClosing -and -not $script:Window.Dispatcher.HasShutdownStarted) {
                        $script:Window.Dispatcher.Invoke([action]{
                            $script:State.IntervalComputing = $false
                            $script:StatusText.Text = '时间段后台计算失败，请稍后重试。'
                        })
                    } else {
                        $script:State.IntervalComputing = $false
                    }
                } catch {
                    $script:State.IntervalComputing = $false
                }
            }
        }, $null)
    } catch {
        # Fallback: run the computation synchronously so the feature keeps
        # working even if a background runspace cannot be created here.
        if ($null -ne $ps) {
            try { $ps.Dispose() } catch { }
        }
        Reset-TokenRaderComputeHost
        $script:State.IntervalComputing = $false
        try {
            $result = Get-TokenRaderIntervalResult -Baseline $Baseline -PricingDocument $script:Prices -BaselineSnapshots $snapshots -EventCache $eventCache -EndOffsets $EndOffsets
            $latest = if ($ScanRateLimits) { Get-TokenRaderLatestRateLimits -SessionsRoot $script:Paths.SessionsRoot } else { $null }
            Complete-TokenRaderIntervalCompute -BaselineStartedAt $baselineStartedAt -Payload ([pscustomobject]@{ Result = $result; LatestRateLimits = $latest }) -Final $Final
        } catch {
            $script:State.IntervalComputing = $false
            $script:StatusText.Text = '时间段计算失败：' + $_.Exception.Message
        }
    }
}

function Complete-TokenRaderIntervalCompute {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$BaselineStartedAt,
        $Payload,
        [bool]$Final = $false
    )

    try {
        if ($null -eq $Payload -or $null -eq $Payload.Result) {
            if (-not $script:WindowClosing) { $script:StatusText.Text = '时间段后台计算未返回结果。' }
            return
        }
        $currentBaseline = $script:State.IntervalBaseline
        if ($null -eq $currentBaseline -or [DateTimeOffset]$currentBaseline.StartedAt -ne $BaselineStartedAt) {
            return  # result belongs to a previous measurement; discard it
        }
        $result = $Payload.Result
        $script:State.IntervalResult = $result
        Merge-LatestRateLimits -Candidate $Payload.LatestRateLimits
        Merge-LatestRateLimits -Candidate $result.RateLimits
        Update-QuotaEstimatesFromInterval -Result $result -Final $Final
        $script:State.IntervalCache = [pscustomobject]@{
            BaselineStartedAt = $BaselineStartedAt
            Signature = [string]$result.Signature
            Result = $result
            BaselineSnapshots = $result.BaselineSnapshots
            EventCache = $result.EventCache
        }
        Show-IntervalResult -Result $result -Running ([bool]$script:State.IsMeasuring)
        if ($Final) {
            $script:IntervalStatusText.Text = '已完成'
            $script:IntervalStatusText.Foreground = [Windows.Media.Brushes]::LightSkyBlue
        }
    } catch {
        if (-not $script:WindowClosing) { $script:StatusText.Text = '时间段结果更新失败：' + $_.Exception.Message }
    } finally {
        $script:State.IntervalComputing = $false
        if (-not $script:WindowClosing -and $script:State.IntervalComputePending -and $null -ne $script:State.IntervalBaseline) {
            $request = $script:State.IntervalComputePendingRequest
            $script:State.IntervalComputePending = $false
            $script:State.IntervalComputePendingRequest = $null
            if ([DateTimeOffset]$request.BaselineStartedAt -eq [DateTimeOffset]$script:State.IntervalBaseline.StartedAt) {
                Start-TokenRaderIntervalComputeAsync -Baseline $script:State.IntervalBaseline -EndOffsets $request.EndOffsets -Final ([bool]$request.Final) -ScanRateLimits ([bool]$request.ScanRateLimits)
            }
        }
    }
}

function Update-IntervalView {
    if ($null -eq $script:State.IntervalBaseline) { return }
    if ([bool]$script:State.IsMeasuring) {
        if ([bool]$script:State.IntervalComputing) { return }
        $cacheHit = $false
        $cache = $script:State.IntervalCache
        if ($null -ne $cache -and [DateTimeOffset]$cache.BaselineStartedAt -eq [DateTimeOffset]$script:State.IntervalBaseline.StartedAt) {
            $signature = Get-TokenRaderSessionTreeSignature -SessionsRoot $script:Paths.SessionsRoot
            if ([string]$signature -eq [string]$cache.Signature) {
                $cacheHit = $true
                $script:State.IntervalResult = $cache.Result
            }
        }
        if (-not $cacheHit) {
            Start-TokenRaderIntervalComputeAsync -Baseline $script:State.IntervalBaseline
        }
    }
    if ($null -ne $script:State.IntervalResult) {
        Show-IntervalResult -Result $script:State.IntervalResult -Running ([bool]$script:State.IsMeasuring)
    }
}

function Update-ProjectView {
    $project = $script:ProjectComboBox.SelectedItem
    if ($null -eq $project) {
        $script:SelectedSessionText.Text = '请选择一个项目'
        $script:UpdatedText.Text = '项目来自 Codex 日志中的 session_meta.cwd'
        $script:ScopeBadgeText.Text = '项目累计'
        Set-EmptyMetrics -Message '尚未选择项目'
        $script:FormulaText.Text = '选择项目后，程序会汇总该目录关联的全部本地 Codex 会话。'
        $script:CaveatText.Text = '只有包含 cwd 元数据的日志才能归入项目。'
        $script:StatusText.Text = '等待选择项目。'
        return
    }

    $key = ([string]$project.ProjectPath).ToLowerInvariant()
    $cached = if ($script:State.ProjectCache.ContainsKey($key)) { $script:State.ProjectCache[$key] } else { $null }
    $result = $null
    if ($null -ne $cached -and [string]$cached.Signature -eq [string]$project.Signature) {
        $result = $cached.Result
    } else {
        $script:StatusText.Text = ('正在汇总项目 {0} 的本地日志…' -f [string]$project.ProjectName)
        try {
            $result = Get-TokenRaderProjectResult -Project $project -SessionsRoot $script:Paths.SessionsRoot -PricingDocument $script:Prices
            $script:State.ProjectCache[$key] = [pscustomobject]@{ Signature = [string]$project.Signature; Result = $result }
        } catch {
            $script:SelectedSessionText.Text = ('项目：{0}' -f [string]$project.ProjectName)
            $script:UpdatedText.Text = [string]$project.ProjectPath
            $script:ScopeBadgeText.Text = '项目累计'
            Set-EmptyMetrics -Message '项目汇总失败'
            $script:FormulaText.Text = '无法完成项目日志汇总。'
            $script:CaveatText.Text = [string]$_.Exception.Message
            $script:StatusText.Text = '项目统计失败，请查看提示。'
            return
        }
    }

    if ($null -eq $result) {
        Set-EmptyMetrics -Message '该项目尚无可计算的 token_count'
        $script:SelectedSessionText.Text = ('项目：{0}' -f [string]$project.ProjectName)
        $script:UpdatedText.Text = [string]$project.ProjectPath
        $script:ScopeBadgeText.Text = '项目累计'
        $script:StatusText.Text = '项目日志中尚无 Token 记录。'
        return
    }

    $script:SelectedSessionText.Text = ('项目：{0}' -f [string]$project.ProjectName)
    $script:UpdatedText.Text = ('{0} · {1} 个日志 · 最近更新 {2:yyyy-MM-dd HH:mm:ss}' -f
        [string]$project.ProjectPath,
        [int]$project.SessionCount,
        $project.LastWriteTime)
    $script:ScopeBadgeText.Text = '项目累计'
    Set-UsageMetrics -Usage $result.Usage -Model ([string]$result.ModelDisplay)

    $costLabel = Format-TokenRaderUsd ([double]$result.TotalCost)
    $script:UsdCostText.Text = if ($result.CostComplete) { $costLabel } else { $costLabel + '（部分）' }
    $script:CostBreakdownText.Text = ('未缓存 {0} · 缓存 {1} · 输出 {2}' -f
        (Format-TokenRaderUsd ([double]$result.InputCost)),
        (Format-TokenRaderUsd ([double]$result.CachedCost)),
        (Format-TokenRaderUsd ([double]$result.OutputCost)))
    $script:LongContextText.Text = if ($result.CostComplete) { '按任务树去重，并按每次调用的模型计价' } else { '存在未收录官方价格的模型，金额为部分合计' }

    if (@($result.Models).Count -eq 1) {
        $price = Resolve-TokenRaderPrice -Model ([string]$result.Models[0]) -PricingDocument $script:Prices
        if ($null -ne $price) {
            $script:InputPriceText.Text = ('$' + ([double]$price.input).ToString('0.###'))
            $script:CachedPriceText.Text = ('$' + ([double]$price.cachedInput).ToString('0.###'))
            $script:OutputPriceText.Text = ('$' + ([double]$price.output).ToString('0.###'))
            $script:State.CurrentPriceUrl = [string]$price.source
            $script:OpenPricingButton.IsEnabled = $true
        }
    } elseif (@($result.Models).Count -gt 1) {
        $script:InputPriceText.Text = '多模型'
        $script:CachedPriceText.Text = '多模型'
        $script:OutputPriceText.Text = '多模型'
        $script:State.CurrentPriceUrl = ''
        $script:OpenPricingButton.IsEnabled = $false
    } else {
        $script:InputPriceText.Text = '等待调用'
        $script:CachedPriceText.Text = '等待调用'
        $script:OutputPriceText.Text = '等待调用'
        $script:State.CurrentPriceUrl = ''
        $script:OpenPricingButton.IsEnabled = $false
    }

    $script:FormulaText.Text = '项目累计 = cwd 与所选目录一致的全部本地会话；逐调用汇总，并在同一任务树内去除复制记录。'
    $script:CaveatText.Text = ('共扫描 {0:N0} 条 Token 记录，计入 {1:N0} 条唯一记录，去除任务树重复 {2:N0} 条；覆盖 {3:N0} 个有用量的日志。金额为官方 API 等价估算，不是 Codex 套餐实际账单。' -f
        [Int64]$result.RawEvents,
        [Int64]$result.CountedEvents,
        [Int64]$result.DuplicateEventsDropped,
        [Int64]$result.ChangedSessions)
    $script:StatusText.Text = ('项目 {0} 汇总完成；结果会在日志变化或手动刷新后更新。' -f [string]$project.ProjectName)
    Update-QuotaCards
}

function Start-IntervalMeasurement {
    if ([bool]$script:State.IsMeasuring) { return }
    $script:StatusText.Text = '正在记录开始位置…'
    $script:State.IntervalBaseline = New-TokenRaderMeasurementBaseline -SessionsRoot $script:Paths.SessionsRoot
    Merge-LatestRateLimits -Candidate $script:State.IntervalBaseline.RateLimits
    $script:State.IntervalResult = $null
    $script:State.IntervalCache = $null
    $script:State.IsMeasuring = $true
    $script:State.ViewMode = 'interval'
    $script:StartMeasureButton.IsEnabled = $false
    $script:StopMeasureButton.IsEnabled = $true
    $script:ViewIntervalButton.IsEnabled = $true
    $script:SessionListBox.IsEnabled = $false
    $script:ProjectComboBox.IsEnabled = $false
    $script:ScopeComboBox.IsEnabled = $false
    $script:IntervalStatusText.Text = '计算中'
    $script:IntervalStatusText.Foreground = [Windows.Media.Brushes]::Aquamarine
    Start-TokenRaderIntervalComputeAsync -Baseline $script:State.IntervalBaseline
}

function Stop-IntervalMeasurement {
    if (-not [bool]$script:State.IsMeasuring -or $null -eq $script:State.IntervalBaseline) { return }
    $script:StatusText.Text = '正在冻结并结算指定时间段…'

    # Capture end offsets synchronously (metadata only) so the final result
    # counts exactly the data written up to this click, even though the actual
    # computation runs in the background afterwards.
    $endOffsets = @{}
    if (Test-Path -LiteralPath $script:Paths.SessionsRoot) {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:Paths.SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
            $endOffsets[[string]$file.FullName] = [Int64]$file.Length
        }
    }

    $script:State.IsMeasuring = $false
    $script:State.ViewMode = 'interval'
    $script:StartMeasureButton.IsEnabled = $true
    $script:StopMeasureButton.IsEnabled = $false
    $script:ViewIntervalButton.IsEnabled = $true
    $script:SessionListBox.IsEnabled = $true
    $script:ProjectComboBox.IsEnabled = $true
    $script:ScopeComboBox.IsEnabled = $true
    $script:IntervalStatusText.Text = '结算中'
    $script:IntervalStatusText.Foreground = [Windows.Media.Brushes]::LightSkyBlue

    Start-TokenRaderIntervalComputeAsync -Baseline $script:State.IntervalBaseline -EndOffsets $endOffsets -Final $true -ScanRateLimits $true
}

function Set-PricingTable {
    $rows = foreach ($entry in $script:Prices.models) {
        [pscustomobject]@{
            Model = [string]$entry.displayName
            Input = ('$' + ([double]$entry.input).ToString('0.###'))
            Cached = ('$' + ([double]$entry.cachedInput).ToString('0.###'))
            Output = ('$' + ([double]$entry.output).ToString('0.###'))
        }
    }
    $script:PricingDataGrid.ItemsSource = @($rows)
    $script:PricingVerifiedText.Text = ('USD / 1M tokens · 官方页面核对于 {0}' -f [string]$script:Prices.verifiedAt)
}

function Update-UsageView {
    if ($script:State.Refreshing) { return }
    if ([string]$script:State.ViewMode -eq 'interval') {
        Update-IntervalView
        return
    }
    if ((Get-SelectedScope) -eq 'project') {
        Update-ProjectView
        return
    }
    $selected = $script:SessionListBox.SelectedItem
    if ($null -eq $selected) {
        $script:SelectedSessionText.Text = '请选择一个会话'
        $script:UpdatedText.Text = '等待日志数据'
        Set-EmptyMetrics
        return
    }

    $script:StatusText.Text = '正在读取本地 token 计数…'
    $snapshot = Get-TokenRaderUsageSnapshot -FilePath ([string]$selected.FilePath)
    $script:State.LastSnapshot = $snapshot
    if ($null -eq $snapshot) {
        $script:SelectedSessionText.Text = ('会话 {0}' -f [string]$selected.ShortId)
        $script:UpdatedText.Text = '该日志尚未写入有效 token_count 记录'
        Set-EmptyMetrics -Message '尚无可计算的 token 数据'
        $script:StatusText.Text = '未找到 token_count；Codex 完成首次模型调用后会自动出现。'
        return
    }
    Merge-LatestRateLimits -Candidate $snapshot.RateLimits

    $scope = Get-SelectedScope
    $usage = if ($scope -eq 'call') { $snapshot.Call } else { $snapshot.Task }
    $sessionMetadata = Get-TokenRaderSessionMetadata -FilePath ([string]$selected.FilePath)
    $isInheritedTask = $scope -eq 'task' -and (
        -not [string]::IsNullOrWhiteSpace([string]$sessionMetadata.ParentThreadId) -or
        -not [string]::IsNullOrWhiteSpace([string]$sessionMetadata.ForkedFromId)
    )
    $scopeLabel = if ($scope -eq 'call') { '最后一次调用' } elseif ($isInheritedTask) { '整次任务（含继承）' } else { '整次任务' }
    $script:ScopeBadgeText.Text = $scopeLabel
    $script:SelectedSessionText.Text = ('会话 {0}' -f [string]$selected.ShortId)
    $script:UpdatedText.Text = ('计数更新 {0:yyyy-MM-dd HH:mm:ss} · 日志 {1}' -f $snapshot.Timestamp, [string]$selected.DisplayName)

    $model = if ([string]::IsNullOrWhiteSpace([string]$snapshot.Model)) { '未知模型' } else { [string]$snapshot.Model }
    Set-UsageMetrics -Usage $usage -Model $model
    if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.PlanType)) {
        $script:PlanText.Text = ('计划快照：{0}' -f [string]$snapshot.PlanType)
    }

    if ($isInheritedTask) {
        $price = Resolve-TokenRaderPrice -Model ([string]$snapshot.Model) -PricingDocument $script:Prices
        $script:UsdCostText.Text = '不计算'
        $script:CostBreakdownText.Text = '该子任务的累计值含父任务历史，直接计价会重复放大'
        $script:LongContextText.Text = '请改看“最后一次调用”或使用开始/结束时间段'
        if ($null -eq $price) {
            $script:InputPriceText.Text = '未公布'
            $script:CachedPriceText.Text = '未公布'
            $script:OutputPriceText.Text = '未公布'
            $script:OpenPricingButton.IsEnabled = $false
            $script:State.CurrentPriceUrl = ''
        } else {
            $script:InputPriceText.Text = ('$' + ([double]$price.input).ToString('0.###'))
            $script:CachedPriceText.Text = ('$' + ([double]$price.cachedInput).ToString('0.###'))
            $script:OutputPriceText.Text = ('$' + ([double]$price.output).ToString('0.###'))
            $script:State.CurrentPriceUrl = [string]$price.source
            $script:OpenPricingButton.IsEnabled = $true
        }
        $script:FormulaText.Text = '子任务日志会继承父任务的累计 token；为避免把同一批调用重复计费，此处不按 total_token_usage 计算美元。'
        $script:CaveatText.Text = '所选日志是派生/子任务。Token 数仍按日志原值显示，但累计美元不可靠；“最后一次调用”只计算最近一调用，“开始/结束”时间段会按任务树去重并按每次调用的实际模型分别计价。'
        $script:StatusText.Text = ('已读取 {0} · {1} · 已阻止继承用量重复计费' -f $model, $scopeLabel)
        Update-QuotaCards
        return
    }

    if ($scope -eq 'task') {
        $taskResult = Get-TokenRaderSessionResult -FilePath ([string]$selected.FilePath) -SessionsRoot $script:Paths.SessionsRoot -PricingDocument $script:Prices
        if ($null -eq $taskResult -or -not $taskResult.CostComplete) {
            $unknownModels = if ($null -ne $taskResult) { @($taskResult.UnknownModels) -join '、' } else { '未知模型' }
            $script:UsdCostText.Text = '无法估算'
            $script:CostBreakdownText.Text = ('存在未收录价格的模型：{0}' -f $unknownModels)
        } else {
            $script:UsdCostText.Text = Format-TokenRaderUsd ([double]$taskResult.TotalCost)
            $script:CostBreakdownText.Text = ('未缓存 {0} · 缓存 {1} · 输出 {2}' -f
                (Format-TokenRaderUsd ([double]$taskResult.InputCost)),
                (Format-TokenRaderUsd ([double]$taskResult.CachedCost)),
                (Format-TokenRaderUsd ([double]$taskResult.OutputCost)))
        }
        $taskModels = @($taskResult.Models)
        if ($taskModels.Count -gt 1) {
            Set-UsageMetrics -Usage $usage -Model ('{0} 个模型' -f $taskModels.Count)
            $script:InputPriceText.Text = '混合'
            $script:CachedPriceText.Text = '混合'
            $script:OutputPriceText.Text = '混合'
            $script:OpenPricingButton.IsEnabled = $false
            $script:State.CurrentPriceUrl = ''
        } else {
            $taskPrice = Resolve-TokenRaderPrice -Model ([string]$snapshot.Model) -PricingDocument $script:Prices
            if ($null -ne $taskPrice) {
                $script:InputPriceText.Text = ('$' + ([double]$taskPrice.input).ToString('0.###'))
                $script:CachedPriceText.Text = ('$' + ([double]$taskPrice.cachedInput).ToString('0.###'))
                $script:OutputPriceText.Text = ('$' + ([double]$taskPrice.output).ToString('0.###'))
                $script:State.CurrentPriceUrl = [string]$taskPrice.source
                $script:OpenPricingButton.IsEnabled = $true
            } else {
                $script:InputPriceText.Text = '未公布'
                $script:CachedPriceText.Text = '未公布'
                $script:OutputPriceText.Text = '未公布'
                $script:State.CurrentPriceUrl = ''
                $script:OpenPricingButton.IsEnabled = $false
            }
        }
        $longCalls = @($taskResult.Items | Where-Object { $_.LongContext })
        $script:LongContextText.Text = if ($longCalls.Count -gt 0) { ('逐调用长上下文加价：{0} 组' -f $longCalls.Count) } else { '逐调用标准上下文费率' }
        $script:FormulaText.Text = '整次任务按每次调用的实际模型分别计价，再汇总未缓存输入、缓存输入和输出金额。'
        $script:CaveatText.Text = '整次任务已逐调用识别模型和 272K 长上下文；金额仍是标准 API 等价估算，不含工具调用、区域处理、Priority/Batch/Flex 或 GPT-5.6 缓存写入附加价。账号切换前的历史日志仍无法仅凭日志可靠归属。'
        $script:StatusText.Text = ('已读取 {0:N0} 次唯一调用 · {1} · 本地处理完成' -f $taskResult.CountedEvents, $scopeLabel)
        Update-QuotaCards
        return
    }

    $cost = Get-TokenRaderCost -Usage $usage -Model ([string]$snapshot.Model) -PricingDocument $script:Prices -Scope $scope
    if (-not $cost.Known) {
        $script:UsdCostText.Text = '无法估算'
        $script:CostBreakdownText.Text = '该日志模型没有匹配到公开 API 标准价格'
        $script:LongContextText.Text = '价格未知，不按 $0 处理'
        $script:InputPriceText.Text = '未公布'
        $script:CachedPriceText.Text = '未公布'
        $script:OutputPriceText.Text = '未公布'
        $script:OpenPricingButton.IsEnabled = $false
        $script:State.CurrentPriceUrl = ''
        $script:FormulaText.Text = '请在 pricing.json 中加入经过官方页面核对的模型价格后再估算。'
    } else {
        $script:UsdCostText.Text = Format-TokenRaderUsd ([double]$cost.TotalCost)
        $script:CostBreakdownText.Text = ('未缓存 {0} · 缓存 {1} · 输出 {2}' -f
            (Format-TokenRaderUsd ([double]$cost.InputCost)),
            (Format-TokenRaderUsd ([double]$cost.CachedCost)),
            (Format-TokenRaderUsd ([double]$cost.OutputCost)))
        $price = $cost.Price
        $script:InputPriceText.Text = ('$' + ([double]$price.input).ToString('0.###'))
        $script:CachedPriceText.Text = ('$' + ([double]$price.cachedInput).ToString('0.###'))
        $script:OutputPriceText.Text = ('$' + ([double]$price.output).ToString('0.###'))
        $script:State.CurrentPriceUrl = [string]$price.source
        $script:OpenPricingButton.IsEnabled = $true
        if ($cost.LongContextApplied) {
            $script:LongContextText.Text = ('长上下文：输入 ×{0:0.#}，输出 ×{1:0.#}' -f $cost.InputMultiplier, $cost.OutputMultiplier)
        } elseif ($scope -eq 'task') {
            $script:LongContextText.Text = '标准价汇总（不推断逐调用长上下文）'
        } else {
            $script:LongContextText.Text = '标准上下文费率'
        }
        $script:FormulaText.Text = '费用 = 未缓存输入 × 输入价 + 缓存输入 × 缓存价 + 输出 × 输出价；输入计数本身已包含缓存输入。'
    }

    $script:CaveatText.Text = '最后一次调用使用 last_token_usage；若该次输入超过模型公布的 272K 阈值，会应用官方长上下文倍率。估算不包含工具调用、区域处理、Priority/Batch/Flex 或 GPT-5.6 缓存写入附加价。'
    $script:StatusText.Text = ('已读取 {0} · {1} · 本地处理完成' -f $model, $scopeLabel)
    Update-QuotaCards
}

function Refresh-Application {
    if ($script:State.Refreshing) { return }
    $script:State.Refreshing = $true
    try {
        $script:StatusText.Text = '正在枚举本地 Codex 会话…'
        $previousPath = ''
        if ($null -ne $script:SessionListBox.SelectedItem) {
            $previousPath = [string]$script:SessionListBox.SelectedItem.FilePath
        }
        $previousProjectPath = ''
        if ($null -ne $script:ProjectComboBox.SelectedItem) {
            $previousProjectPath = [string]$script:ProjectComboBox.SelectedItem.ProjectPath
        }

        $account = Get-TokenRaderAccount -CodexRoot $script:Paths.CodexRoot
        $script:AccountNameText.Text = [string]$account.DisplayName
        $script:AccountIdText.Text = if ([string]::IsNullOrWhiteSpace([string]$account.AccountIdShort)) { '' } else { [string]$account.AccountIdShort }
        if ($null -ne $account.WrittenAt) {
            $script:AccountHintText.Text = ('账号标签更新于 {0:MM-dd HH:mm}；历史会话归属需自行确认。' -f $account.WrittenAt)
        } else {
            $script:AccountHintText.Text = '账号只用于标记当前会话；不会读取 auth.json 中的密钥。'
        }
        Merge-LatestRateLimits -Candidate (Get-TokenRaderLatestRateLimits -SessionsRoot $script:Paths.SessionsRoot)

        $sessions = @(Get-TokenRaderSessionFiles -SessionsRoot $script:Paths.SessionsRoot)
        $projects = @(Get-TokenRaderProjects -SessionsRoot $script:Paths.SessionsRoot)
        $script:State.Projects = $projects
        $script:SessionCountText.Text = ('{0} 个日志（最多显示 200） · {1} 个项目' -f $sessions.Count, $projects.Count)
        $script:SessionListBox.ItemsSource = $null
        $script:SessionListBox.ItemsSource = $sessions
        $script:ProjectComboBox.ItemsSource = $null
        $script:ProjectComboBox.ItemsSource = $projects

        $projectIndex = 0
        $preferredProjectPath = if (-not [string]::IsNullOrWhiteSpace($previousProjectPath)) { $previousProjectPath } else { $PSScriptRoot }
        for ($i = 0; $i -lt $projects.Count; $i++) {
            if ([string]$projects[$i].ProjectPath -eq $preferredProjectPath) { $projectIndex = $i; break }
        }
        if ($projects.Count -gt 0) { $script:ProjectComboBox.SelectedIndex = $projectIndex }

        $targetIndex = 0
        if (-not [string]::IsNullOrWhiteSpace($previousPath)) {
            for ($i = 0; $i -lt $sessions.Count; $i++) {
                if ([string]$sessions[$i].FilePath -eq $previousPath) { $targetIndex = $i; break }
            }
        }
        if ($sessions.Count -gt 0) {
            $script:SessionListBox.SelectedIndex = $targetIndex
        } else {
            $script:SelectedSessionText.Text = '未找到 Codex 会话日志'
            $script:UpdatedText.Text = [string]$script:Paths.SessionsRoot
            Set-EmptyMetrics -Message '请确认 Codex 已生成本地日志'
        }
    } finally {
        $script:State.Refreshing = $false
    }
    Update-UsageView
}

$script:RefreshButton.Add_Click({ Refresh-Application })
$script:SessionListBox.Add_SelectionChanged({
    if (-not $script:State.Refreshing -and -not [bool]$script:State.IsMeasuring) {
        $script:State.ViewMode = 'session'
        Update-UsageView
    }
})
$script:ProjectComboBox.Add_SelectionChanged({
    if (-not $script:State.Refreshing -and -not [bool]$script:State.IsMeasuring) {
        $script:State.ViewMode = 'session'
        $projectScopeIndex = -1
        for ($i = 0; $i -lt $script:ScopeComboBox.Items.Count; $i++) {
            if ([string]$script:ScopeComboBox.Items[$i].Tag -eq 'project') { $projectScopeIndex = $i; break }
        }
        if ($projectScopeIndex -ge 0 -and $script:ScopeComboBox.SelectedIndex -ne $projectScopeIndex) {
            $script:ScopeComboBox.SelectedIndex = $projectScopeIndex
        } else {
            Update-UsageView
        }
    }
})
$script:ScopeComboBox.Add_SelectionChanged({
    if (-not $script:State.Refreshing -and -not [bool]$script:State.IsMeasuring) {
        $script:State.ViewMode = 'session'
        Update-UsageView
    }
})
$script:StartMeasureButton.Add_Click({ Start-IntervalMeasurement })
$script:StopMeasureButton.Add_Click({ Stop-IntervalMeasurement })
$script:ViewIntervalButton.Add_Click({
    if ($null -ne $script:State.IntervalBaseline) {
        $script:State.ViewMode = 'interval'
        Update-IntervalView
    }
})
$script:OpenLogsButton.Add_Click({
    if (Test-Path -LiteralPath $script:Paths.SessionsRoot) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList @($script:Paths.SessionsRoot) | Out-Null
    }
})
$script:OpenPricingButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace([string]$script:State.CurrentPriceUrl)) {
        Open-TokenRaderUrl -Url ([string]$script:State.CurrentPriceUrl)
    }
})

$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMinutes(5)
$script:Timer.Add_Tick({
    if ($script:AutoRefreshCheckBox.IsChecked -ne $true) { return }
    if ([bool]$script:State.IsMeasuring) {
        Update-IntervalView
    } else {
        Refresh-Application
    }
})
$script:Window.Add_Closing({
    $script:WindowClosing = $true
    $script:Timer.Stop()
    Reset-TokenRaderComputeHost
})

Set-PricingTable
Refresh-Application
$script:Timer.Start()
[void]$script:Window.ShowDialog()
