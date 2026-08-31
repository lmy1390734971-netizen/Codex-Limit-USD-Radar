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
    AccountIdentity = ''
    LastSnapshot = $null
    ViewMode = 'session'
    UiState = 'Idle'
    MeasurementGeneration = [Int64]0
    RequestSequence = [Int64]0
    BaselineRequestId = [Int64]0
    EndCaptureRequestId = [Int64]0
    IntervalComputeRequestId = [Int64]0
    IsMeasuring = $false
    IntervalBaseline = $null
    IntervalResult = $null
    IntervalComputing = $false
    IntervalComputeStopping = $false
    IntervalActiveScanRateLimits = $false
    IntervalComputePending = $false
    IntervalComputePendingRequest = $null
    IntervalLastError = ''
    IntervalFinalRetry = $null
    IntervalCache = $null
    BackgroundJobs = @{}
    IndexReady = $false
    IndexCatalogAvailable = $false
    IndexSyncing = $false
    IndexSyncRequestId = [Int64]0
    UsageHistoryRefreshing = $false
    UsageHistoryStopping = $false
    UsageHistoryRequestId = [Int64]0
    UsageHistoryPending = $false
    UsageHistoryPendingRequest = $null
    ToolBackfillRunning = $false
    ToolBackfillRequestId = [Int64]0
    ToolBackfillCompleted = $false
    PendingMeasurementStart = $false
    RateLimits = $null
    RateLimitSnapshotCache = @{}
    QuotaEstimates = $null
    QuotaCalibrationMessage = '美元总额需通过一次使额度百分比上升的时间段测量进行反推。'
    Projects = @()
    ProjectCache = @{}
}

$script:WindowClosing = $false
$script:BackgroundPollTimer = $null

# Runs in a background runspace so interval computation never blocks the UI.
# The baseline and snapshot cache cross the runspace boundary through
# PowerShell serialization, which preserves DateTimeOffset, DateTime, Int64 and
# nested pscustomobject graphs (verified by tests/Run-Tests.ps1).
$script:IntervalComputeScript = {
    param(
        $Baseline,
        $Snapshots,
        $EndOffsets,
        $EndRevision,
        $EndedAt,
        [string]$PricingPath,
        [string]$ModulePath,
        [string]$SessionsRoot,
        [bool]$ScanRateLimits,
        [Threading.CancellationToken]$CancellationToken,
        [hashtable]$ProgressState
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module $ModulePath -Force
    $prices = Get-TokenRaderPrices -PricingPath $PricingPath
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '同步增量日志'
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    # The indexed core path owns interval parsing, end-boundary snapshots and
    # rate-limit selection.  Deliberately do not fall back to the old full-log
    # path here; a missing indexed function is a worker error reported
    # asynchronously to the UI.
    $indexedCommand = Get-Command -Name Get-TokenRaderIndexedIntervalResult -ErrorAction Stop
    $indexedParameters = @{
        Baseline = $Baseline
        PricingDocument = $prices
        BaselineSnapshots = $Snapshots
        EndOffsets = $EndOffsets
    }
    if ($null -ne $EndRevision -and $indexedCommand.Parameters.ContainsKey('EndRevision')) { $indexedParameters.EndRevision = $EndRevision }
    if ($null -ne $EndedAt -and $indexedCommand.Parameters.ContainsKey('EndedAt')) { $indexedParameters.EndedAt = $EndedAt }
    if ($indexedCommand.Parameters.ContainsKey('ScanRateLimits')) { $indexedParameters.ScanRateLimits = $ScanRateLimits }
    if ($indexedCommand.Parameters.ContainsKey('SessionsRoot')) { $indexedParameters.SessionsRoot = $SessionsRoot }
    if ($indexedCommand.Parameters.ContainsKey('CancellationToken')) { $indexedParameters.CancellationToken = $CancellationToken }
    if ($indexedCommand.Parameters.ContainsKey('ProgressState')) { $indexedParameters.ProgressState = $ProgressState }
    $result = & $indexedCommand.Name @indexedParameters
    $latest = if ($null -ne $result -and $null -ne $result.PSObject.Properties['EndRateLimits']) { $result.EndRateLimits }
              elseif ($null -ne $result -and $null -ne $result.PSObject.Properties['RateLimits']) { $result.RateLimits }
              else { $null }
    [pscustomobject]@{
        Result = $result
        LatestRateLimits = $latest
    }
}

# Measurement setup/teardown runs in a dedicated worker and requires the
# indexed snapshot contract. No WPF object or UI state crosses this boundary.
$script:MeasurementBaselineScript = {
    param(
        [string]$SessionsRoot,
        [string]$PricingPath,
        [string]$ModulePath,
        [string]$AccountIdentity
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module $ModulePath -Force
    $prices = Get-TokenRaderPrices -PricingPath $PricingPath
    [void](Get-Command -Name CaptureMeasurementBaseline -ErrorAction Stop)
    $baseline = CaptureMeasurementBaseline -SessionsRoot $SessionsRoot -PricingDocument $prices -AccountIdentity $AccountIdentity
    if ($null -eq $baseline) { throw '未能创建时间段测量基线。' }
    if ($null -eq $baseline.PSObject.Properties['StartOffsets']) {
        $offsets = @{}
        foreach ($entry in @($baseline.Files)) { $offsets[[string]$entry.FilePath] = [Int64]$entry.Length }
        Add-Member -InputObject $baseline -NotePropertyName StartOffsets -NotePropertyValue $offsets
    }
    if ($null -eq $baseline.PSObject.Properties['StartRateLimits']) {
        $startLimits = if ($null -ne $baseline.PSObject.Properties['RateLimits']) { $baseline.RateLimits } else { $null }
        Add-Member -InputObject $baseline -NotePropertyName StartRateLimits -NotePropertyValue $startLimits
    }
    if ($null -eq $baseline.PSObject.Properties['IndexRevision']) {
        Add-Member -InputObject $baseline -NotePropertyName IndexRevision -NotePropertyValue ''
    }
    return $baseline
}

$script:MeasurementEndScript = {
    param(
        $Baseline,
        [string]$SessionsRoot,
        [string]$ModulePath
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module $ModulePath -Force
    [void](Get-Command -Name CaptureMeasurementEnd -ErrorAction Stop)
    $ending = CaptureMeasurementEnd -Baseline $Baseline
    if ($null -eq $ending) { throw '未能冻结时间段结束位置。' }
    if ($null -eq $ending.PSObject.Properties['EndOffsets']) { throw '结束快照缺少 EndOffsets。' }
    if ($null -eq $ending.PSObject.Properties['EndRevision']) {
        Add-Member -InputObject $ending -NotePropertyName EndRevision -NotePropertyValue ([DateTimeOffset]::Now)
    }
    return $ending
}

$script:IndexSyncScript = {
    param(
        [string]$SessionsRoot,
        [string]$ModulePath,
        [bool]$FullReconcile,
        [hashtable]$ProgressState
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module $ModulePath -Force
    try {
        if ($null -ne $ProgressState) {
            $ProgressState.Stage = '打开索引'
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }
        Open-TokenRaderIndex -SessionsRoot $SessionsRoot | Out-Null
        if ($FullReconcile) {
            Update-TokenRaderIndex -SessionsRoot $SessionsRoot -FullReconcile -ProgressState $ProgressState | Out-Null
        } else {
            Update-TokenRaderIndex -SessionsRoot $SessionsRoot -ProgressState $ProgressState | Out-Null
        }
        [pscustomobject]@{
            IndexRevision = [Int64](GetIndexRevision -SessionsRoot $SessionsRoot)
            LatestRateLimits = Get-TokenRaderIndexedLatestRateLimits -SessionsRoot $SessionsRoot
        }
    } finally {
        Close-TokenRaderIndex -KeepWatcher
    }
}

$script:UsageHistoryScript = {
    param(
        [string]$SessionsRoot,
        [string]$PricingPath,
        [string]$ModulePath,
        [int]$DayOffset,
        [bool]$ForceRefresh,
        [bool]$PurgeExpired,
        [Threading.CancellationToken]$CancellationToken,
        [hashtable]$ProgressState
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module $ModulePath -Force
    try {
        $prices = Get-TokenRaderPrices -PricingPath $PricingPath
        Get-TokenRaderUsageHistoryWindow `
            -SessionsRoot $SessionsRoot `
            -PricingDocument $prices `
            -DayOffset $DayOffset `
            -ForceRefresh:$ForceRefresh `
            -PurgeExpired:$PurgeExpired `
            -CancellationToken $CancellationToken `
            -ProgressState $ProgressState
    } finally {
        Close-TokenRaderIndex -KeepWatcher
    }
}

$script:ToolBackfillScript = {
    param(
        [string]$SessionsRoot,
        [string]$ModulePath,
        [Threading.CancellationToken]$CancellationToken,
        [hashtable]$ProgressState
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module $ModulePath -Force
    try {
        Invoke-TokenRaderToolBackfill `
            -SessionsRoot $SessionsRoot `
            -Days 7 `
            -CancellationToken $CancellationToken `
            -ProgressState $ProgressState
    } finally {
        Close-TokenRaderIndex -KeepWatcher
    }
}

[xml]$xaml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'MainWindow.xaml')
$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    'AutoRefreshCheckBox', 'HistoryRangeComboBox', 'RefreshButton', 'RebuildIndexButton', 'PurgeOldIndexButton', 'AccountNameText', 'PlanText', 'AccountIdText', 'AccountHintText',
    'SessionCountText', 'OpenLogsButton', 'ProjectComboBox', 'ScopeComboBox', 'SessionListBox', 'SelectedSessionText', 'UpdatedText',
    'ScopeBadgeText', 'ModelMetricText', 'CachedMetricText', 'UncachedMetricText', 'OutputMetricText',
    'TotalMetricText', 'HitRateMetricText', 'HitRateProgress', 'UsdCostText', 'CostBreakdownText',
    'LongContextText', 'PricingVerifiedText', 'OpenPricingButton', 'InputPriceText', 'CachedPriceText',
    'OutputPriceText', 'FormulaText', 'PricingDataGrid', 'CaveatText', 'StatusText'
    'IntervalStatusText', 'IntervalTimeText', 'StartMeasureButton', 'StopMeasureButton', 'ViewIntervalButton'
    'FiveHourUsageText', 'FiveHourProgress', 'FiveHourDollarText', 'FiveHourResetText',
    'WeeklyUsageText', 'WeeklyProgress', 'WeeklyDollarText', 'WeeklyResetText', 'QuotaEstimateHintText',
    'UsageHistoryRangeComboBox', 'UsageHistoryTokenText', 'UsageHistoryUsdText', 'UsageHistoryWindowText',
    'UsageHistoryModelText', 'UsageHistoryStatusText', 'UsageHistoryModelGrid',
    'BackfillToolUsageButton', 'ToolCallCountText', 'InputImageCountText', 'GeneratedImageCountText',
    'ComputerScreenshotCountText', 'ToolUsageGrid', 'ToolUsageStatusText', 'UnpricedUsageText'
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

function Get-SelectedHistoryDays {
    $item = $script:HistoryRangeComboBox.SelectedItem
    if ($null -ne $item -and $null -ne $item.Tag) {
        $days = 0
        if ([int]::TryParse([string]$item.Tag, [ref]$days) -and $days -ge 0) { return $days }
    }
    return 1
}

function Get-SelectedUsageHistoryDayOffset {
    $item = $script:UsageHistoryRangeComboBox.SelectedItem
    if ($null -ne $item -and $null -ne $item.Tag) {
        $offset = 0
        if ([int]::TryParse([string]$item.Tag, [ref]$offset) -and $offset -ge 0 -and $offset -le 6) { return $offset }
    }
    return 0
}

function New-TokenRaderRequestId {
    $script:State.RequestSequence = [Int64]$script:State.RequestSequence + 1
    return [Int64]$script:State.RequestSequence
}

function Set-TokenRaderUiState {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Idle', 'Starting', 'Measuring', 'Stopping', 'ComputingFinal', 'Ready', 'Error', 'Closing')]
        [string]$NewState,
        [string]$StatusMessage = ''
    )

    $script:State.UiState = $NewState
    $script:State.IsMeasuring = ($NewState -eq 'Measuring')
    $canOperate = $NewState -in @('Idle', 'Ready', 'Error')
    $canViewInterval = $NewState -in @('Measuring', 'Stopping', 'ComputingFinal', 'Ready')

    # All WPF state changes are made on the dispatcher thread.  Keeping this
    # transition in one helper prevents a late worker callback from partially
    # re-enabling controls during finalization.
    $indexReady = [bool]$script:State.IndexReady -and -not [bool]$script:State.IndexSyncing
    # “开始计算”始终可以触发准备流程。若索引仍在同步，测量会在
    # 同步完成后自动继续，而不是让按钮永久灰掉。
    $script:StartMeasureButton.IsEnabled = $canOperate
    $script:StopMeasureButton.IsEnabled = ($NewState -in @('Starting', 'Measuring'))
    $script:StopMeasureButton.Content = if ($NewState -eq 'Starting') { '取消准备' } else { '结束计算' }
    $script:ViewIntervalButton.IsEnabled = ($canViewInterval -and $null -ne $script:State.IntervalBaseline)
    $script:RefreshButton.IsEnabled = ($canOperate -and -not [bool]$script:State.IndexSyncing)
    $script:RebuildIndexButton.IsEnabled = ($canOperate -and $indexReady)
    $script:PurgeOldIndexButton.IsEnabled = ($canOperate -and $indexReady)
    $script:BackfillToolUsageButton.IsEnabled = ($canOperate -and $indexReady -and
        -not [bool]$script:State.ToolBackfillRunning -and -not [bool]$script:State.ToolBackfillCompleted -and
        -not [bool]$script:State.UsageHistoryRefreshing -and -not [bool]$script:State.IndexSyncing)
    # 历史浏览范围不参与开始/结束时间段的计量边界，测量进行中也可切换。
    $script:HistoryRangeComboBox.IsEnabled = ($NewState -in @('Idle', 'Measuring', 'Ready', 'Error'))
    $script:UsageHistoryRangeComboBox.IsEnabled = ($NewState -in @('Idle', 'Measuring', 'Ready', 'Error'))
    $script:SessionListBox.IsEnabled = $canOperate
    $script:ProjectComboBox.IsEnabled = $canOperate
    $script:ScopeComboBox.IsEnabled = $canOperate

    switch ($NewState) {
        'Starting' {
            $script:IntervalStatusText.Text = '准备中'
            $script:IntervalStatusText.Foreground = [Windows.Media.Brushes]::Aquamarine
        }
        'Measuring' {
            $script:IntervalStatusText.Text = '计算中'
            $script:IntervalStatusText.Foreground = [Windows.Media.Brushes]::Aquamarine
        }
        'Stopping' {
            $script:IntervalStatusText.Text = '冻结中'
            $script:IntervalStatusText.Foreground = [Windows.Media.Brushes]::LightSkyBlue
        }
        'ComputingFinal' {
            $script:IntervalStatusText.Text = '结算中'
            $script:IntervalStatusText.Foreground = [Windows.Media.Brushes]::LightSkyBlue
        }
        'Ready' {
            $script:IntervalStatusText.Text = '已完成'
            $script:IntervalStatusText.Foreground = [Windows.Media.Brushes]::LightSkyBlue
        }
        'Error' {
            $script:IntervalStatusText.Text = '失败'
            $script:IntervalStatusText.Foreground = [Windows.Media.Brushes]::Salmon
        }
        'Closing' {
            $script:IntervalStatusText.Text = '正在关闭'
            $script:IntervalStatusText.Foreground = [Windows.Media.Brushes]::Gray
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($StatusMessage)) { $script:StatusText.Text = $StatusMessage }
}

function Get-TokenRaderCallbackContextValue {
    param($Context, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $Context) { return $Default }
    if ($Context -is [System.Collections.IDictionary]) {
        if ($Context.Contains($Name)) { return $Context[$Name] }
        return $Default
    }
    $property = $Context.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Get-TokenRaderBackgroundErrorMessage {
    param($Worker, $Exception)
    $messages = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Worker) {
        foreach ($record in @($Worker.Streams.Error)) {
            $candidate = if ($null -ne $record.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$record.ErrorDetails.Message)) {
                [string]$record.ErrorDetails.Message
            } elseif ($null -ne $record.Exception) { [string]$record.Exception.Message } else { [string]$record }
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $messages.Contains($candidate)) { [void]$messages.Add($candidate) }
        }
    }
    $current = $Exception
    while ($null -ne $current) {
        $candidate = [string]$current.Message
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            $candidate -notmatch 'EndInvoke' -and -not $messages.Contains($candidate)) {
            [void]$messages.Add($candidate)
        }
        $current = $current.InnerException
    }
    if ($messages.Count -eq 0 -and $null -ne $Exception) { return [string]$Exception.Message }
    if ($messages.Count -eq 0) { return '后台任务失败，但未返回详细错误。' }
    return ($messages -join '；')
}

function Reset-TokenRaderBackgroundFailureState {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:State.MeasurementGeneration = [Int64]$script:State.MeasurementGeneration + 1L
    $script:State.IndexSyncing = $false
    $script:State.IndexSyncRequestId = 0L
    $script:State.BaselineRequestId = 0L
    $script:State.EndCaptureRequestId = 0L
    $script:State.IntervalComputeRequestId = 0L
    $script:State.IntervalComputing = $false
    $script:State.IntervalComputeStopping = $false
    $script:State.IntervalActiveScanRateLimits = $false
    $script:State.IntervalComputePending = $false
    $script:State.IntervalComputePendingRequest = $null
    $script:State.UsageHistoryRefreshing = $false
    $script:State.UsageHistoryStopping = $false
    $script:State.UsageHistoryRequestId = 0L
    $script:State.UsageHistoryPending = $false
    $script:State.UsageHistoryPendingRequest = $null
    $script:State.ToolBackfillRunning = $false
    $script:State.ToolBackfillRequestId = 0L
    $script:State.PendingMeasurementStart = $false
    $script:State.QuotaEstimates = $null
    $script:State.QuotaCalibrationMessage = $Message
    try {
        Set-TokenRaderUiState -NewState 'Error' -StatusMessage $Message
    } catch {
        # State is already unlocked above. Preserve a retryable state even if
        # an individual WPF control failed while rendering the error.
        $script:State.UiState = 'Error'
        try { $script:StartMeasureButton.IsEnabled = $true } catch { }
        try { $script:StopMeasureButton.IsEnabled = $false } catch { }
    }
    try { Update-QuotaCards } catch { }
}

function Invoke-TokenRaderBackgroundHandler {
    param(
        [Parameter(Mandatory = $true)][string]$HandlerName,
        $Value,
        [Parameter(Mandatory = $true)]$Job
    )
    if ([string]::IsNullOrWhiteSpace($HandlerName)) { throw '后台任务缺少处理函数名称。' }
    & $HandlerName $Value ([Int64]$Job.Generation) ([Int64]$Job.RequestId) ([string]$Job.Kind) $Job.CallbackContext
}

function Request-TokenRaderBackgroundStop {
    param([Parameter(Mandatory = $true)]$Job)
    if ($null -ne $Job.StopAsyncResult) { return }
    $Job.CompletionDelivered = $true
    if ($null -ne $Job.CancellationSource) {
        try { $Job.CancellationSource.Cancel() } catch { }
    }
    try {
        # BeginStop is asynchronous: cancellation and timeout never block WPF.
        $Job.StopAsyncResult = $Job.PowerShell.BeginStop([System.AsyncCallback]$null, $null)
    } catch {
        try { $Job.PowerShell.Dispose() } catch { }
        try { if ($null -ne $Job.CancellationSource) { $Job.CancellationSource.Dispose() } } catch { }
        if ($script:State.BackgroundJobs.ContainsKey([Int64]$Job.RequestId)) {
            [void]$script:State.BackgroundJobs.Remove([Int64]$Job.RequestId)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Job.StopCompletionHandler)) {
            try { Invoke-TokenRaderBackgroundHandler -HandlerName ([string]$Job.StopCompletionHandler) -Value $null -Job $Job } catch { }
        }
    }
}

function Start-TokenRaderBackgroundPoller {
    if ($script:WindowClosing) { return }

    if ($null -eq $script:BackgroundPollTimer) {
        $script:BackgroundPollTimer = New-Object Windows.Threading.DispatcherTimer
        $script:BackgroundPollTimer.Interval = [TimeSpan]::FromMilliseconds(50)
        $script:BackgroundPollTimer.Add_Tick({
            if ($script:WindowClosing) {
                $script:BackgroundPollTimer.Stop()
                return
            }

            $now = [DateTimeOffset]::Now
            foreach ($requestId in @($script:State.BackgroundJobs.Keys)) {
                if (-not $script:State.BackgroundJobs.ContainsKey($requestId)) { continue }
                $job = $script:State.BackgroundJobs[$requestId]

                if ($null -ne $job.StopAsyncResult) {
                    if ($job.StopAsyncResult.IsCompleted) {
                        try { $job.PowerShell.EndStop($job.StopAsyncResult) } catch { }
                        try { $job.PowerShell.Dispose() } catch { }
                        try { if ($null -ne $job.CancellationSource) { $job.CancellationSource.Dispose() } } catch { }
                        [void]$script:State.BackgroundJobs.Remove($requestId)
                        if (-not [string]::IsNullOrWhiteSpace([string]$job.StopCompletionHandler)) {
                            try {
                                Invoke-TokenRaderBackgroundHandler -HandlerName ([string]$job.StopCompletionHandler) -Value $null -Job $job
                            } catch {
                                Reset-TokenRaderBackgroundFailureState -Message ('后台停止回调失败：' + $_.Exception.Message)
                            }
                        }
                    }
                    continue
                }

                if ($null -ne $job.AsyncResult -and $job.AsyncResult.IsCompleted) {
                    [void]$script:State.BackgroundJobs.Remove($requestId)
                    $payload = $null
                    $errorMessage = ''
                    try {
                        $output = @($job.PowerShell.EndInvoke($job.AsyncResult))
                        if ($output.Count -gt 0) { $payload = $output[0] }
                    } catch {
                        $errorMessage = Get-TokenRaderBackgroundErrorMessage -Worker $job.PowerShell -Exception $_.Exception
                    } finally {
                        try { $job.PowerShell.Dispose() } catch { }
                        try { if ($null -ne $job.CancellationSource) { $job.CancellationSource.Dispose() } } catch { }
                    }

                    if (-not [bool]$job.CompletionDelivered) {
                        $job.CompletionDelivered = $true
                        try {
                            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                                Invoke-TokenRaderBackgroundHandler -HandlerName ([string]$job.CompletionHandler) -Value $payload -Job $job
                            } else {
                                Invoke-TokenRaderBackgroundHandler -HandlerName ([string]$job.FailureHandler) -Value $errorMessage -Job $job
                            }
                        } catch {
                            Reset-TokenRaderBackgroundFailureState -Message ('后台任务回调失败：' + $_.Exception.Message)
                        }
                    }
                    continue
                }

                $elapsed = $now - [DateTimeOffset]$job.StartedAt
                if ([string]$job.Kind -eq 'IndexSync' -and $null -ne $job.ProgressState -and
                    ($now - [DateTimeOffset]$job.LastProgressUiAt).TotalMilliseconds -ge 500) {
                    $job.LastProgressUiAt = $now
                    $stage = [string](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'Stage' -Default '准备索引')
                    $processed = [int](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'ProcessedFiles' -Default 0)
                    $total = [int](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'TotalFiles' -Default 0)
                    $countText = if ($total -gt 0) { '，{0}/{1} 个文件' -f $processed, $total } else { '' }
                    $prefix = if ([bool](Get-TokenRaderCallbackContextValue -Context $job.CallbackContext -Name 'ColdStart' -Default $false)) { '首次建库' } else { '索引同步' }
                    $script:StatusText.Text = ('{0}：{1}{2}，已用 {3:0.0} 秒…' -f $prefix, $stage, $countText, $elapsed.TotalSeconds)
                }
                if ([string]$job.Kind -eq 'IntervalCompute' -and
                    [Int64]$script:State.IntervalComputeRequestId -eq [Int64]$job.RequestId -and
                    ($now - [DateTimeOffset]$job.LastProgressUiAt).TotalMilliseconds -ge 1000) {
                    $job.LastProgressUiAt = $now
                    $isFinalCompute = [bool](Get-TokenRaderCallbackContextValue -Context $job.CallbackContext -Name 'Final' -Default $false)
                    $stage = [string](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'Stage' -Default '计算时间段消耗')
                    $processedRows = [Int64](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'ProcessedRows' -Default 0L)
                    $slow = ([int]$job.SoftWarningSeconds -gt 0 -and $elapsed.TotalSeconds -ge [int]$job.SoftWarningSeconds)
                    $detail = if ($processedRows -gt 0) { '，已处理 {0:N0} 条记录' -f $processedRows } else { '' }
                    $script:StatusText.Text = if ($isFinalCompute) {
                        '正在后台结算冻结时间段：{0}{1}，计算用时 {2:0} 秒{3}' -f $stage, $detail, $elapsed.TotalSeconds, $(if ($slow) { '（数据量较大）' } else { '' })
                    } elseif ($null -ne $script:State.IntervalResult) {
                        '正在后台更新：{0}{1}；当前保留上一次结果，计算用时 {2:0} 秒{3}' -f $stage, $detail, $elapsed.TotalSeconds, $(if ($slow) { '（数据量较大）' } else { '' })
                    } else {
                        '正在后台计算：{0}{1}，计算用时 {2:0} 秒{3}' -f $stage, $detail, $elapsed.TotalSeconds, $(if ($slow) { '（数据量较大）' } else { '' })
                    }
                }
                if ([string]$job.Kind -eq 'UsageHistory' -and
                    [Int64]$script:State.UsageHistoryRequestId -eq [Int64]$job.RequestId -and
                    ($now - [DateTimeOffset]$job.LastProgressUiAt).TotalMilliseconds -ge 1000) {
                    $job.LastProgressUiAt = $now
                    $stage = [string](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'Stage' -Default '读取24小时磁盘用量')
                    $processedRows = [Int64](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'ProcessedRows' -Default 0L)
                    $detail = if ($processedRows -gt 0) { ' · {0:N0} 条记录' -f $processedRows } else { '' }
                    $script:UsageHistoryStatusText.Text = ('{0}{1} · {2:0} 秒' -f $stage, $detail, $elapsed.TotalSeconds)
                }
                if ([string]$job.Kind -eq 'ToolBackfill' -and
                    [Int64]$script:State.ToolBackfillRequestId -eq [Int64]$job.RequestId -and
                    ($now - [DateTimeOffset]$job.LastProgressUiAt).TotalMilliseconds -ge 500) {
                    $job.LastProgressUiAt = $now
                    $stage = [string](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'Stage' -Default '回填工具元数据')
                    $processed = [int](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'ProcessedFiles' -Default 0)
                    $total = [int](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'TotalFiles' -Default 0)
                    $detected = [Int64](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'DetectedRecords' -Default 0L)
                    $script:ToolUsageStatusText.Text = ('{0} · {1}/{2} 个文件 · {3:N0} 条元数据 · {4:0} 秒' -f
                        $stage, $processed, $total, $detected, $elapsed.TotalSeconds)
                }

                $totalTimedOut = ([int]$job.TimeoutSeconds -gt 0 -and $elapsed.TotalSeconds -ge [int]$job.TimeoutSeconds)
                $lastProgressAt = [DateTimeOffset]$job.StartedAt
                if ($null -ne $job.ProgressState) {
                    try { $lastProgressAt = [DateTimeOffset](Get-TokenRaderCallbackContextValue -Context $job.ProgressState -Name 'LastProgressAt' -Default $job.StartedAt) } catch { }
                }
                $stalled = ([int]$job.StallTimeoutSeconds -gt 0 -and ($now - $lastProgressAt).TotalSeconds -ge [int]$job.StallTimeoutSeconds)
                if (($totalTimedOut -or $stalled) -and -not [bool]$job.CompletionDelivered) {
                    $job.CompletionDelivered = $true
                    if ($job.CallbackContext -is [System.Collections.IDictionary]) { $job.CallbackContext['StopPending'] = $true }
                    $timeoutMessage = if ($stalled) {
                        '后台任务长时间没有进度，已停止并解锁界面。'
                    } else { '后台任务超过限定时间，已停止并解锁界面。' }
                    try {
                        Invoke-TokenRaderBackgroundHandler -HandlerName ([string]$job.FailureHandler) -Value $timeoutMessage -Job $job
                    } catch {
                        Reset-TokenRaderBackgroundFailureState -Message ('后台任务超时处理失败：' + $_.Exception.Message)
                    }
                    Request-TokenRaderBackgroundStop -Job $job
                }
            }

            if ($script:State.BackgroundJobs.Count -eq 0) { $script:BackgroundPollTimer.Stop() }
        })
    }

    if (-not $script:BackgroundPollTimer.IsEnabled) { $script:BackgroundPollTimer.Start() }
}

function Start-TokenRaderBackgroundJob {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [hashtable]$Parameters = @{},
        [Parameter(Mandatory = $true)][string]$Kind,
        [Int64]$Generation = 0,
        [Parameter(Mandatory = $true)][Int64]$RequestId,
        [Parameter(Mandatory = $true)][string]$CompletionHandler,
        [Parameter(Mandatory = $true)][string]$FailureHandler,
        $CallbackContext = $null,
        [int]$TimeoutSeconds = 0,
        [int]$SoftWarningSeconds = 0,
        [int]$StallTimeoutSeconds = 0,
        [hashtable]$ProgressState = $null,
        [Threading.CancellationTokenSource]$CancellationSource = $null,
        [string]$StopCompletionHandler = ''
    )

    if ($script:WindowClosing) { return $false }
    $worker = [PowerShell]::Create()
    try {
        [void]$worker.AddScript($ScriptBlock.ToString())
        foreach ($key in @($Parameters.Keys)) { [void]$worker.AddParameter([string]$key, $Parameters[$key]) }
        $asyncResult = $worker.BeginInvoke()
        $startedAt = [DateTimeOffset]::Now
        $script:State.BackgroundJobs[$RequestId] = [pscustomobject]@{
            Kind = $Kind
            Generation = $Generation
            RequestId = $RequestId
            PowerShell = $worker
            AsyncResult = $asyncResult
            CompletionHandler = $CompletionHandler
            FailureHandler = $FailureHandler
            CallbackContext = $CallbackContext
            StartedAt = $startedAt
            TimeoutSeconds = $TimeoutSeconds
            SoftWarningSeconds = $SoftWarningSeconds
            StallTimeoutSeconds = $StallTimeoutSeconds
            ProgressState = $ProgressState
            CancellationSource = $CancellationSource
            StopCompletionHandler = $StopCompletionHandler
            CompletionDelivered = $false
            StopAsyncResult = $null
            LastProgressUiAt = $startedAt
        }
        Start-TokenRaderBackgroundPoller
        return $true
    } catch {
        try { $worker.Dispose() } catch { }
        try { if ($null -ne $CancellationSource) { $CancellationSource.Dispose() } } catch { }
        if ($script:State.BackgroundJobs.ContainsKey($RequestId)) { [void]$script:State.BackgroundJobs.Remove($RequestId) }
        $failedJob = [pscustomobject]@{
            Generation = $Generation; RequestId = $RequestId; Kind = $Kind; CallbackContext = $CallbackContext
        }
        try {
            Invoke-TokenRaderBackgroundHandler -HandlerName $FailureHandler -Value $_.Exception.Message -Job $failedJob
        } catch {
            Reset-TokenRaderBackgroundFailureState -Message ('后台任务启动失败：' + $_.Exception.Message)
        }
        return $false
    }
}

function Stop-TokenRaderBackgroundJobs {
    if ($null -ne $script:BackgroundPollTimer) {
        $script:BackgroundPollTimer.Stop()
    }
    foreach ($job in @($script:State.BackgroundJobs.Values)) {
        try { if ($null -ne $job.CancellationSource) { $job.CancellationSource.Cancel() } } catch { }
        try { $job.PowerShell.Stop() } catch { }
        try { $job.PowerShell.Dispose() } catch { }
        try { if ($null -ne $job.CancellationSource) { $job.CancellationSource.Dispose() } } catch { }
    }
    $script:State.BackgroundJobs.Clear()
}

function Complete-TokenRaderMeasurementBaselineJob {
    param($Baseline, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    Complete-TokenRaderMeasurementBaseline -Baseline $Baseline -Generation $Generation -RequestId $RequestId
}

function Fail-TokenRaderMeasurementBaselineJob {
    param($ErrorMessage, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    Fail-TokenRaderMeasurementRequest -Generation $Generation -RequestId $RequestId -Final $false `
        -Message ('开始计算准备失败：' + [string]$ErrorMessage)
}

function Complete-TokenRaderMeasurementEndJob {
    param($Ending, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    Complete-TokenRaderMeasurementEnd -Ending $Ending -Generation $Generation -RequestId $RequestId
}

function Fail-TokenRaderMeasurementEndJob {
    param($ErrorMessage, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    Fail-TokenRaderMeasurementRequest -Generation $Generation -RequestId $RequestId -Final $true `
        -Message ('结束计算冻结失败：' + [string]$ErrorMessage)
}

function Complete-TokenRaderIndexSyncJob {
    param($Payload, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    if ($script:WindowClosing -or [Int64]$script:State.IndexSyncRequestId -ne $RequestId) { return }
    $startup = [bool](Get-TokenRaderCallbackContextValue -Context $Context -Name 'Startup' -Default $false)
    $script:State.IndexSyncing = $false
    $script:State.IndexSyncRequestId = 0L
    $script:State.IndexReady = $true
    $script:State.IndexCatalogAvailable = $true
    $script:State.ProjectCache = @{}
    $script:State.RateLimitSnapshotCache = @{}
    Update-TokenRaderToolBackfillButton
    if ($null -ne $Payload -and $null -ne $Payload.PSObject.Properties['LatestRateLimits']) {
        Merge-LatestRateLimits -Candidate $Payload.LatestRateLimits
    }
    if ([bool]$script:State.PendingMeasurementStart -and [string]$script:State.UiState -eq 'Starting' -and
        [Int64]$script:State.BaselineRequestId -gt 0) {
        $script:State.PendingMeasurementStart = $false
        Set-TokenRaderUiState -NewState 'Starting' -StatusMessage '索引已就绪，正在后台冻结开始位置…'
        Start-TokenRaderMeasurementBaselineAsync `
            -Generation ([Int64]$script:State.MeasurementGeneration) `
            -RequestId ([Int64]$script:State.BaselineRequestId)
    } else {
        Refresh-Application
        Set-TokenRaderUiState -NewState ([string]$script:State.UiState) -StatusMessage $(if ($startup) {
            '后台索引准备完成，可以开始计算。'
        } else { '新增或修改日志已更新。' })
        Start-TokenRaderUsageHistoryRefresh
    }
}

function Fail-TokenRaderIndexSyncJob {
    param($ErrorMessage, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    if ($script:WindowClosing -or [Int64]$script:State.IndexSyncRequestId -ne $RequestId) { return }
    $coldStart = [bool](Get-TokenRaderCallbackContextValue -Context $Context -Name 'ColdStart' -Default $false)
    $script:State.IndexSyncing = $false
    $script:State.IndexSyncRequestId = 0L
    if ($coldStart) { $script:State.IndexReady = $false }
    $script:State.PendingMeasurementStart = $false
    $script:State.BaselineRequestId = 0L
    $script:State.QuotaEstimates = $null
    $script:State.QuotaCalibrationMessage = [string]$ErrorMessage
    Set-TokenRaderUiState -NewState 'Error' -StatusMessage ('后台索引同步失败：' + [string]$ErrorMessage)
    Update-QuotaCards
}

function Show-TokenRaderUsageHistoryResult {
    param([Parameter(Mandatory = $true)]$Result)
    $start = ([DateTimeOffset]$Result.WindowStart).ToLocalTime()
    $end = ([DateTimeOffset]$Result.WindowEnd).ToLocalTime()
    $script:UsageHistoryTokenText.Text = Format-TokenRaderNumber ([Int64]$Result.Usage.Total)
    $costText = Format-TokenRaderUsd ([double]$Result.TotalCost)
    $script:UsageHistoryUsdText.Text = if ([bool]$Result.PricingComplete) { $costText } else { $costText + '（部分）' }
    $script:UsageHistoryWindowText.Text = ('{0:MM-dd HH:mm} — {1:MM-dd HH:mm}' -f $start, $end)
    $script:UsageHistoryModelText.Text = ('{0} · {1:N0} 次调用' -f [string]$Result.ModelDisplay, [Int64]$Result.CountedEvents)
    $sourceLabel = if ([bool]$Result.FromCache) { '读取磁盘缓存' } else { '已更新磁盘缓存' }
    $script:UsageHistoryStatusText.Text = if ([bool]$Result.PricingComplete) {
        $sourceLabel
    } else { $sourceLabel + ' · 存在未知模型价格' }
    $rows = foreach ($modelResult in @($Result.ModelBreakdown | Sort-Object Model)) {
        [pscustomobject]@{
            Model = [string]$modelResult.Model
            Cached = Format-TokenRaderNumber ([Int64]$modelResult.Usage.Cached)
            Uncached = Format-TokenRaderNumber ([Int64]$modelResult.Usage.Uncached)
            Output = Format-TokenRaderNumber ([Int64]$modelResult.Usage.Output)
            Total = Format-TokenRaderNumber ([Int64]$modelResult.Usage.Total)
            Cost = $(if ([bool]$modelResult.PricingComplete) {
                Format-TokenRaderUsd ([double]$modelResult.TotalCost)
            } else { (Format-TokenRaderUsd ([double]$modelResult.TotalCost)) + '（部分）' })
        }
    }
    $rows = @($rows) + @([pscustomobject]@{
        Model = '总计'
        Cached = Format-TokenRaderNumber ([Int64]$Result.Usage.Cached)
        Uncached = Format-TokenRaderNumber ([Int64]$Result.Usage.Uncached)
        Output = Format-TokenRaderNumber ([Int64]$Result.Usage.Output)
        Total = Format-TokenRaderNumber ([Int64]$Result.Usage.Total)
        Cost = $(if ([bool]$Result.PricingComplete) { Format-TokenRaderUsd ([double]$Result.TotalCost) } else { (Format-TokenRaderUsd ([double]$Result.TotalCost)) + '（部分）' })
    })
    $script:UsageHistoryModelGrid.ItemsSource = $null
    $script:UsageHistoryModelGrid.ItemsSource = $rows

    $toolUsage = if ($null -ne $Result.PSObject.Properties['ToolUsage']) { $Result.ToolUsage } else { $null }
    $script:ToolCallCountText.Text = Format-TokenRaderNumber $(if ($null -ne $toolUsage) { [Int64]$toolUsage.TotalToolCalls } else { 0L })
    $script:InputImageCountText.Text = Format-TokenRaderNumber $(if ($null -ne $toolUsage) { [Int64]$toolUsage.InputImages } else { 0L })
    $script:GeneratedImageCountText.Text = Format-TokenRaderNumber $(if ($null -ne $toolUsage) { [Int64]$toolUsage.GeneratedImages } else { 0L })
    $script:ComputerScreenshotCountText.Text = Format-TokenRaderNumber $(if ($null -ne $toolUsage) { [Int64]$toolUsage.ComputerScreenshots } else { 0L })
    $script:UnpricedUsageText.Text = ('未单独计价：工具 {0:N0} 次 · 输入图片 {1:N0} 张 · 生成图片 {2:N0} 张' -f
        $(if ($null -ne $toolUsage) { [Int64]$toolUsage.TotalToolCalls } else { 0L }),
        $(if ($null -ne $toolUsage) { [Int64]$toolUsage.InputImages } else { 0L }),
        $(if ($null -ne $toolUsage) { [Int64]$toolUsage.GeneratedImages } else { 0L }))
    $toolRows = foreach ($item in @($(if ($null -ne $toolUsage) { $toolUsage.Items } else { @() }))) {
        $kindLabel = switch ([string]$item.EventKind) {
            'tool_call' { '工具'; break }
            'image_generation' { '图片生成'; break }
            'image_input' { '输入图片'; break }
            'computer_screenshot' { '电脑截图'; break }
            default { [string]$item.EventKind }
        }
        [pscustomobject]@{
            Kind = $kindLabel
            Tool = [string]$item.ToolName
            Calls = Format-TokenRaderNumber ([Int64]$item.Calls)
            Completed = Format-TokenRaderNumber ([Int64]$item.Completed)
            Failed = Format-TokenRaderNumber ([Int64]$item.Failed)
        }
    }
    $script:ToolUsageGrid.ItemsSource = $null
    $script:ToolUsageGrid.ItemsSource = @($toolRows)
    if (-not [bool]$script:State.ToolBackfillCompleted) {
        $script:ToolUsageStatusText.Text = '新日志已增量识别；旧日志需点击一次“回填最近7天工具记录”。'
    } elseif ($null -ne $toolUsage) {
        $script:ToolUsageStatusText.Text = ('本窗口工具调用 {0:N0} 次，完成 {1:N0}、失败 {2:N0}；仅统计本地可观察元数据，不并入美元总额。' -f
            [Int64]$toolUsage.TotalToolCalls, [Int64]$toolUsage.CompletedToolCalls, [Int64]$toolUsage.FailedToolCalls)
    }
}

function Start-TokenRaderPendingUsageHistory {
    if (-not [bool]$script:State.UsageHistoryPending -or $null -eq $script:State.UsageHistoryPendingRequest) { return $false }
    $pending = $script:State.UsageHistoryPendingRequest
    $script:State.UsageHistoryPending = $false
    $script:State.UsageHistoryPendingRequest = $null
    Start-TokenRaderUsageHistoryRefresh `
        -DayOffset ([int]$pending.DayOffset) `
        -ForceRefresh ([bool]$pending.ForceRefresh) `
        -PurgeExpired ([bool]$pending.PurgeExpired)
    return $true
}

function Complete-TokenRaderUsageHistoryJob {
    param($Payload, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    if ($script:WindowClosing -or [Int64]$script:State.UsageHistoryRequestId -ne $RequestId) { return }
    $script:State.UsageHistoryRequestId = 0L
    $script:State.UsageHistoryRefreshing = $false
    $script:State.UsageHistoryStopping = $false
    if ($null -ne $Payload) { Show-TokenRaderUsageHistoryResult -Result $Payload }
    Update-TokenRaderToolBackfillButton
    [void](Start-TokenRaderPendingUsageHistory)
}

function Fail-TokenRaderUsageHistoryJob {
    param($ErrorMessage, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    if ($script:WindowClosing -or [Int64]$script:State.UsageHistoryRequestId -ne $RequestId) { return }
    $stopPending = [bool](Get-TokenRaderCallbackContextValue -Context $Context -Name 'StopPending' -Default $false)
    $script:UsageHistoryStatusText.Text = '汇总失败：' + [string]$ErrorMessage
    if ($stopPending) {
        $script:State.UsageHistoryStopping = $true
        return
    }
    $script:State.UsageHistoryRequestId = 0L
    $script:State.UsageHistoryRefreshing = $false
    $script:State.UsageHistoryStopping = $false
    Update-TokenRaderToolBackfillButton
    [void](Start-TokenRaderPendingUsageHistory)
}

function Complete-TokenRaderUsageHistoryStopJob {
    param($Payload, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    if ($script:WindowClosing -or [Int64]$script:State.UsageHistoryRequestId -ne $RequestId) { return }
    $script:State.UsageHistoryRequestId = 0L
    $script:State.UsageHistoryRefreshing = $false
    $script:State.UsageHistoryStopping = $false
    Update-TokenRaderToolBackfillButton
    [void](Start-TokenRaderPendingUsageHistory)
}

function Start-TokenRaderUsageHistoryRefresh {
    param(
        [int]$DayOffset = -1,
        [bool]$ForceRefresh = $false,
        [bool]$PurgeExpired = $false
    )
    if ($script:WindowClosing -or -not [bool]$script:State.IndexCatalogAvailable) { return }
    $selectedOffset = if ($DayOffset -ge 0) { $DayOffset } else { Get-SelectedUsageHistoryDayOffset }
    if ([bool]$script:State.UsageHistoryRefreshing) {
        $previous = $script:State.UsageHistoryPendingRequest
        $script:State.UsageHistoryPending = $true
        $script:State.UsageHistoryPendingRequest = [pscustomobject]@{
            DayOffset = $selectedOffset
            ForceRefresh = ($ForceRefresh -or ($null -ne $previous -and [bool]$previous.ForceRefresh))
            PurgeExpired = ($PurgeExpired -or ($null -ne $previous -and [bool]$previous.PurgeExpired))
        }
        return
    }

    $requestId = New-TokenRaderRequestId
    $script:State.UsageHistoryRequestId = $requestId
    $script:State.UsageHistoryRefreshing = $true
    $script:State.UsageHistoryStopping = $false
    $script:BackfillToolUsageButton.IsEnabled = $false
    $script:UsageHistoryStatusText.Text = '正在读取磁盘汇总…'
    $progressState = [hashtable]::Synchronized(@{
        Stage = '打开24小时磁盘数据'
        ProcessedRows = [Int64]0
        LastProgressAt = [DateTimeOffset]::Now
    })
    $cancellationSource = [Threading.CancellationTokenSource]::new()
    [void](Start-TokenRaderBackgroundJob `
        -ScriptBlock $script:UsageHistoryScript `
        -Parameters @{
            SessionsRoot = $script:Paths.SessionsRoot
            PricingPath = $script:Paths.PricingPath
            ModulePath = (Join-Path $PSScriptRoot 'TokenRader.Core.psm1')
            DayOffset = $selectedOffset
            ForceRefresh = $ForceRefresh
            PurgeExpired = $PurgeExpired
            CancellationToken = $cancellationSource.Token
            ProgressState = $progressState
        } `
        -Kind 'UsageHistory' `
        -RequestId $requestId `
        -CompletionHandler 'Complete-TokenRaderUsageHistoryJob' `
        -FailureHandler 'Fail-TokenRaderUsageHistoryJob' `
        -CallbackContext @{} `
        -TimeoutSeconds 60 `
        -SoftWarningSeconds 3 `
        -ProgressState $progressState `
        -CancellationSource $cancellationSource `
        -StopCompletionHandler 'Complete-TokenRaderUsageHistoryStopJob')
}

function Update-TokenRaderToolBackfillButton {
    if (-not [bool]$script:State.IndexCatalogAvailable) { return }
    try {
        $status = Get-TokenRaderToolBackfillStatus -SessionsRoot $script:Paths.SessionsRoot
        $script:State.ToolBackfillCompleted = [bool]$status.Completed
    } catch {
        $script:State.ToolBackfillCompleted = $false
    }
    $script:BackfillToolUsageButton.Content = if ([bool]$script:State.ToolBackfillCompleted) {
        '最近7天工具记录已回填'
    } else { '回填最近7天工具记录' }
    $canOperate = [string]$script:State.UiState -in @('Idle', 'Ready', 'Error')
    $script:BackfillToolUsageButton.IsEnabled = ($canOperate -and [bool]$script:State.IndexReady -and
        -not [bool]$script:State.ToolBackfillRunning -and -not [bool]$script:State.ToolBackfillCompleted -and
        -not [bool]$script:State.UsageHistoryRefreshing -and -not [bool]$script:State.IndexSyncing)
}

function Complete-TokenRaderToolBackfillJob {
    param($Payload, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    if ($script:WindowClosing -or [Int64]$script:State.ToolBackfillRequestId -ne $RequestId) { return }
    $script:State.ToolBackfillRequestId = 0L
    $script:State.ToolBackfillRunning = $false
    $script:State.ToolBackfillCompleted = $true
    Set-TokenRaderUiState -NewState ([string]$script:State.UiState)
    $script:BackfillToolUsageButton.Content = '最近7天工具记录已回填'
    $script:BackfillToolUsageButton.IsEnabled = $false
    if ($null -ne $Payload -and [bool]$Payload.AlreadyCompleted) {
        $script:ToolUsageStatusText.Text = '最近7天工具元数据此前已经回填。'
    } elseif ($null -ne $Payload) {
        $script:ToolUsageStatusText.Text = ('回填完成：扫描 {0}/{1} 个文件，识别 {2:N0} 条工具/图片元数据。' -f
            [int]$Payload.ProcessedFiles, [int]$Payload.CandidateFiles, [Int64]$Payload.DetectedRecords)
    }
    Start-TokenRaderUsageHistoryRefresh -ForceRefresh $true
}

function Fail-TokenRaderToolBackfillJob {
    param($ErrorMessage, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    if ($script:WindowClosing -or [Int64]$script:State.ToolBackfillRequestId -ne $RequestId) { return }
    $stopPending = [bool](Get-TokenRaderCallbackContextValue -Context $Context -Name 'StopPending' -Default $false)
    $script:ToolUsageStatusText.Text = '工具元数据回填失败：' + [string]$ErrorMessage
    if ($stopPending) { return }
    $script:State.ToolBackfillRequestId = 0L
    $script:State.ToolBackfillRunning = $false
    Set-TokenRaderUiState -NewState ([string]$script:State.UiState)
    Update-TokenRaderToolBackfillButton
}

function Complete-TokenRaderToolBackfillStopJob {
    param($Payload, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    if ($script:WindowClosing -or [Int64]$script:State.ToolBackfillRequestId -ne $RequestId) { return }
    $script:State.ToolBackfillRequestId = 0L
    $script:State.ToolBackfillRunning = $false
    Set-TokenRaderUiState -NewState ([string]$script:State.UiState)
    Update-TokenRaderToolBackfillButton
}

function Start-TokenRaderToolBackfill {
    if ($script:WindowClosing -or [bool]$script:State.ToolBackfillRunning -or
        [bool]$script:State.ToolBackfillCompleted -or -not [bool]$script:State.IndexReady -or
        [bool]$script:State.UsageHistoryRefreshing -or [bool]$script:State.IndexSyncing -or
        [string]$script:State.UiState -notin @('Idle', 'Ready', 'Error')) { return }
    $requestId = New-TokenRaderRequestId
    $script:State.ToolBackfillRequestId = $requestId
    $script:State.ToolBackfillRunning = $true
    $script:BackfillToolUsageButton.IsEnabled = $false
    $script:StartMeasureButton.IsEnabled = $false
    $script:RefreshButton.IsEnabled = $false
    $script:RebuildIndexButton.IsEnabled = $false
    $script:PurgeOldIndexButton.IsEnabled = $false
    $script:UsageHistoryRangeComboBox.IsEnabled = $false
    $script:ToolUsageStatusText.Text = '正在后台回填最近7天工具元数据；不会保存参数、图片或输出正文…'
    $progressState = [hashtable]::Synchronized(@{
        Stage = '准备最近7天工具元数据回填'
        ProcessedFiles = 0
        TotalFiles = 0
        DetectedRecords = [Int64]0
        LastProgressAt = [DateTimeOffset]::Now
    })
    $cancellationSource = [Threading.CancellationTokenSource]::new()
    [void](Start-TokenRaderBackgroundJob `
        -ScriptBlock $script:ToolBackfillScript `
        -Parameters @{
            SessionsRoot = $script:Paths.SessionsRoot
            ModulePath = (Join-Path $PSScriptRoot 'TokenRader.Core.psm1')
            CancellationToken = $cancellationSource.Token
            ProgressState = $progressState
        } `
        -Kind 'ToolBackfill' `
        -RequestId $requestId `
        -CompletionHandler 'Complete-TokenRaderToolBackfillJob' `
        -FailureHandler 'Fail-TokenRaderToolBackfillJob' `
        -CallbackContext @{} `
        -StallTimeoutSeconds 300 `
        -ProgressState $progressState `
        -CancellationSource $cancellationSource `
        -StopCompletionHandler 'Complete-TokenRaderToolBackfillStopJob')
}

function Complete-TokenRaderIntervalComputeJob {
    param($Payload, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    $baselineStartedAt = [DateTimeOffset](Get-TokenRaderCallbackContextValue -Context $Context -Name 'BaselineStartedAt')
    $final = [bool](Get-TokenRaderCallbackContextValue -Context $Context -Name 'Final' -Default $false)
    $scanRateLimits = [bool](Get-TokenRaderCallbackContextValue -Context $Context -Name 'ScanRateLimits' -Default $true)
    Complete-TokenRaderIntervalCompute -BaselineStartedAt $baselineStartedAt -Payload $Payload -Final $final `
        -ScanRateLimits $scanRateLimits -Generation $Generation -RequestId $RequestId
}

function New-TokenRaderFinalRetryState {
    param([Int64]$Generation, $Context)
    return [pscustomobject]@{
        Generation = $Generation
        BaselineStartedAt = Get-TokenRaderCallbackContextValue -Context $Context -Name 'BaselineStartedAt'
        EndOffsets = Get-TokenRaderCallbackContextValue -Context $Context -Name 'EndOffsets'
        EndRevision = Get-TokenRaderCallbackContextValue -Context $Context -Name 'EndRevision'
        EndedAt = Get-TokenRaderCallbackContextValue -Context $Context -Name 'EndedAt'
        ScanRateLimits = [bool](Get-TokenRaderCallbackContextValue -Context $Context -Name 'ScanRateLimits' -Default $true)
    }
}

function Start-TokenRaderPendingIntervalCompute {
    param($PendingRequest, [Int64]$Generation)
    if ($null -eq $PendingRequest -or [Int64]$PendingRequest.Generation -ne $Generation -or
        $null -eq $script:State.IntervalBaseline) { return $false }
    if ([bool]$PendingRequest.Final) {
        Set-TokenRaderUiState -NewState 'ComputingFinal' -StatusMessage '实时预览已停止，正在使用冻结边界完成最终结算…'
    } else {
        $script:StatusText.Text = '前一后台请求已结束，正在执行合并后的手动刷新…'
    }
    $pendingEndOffsets = if ($null -eq $PendingRequest.EndOffsets) {
        $null
    } else {
        ConvertTo-TokenRaderOffsetHashtable -Value $PendingRequest.EndOffsets
    }
    Start-TokenRaderIntervalComputeAsync `
        -Baseline $script:State.IntervalBaseline `
        -EndOffsets $pendingEndOffsets `
        -EndRevision $PendingRequest.EndRevision `
        -EndedAt $PendingRequest.EndedAt `
        -Final ([bool]$PendingRequest.Final) `
        -ScanRateLimits ([bool]$PendingRequest.ScanRateLimits) `
        -Generation $Generation `
        -RequestId ([Int64]$PendingRequest.RequestId)
    return $true
}

function Fail-TokenRaderIntervalComputeJob {
    param($ErrorMessage, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    $final = [bool](Get-TokenRaderCallbackContextValue -Context $Context -Name 'Final' -Default $false)
    if ($script:WindowClosing -or [Int64]$script:State.MeasurementGeneration -ne $Generation -or
        [Int64]$script:State.IntervalComputeRequestId -ne $RequestId) { return }

    $message = '时间段后台计算失败：' + [string]$ErrorMessage
    $stopPending = [bool](Get-TokenRaderCallbackContextValue -Context $Context -Name 'StopPending' -Default $false)
    $script:State.IntervalLastError = $message

    if ($final) {
        # EndOffsets and EndRevision are immutable. Preserve them so a timeout
        # or transient SQLite lock can be retried without losing the completed
        # measurement or accidentally including later log writes.
        $script:State.IntervalFinalRetry = New-TokenRaderFinalRetryState -Generation $Generation -Context $Context
    }

    if ($stopPending) {
        # Do not unlock or launch a replacement until CancellationToken and
        # BeginStop have both completed. This prevents a timed-out native query
        # from becoming a hidden CPU-consuming zombie beside the next request.
        $script:State.IntervalComputeStopping = $true
        $script:StatusText.Text = if ($final) {
            $message + ' 正在取消过慢的最终查询；冻结边界已保留…'
        } elseif ([string]$script:State.UiState -eq 'Stopping') {
            $message + ' 正在取消实时预览；结束边界仍在冻结…'
        } else {
            $message + ' 正在取消过慢查询；测量仍然有效…'
        }
        return
    }

    $pendingRequest = if ([bool]$script:State.IntervalComputePending) { $script:State.IntervalComputePendingRequest } else { $null }
    $script:State.IntervalComputeRequestId = 0L
    $script:State.IntervalComputing = $false
    $script:State.IntervalComputeStopping = $false
    $script:State.IntervalActiveScanRateLimits = $false
    $script:State.IntervalComputePending = $false
    $script:State.IntervalComputePendingRequest = $null

    if ($final) {
        Set-TokenRaderUiState -NewState 'Ready' -StatusMessage ($message + ' 已保留冻结边界；点击“查看结果”可重试。')
        return
    }

    # A live preview is advisory. Its failure must not invalidate the frozen
    # baseline, the current measurement, or the last successfully shown result.
    if (Start-TokenRaderPendingIntervalCompute -PendingRequest $pendingRequest -Generation $Generation) { return }

    if ([string]$script:State.UiState -eq 'Measuring') {
        Set-TokenRaderUiState -NewState 'Measuring' -StatusMessage ($message + ' 测量仍然有效，可稍后再次查看。')
    } elseif ([string]$script:State.UiState -eq 'Stopping') {
        $script:StatusText.Text = $message + ' 正在继续冻结结束边界…'
    }
}

function Complete-TokenRaderIntervalStopJob {
    param($Payload, [Int64]$Generation, [Int64]$RequestId, [string]$Kind, $Context)
    if ($script:WindowClosing -or [Int64]$script:State.MeasurementGeneration -ne $Generation -or
        [Int64]$script:State.IntervalComputeRequestId -ne $RequestId) { return }

    $final = [bool](Get-TokenRaderCallbackContextValue -Context $Context -Name 'Final' -Default $false)
    $pendingRequest = if ([bool]$script:State.IntervalComputePending) { $script:State.IntervalComputePendingRequest } else { $null }
    $message = [string]$script:State.IntervalLastError
    $script:State.IntervalComputeRequestId = 0L
    $script:State.IntervalComputing = $false
    $script:State.IntervalComputeStopping = $false
    $script:State.IntervalActiveScanRateLimits = $false
    $script:State.IntervalComputePending = $false
    $script:State.IntervalComputePendingRequest = $null

    if (Start-TokenRaderPendingIntervalCompute -PendingRequest $pendingRequest -Generation $Generation) { return }
    if ($final) {
        Set-TokenRaderUiState -NewState 'Ready' -StatusMessage ($message + ' 已停止过慢查询并保留冻结边界；点击“查看结果”可重试。')
    } elseif ([string]$script:State.UiState -eq 'Measuring') {
        Set-TokenRaderUiState -NewState 'Measuring' -StatusMessage ($message + ' 已停止过慢查询；测量仍然有效，可再次查看。')
    } elseif ([string]$script:State.UiState -eq 'Stopping') {
        $script:StatusText.Text = $message + ' 已停止实时预览；正在继续冻结结束边界…'
    }
}

function Start-TokenRaderMeasurementBaselineAsync {
    param(
        [Parameter(Mandatory = $true)][Int64]$Generation,
        [Parameter(Mandatory = $true)][Int64]$RequestId
    )
    [void](Start-TokenRaderBackgroundJob `
        -ScriptBlock $script:MeasurementBaselineScript `
        -Parameters @{
            SessionsRoot = [string]$script:Paths.SessionsRoot
            PricingPath = [string]$script:Paths.PricingPath
            ModulePath = [string](Join-Path $PSScriptRoot 'TokenRader.Core.psm1')
            AccountIdentity = [string]$script:State.AccountIdentity
        } `
        -Kind 'MeasurementBaseline' `
        -Generation $Generation `
        -RequestId $RequestId `
        -CompletionHandler 'Complete-TokenRaderMeasurementBaselineJob' `
        -FailureHandler 'Fail-TokenRaderMeasurementBaselineJob' `
        -TimeoutSeconds 30)
}

function Start-TokenRaderMeasurementEndAsync {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [Parameter(Mandatory = $true)][Int64]$Generation,
        [Parameter(Mandatory = $true)][Int64]$RequestId
    )
    [void](Start-TokenRaderBackgroundJob `
        -ScriptBlock $script:MeasurementEndScript `
        -Parameters @{
            Baseline = $Baseline
            SessionsRoot = [string]$script:Paths.SessionsRoot
            ModulePath = [string](Join-Path $PSScriptRoot 'TokenRader.Core.psm1')
        } `
        -Kind 'MeasurementEnd' `
        -Generation $Generation `
        -RequestId $RequestId `
        -CompletionHandler 'Complete-TokenRaderMeasurementEndJob' `
        -FailureHandler 'Fail-TokenRaderMeasurementEndJob' `
        -TimeoutSeconds 30)
}

function Start-TokenRaderIndexSyncAsync {
    param(
        [bool]$FullReconcile = $false,
        [bool]$Startup = $false
    )
    if ($script:WindowClosing -or [bool]$script:State.IndexSyncing -or
        [string]$script:State.UiState -notin @('Idle', 'Ready', 'Error')) { return }
    $requestId = New-TokenRaderRequestId
    $script:State.IndexSyncing = $true
    $script:State.IndexSyncRequestId = $requestId
    Set-TokenRaderUiState -NewState ([string]$script:State.UiState) -StatusMessage $(if ($FullReconcile) {
        '正在后台核对日志目录；当前界面仍显示已有索引结果…'
    } else { '正在后台读取新增或修改日志；当前界面仍显示上一次结果…' })

    $coldStart = -not [bool]$script:State.IndexCatalogAvailable
    $progressState = [hashtable]::Synchronized(@{
        Stage = if ($coldStart) { '首次建库' } else { '准备索引' }
        ProcessedFiles = 0
        TotalFiles = 0
        LastProgressAt = [DateTimeOffset]::Now
    })
    [void](Start-TokenRaderBackgroundJob `
        -ScriptBlock $script:IndexSyncScript `
        -Parameters @{
            SessionsRoot = [string]$script:Paths.SessionsRoot
            ModulePath = [string](Join-Path $PSScriptRoot 'TokenRader.Core.psm1')
            FullReconcile = $FullReconcile
            ProgressState = $progressState
        } `
        -Kind 'IndexSync' `
        -Generation 0 `
        -RequestId $requestId `
        -CompletionHandler 'Complete-TokenRaderIndexSyncJob' `
        -FailureHandler 'Fail-TokenRaderIndexSyncJob' `
        -CallbackContext @{ Startup = $Startup; ColdStart = $coldStart } `
        -TimeoutSeconds $(if ($coldStart) { 0 } else { 60 }) `
        -StallTimeoutSeconds $(if ($coldStart) { 300 } else { 60 }) `
        -ProgressState $progressState)
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
    $candidateFiveObserved = if ($null -ne $Candidate.FiveHour -and $null -ne $Candidate.FiveHour.PSObject.Properties['ObservedAt']) { [DateTimeOffset]$Candidate.FiveHour.ObservedAt } else { [DateTimeOffset]$Candidate.ObservedAt }
    $currentFiveObserved = if ($null -ne $current.FiveHour -and $null -ne $current.FiveHour.PSObject.Properties['ObservedAt']) { [DateTimeOffset]$current.FiveHour.ObservedAt } else { [DateTimeOffset]$current.ObservedAt }
    $candidateWeeklyObserved = if ($null -ne $Candidate.Weekly -and $null -ne $Candidate.Weekly.PSObject.Properties['ObservedAt']) { [DateTimeOffset]$Candidate.Weekly.ObservedAt } else { [DateTimeOffset]$Candidate.ObservedAt }
    $currentWeeklyObserved = if ($null -ne $current.Weekly -and $null -ne $current.Weekly.PSObject.Properties['ObservedAt']) { [DateTimeOffset]$current.Weekly.ObservedAt } else { [DateTimeOffset]$current.ObservedAt }
    $useCandidateFive = ($null -ne $Candidate.FiveHour -and ($null -eq $current.FiveHour -or $candidateFiveObserved -ge $currentFiveObserved))
    $useCandidateWeekly = ($null -ne $Candidate.Weekly -and ($null -eq $current.Weekly -or $candidateWeeklyObserved -ge $currentWeeklyObserved))
    $fiveHour = if ($useCandidateFive) { $Candidate.FiveHour } else { $current.FiveHour }
    $weekly = if ($useCandidateWeekly) { $Candidate.Weekly } else { $current.Weekly }
    $fiveObserved = if ($null -ne $fiveHour -and $null -ne $fiveHour.PSObject.Properties['ObservedAt']) { [DateTimeOffset]$fiveHour.ObservedAt } else { [DateTimeOffset]::MinValue }
    $weeklyObserved = if ($null -ne $weekly -and $null -ne $weekly.PSObject.Properties['ObservedAt']) { [DateTimeOffset]$weekly.ObservedAt } else { [DateTimeOffset]::MinValue }
    $fivePlanType = if ($null -ne $fiveHour -and $null -ne $fiveHour.PSObject.Properties['PlanType']) { [string]$fiveHour.PlanType } else { '' }
    $weeklyPlanType = if ($null -ne $weekly -and $null -ne $weekly.PSObject.Properties['PlanType']) { [string]$weekly.PlanType } else { '' }
    $planType = if ($fiveObserved -ge $weeklyObserved -and -not [string]::IsNullOrWhiteSpace($fivePlanType)) {
        $fivePlanType
    } elseif (-not [string]::IsNullOrWhiteSpace($weeklyPlanType)) {
        $weeklyPlanType
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Candidate.PlanType)) { [string]$Candidate.PlanType } else { [string]$current.PlanType }
    $script:State.RateLimits = [pscustomobject]@{
        ObservedAt = if ($fiveObserved -gt $weeklyObserved) { $fiveObserved } else { $weeklyObserved }
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
        $DollarText.Text = '美金额度：暂无可用数据'
        $ResetText.Text = '暂无窗口'
        return
    }
    $UsageText.Text = ('{0:0.####}%' -f [double]$Window.UsedPercent)
    $Progress.Value = [Math]::Max(0, [Math]::Min(100, [double]$Window.UsedPercent))
    $ResetText.Text = if ($null -ne $Window.ResetsAt) { ('重置 {0:MM-dd HH:mm}' -f $Window.ResetsAt) } else { ('{0} 分钟窗口' -f $Window.WindowMinutes) }
    if ($null -ne $Estimate) {
        $DollarText.Text = ('美金额度≈{0} · 从 {1:0.####}% 开始 · 已用≈{2} · 剩余≈{3}' -f
            (Format-TokenRaderUsd ([double]$Estimate.TotalUsd)),
            [double]$Estimate.StartUsedPercent,
            (Format-TokenRaderUsd ([double]$Estimate.UsedUsd)),
            (Format-TokenRaderUsd ([double]$Estimate.RemainingUsd)))
    } else {
        $DollarText.Text = '美金额度：尚无有效反推结果'
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
    $accountUnchanged = $true
    if ($null -ne $script:State.IntervalBaseline.PSObject.Properties['AccountIdentity']) {
        $currentAccount = Get-TokenRaderAccount -CodexRoot $script:Paths.CodexRoot
        $accountUnchanged = ([string]$script:State.IntervalBaseline.AccountIdentity -eq [string]$currentAccount.AccountId)
    }
    $startRateLimits = if ($null -ne $Result.PSObject.Properties['StartRateLimits']) { $Result.StartRateLimits } else { $script:State.IntervalBaseline.RateLimits }
    $endRateLimits = if ($null -ne $Result.PSObject.Properties['EndRateLimits']) { $Result.EndRateLimits } else { $Result.RateLimits }
    $pricingComplete = if ($null -ne $Result.PSObject.Properties['PricingComplete']) { [bool]$Result.PricingComplete } else { [bool]$Result.CostComplete }
    $newEstimates = Get-TokenRaderQuotaEstimate `
        -StartRateLimits $(if ($accountUnchanged) { $startRateLimits } else { $null }) `
        -EndRateLimits $(if ($accountUnchanged) { $endRateLimits } else { $null }) `
        -IntervalCost ([double]$Result.TotalCost) `
        -CostComplete $pricingComplete
    $script:State.QuotaEstimates = [pscustomobject]@{
        FiveHour = $newEstimates.FiveHour
        Weekly = $newEstimates.Weekly
    }

    $calibrated = @()
    if ($null -ne $newEstimates.FiveHour) {
        $calibrated += ('5 小时 {0:0.####}%→{1:0.####}%（+{2:0.####}%）' -f
            $newEstimates.FiveHour.StartUsedPercent, $newEstimates.FiveHour.EndUsedPercent, $newEstimates.FiveHour.DeltaPercent)
    }
    if ($null -ne $newEstimates.Weekly) {
        $calibrated += ('周 {0:0.####}%→{1:0.####}%（+{2:0.####}%）' -f
            $newEstimates.Weekly.StartUsedPercent, $newEstimates.Weekly.EndUsedPercent, $newEstimates.Weekly.DeltaPercent)
    }
    $phase = if ($Final) { '最终' } else { '实时' }
    $script:State.QuotaCalibrationMessage = if ($calibrated.Count -gt 0) {
        ('{0}反推已同步：{1}。' -f $phase, ($calibrated -join '，'))
    } elseif (-not $accountUnchanged) {
        '测量期间账号标签发生变化，本次不反推美金额度。'
    } elseif (-not $pricingComplete) {
        '存在未收录价格的模型，暂时无法反推完整美金额度。'
    } elseif ([double]$Result.TotalCost -le 0) {
        '当前时间段尚无可计价消耗，点击“查看结果”会再次检查。'
    } else {
        '开始与当前额度窗口不一致、缺少重置时间或百分比尚无增量，暂不显示反推结果。'
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
    $processingMilliseconds = if ($null -ne $Result.PSObject.Properties['ProcessingMilliseconds']) { [double]$Result.ProcessingMilliseconds } else { 0.0 }
    $processingText = if ($processingMilliseconds -gt 0) { ' · 本次结果计算 {0:0.00} 秒' -f ($processingMilliseconds / 1000.0) } else { '' }
    $script:UpdatedText.Text = ('{0:HH:mm:ss} → {1:HH:mm:ss} · {2} · {3} 个活跃会话' -f $Result.StartedAt, $Result.EndedAt, $durationText, $Result.ChangedSessions)
    $script:IntervalTimeText.Text = if ($Running) {
        ('开始于 {0:HH:mm:ss} · 测量时长 {1}{2}' -f $Result.StartedAt, $durationText, $processingText)
    } else {
        ('{0:HH:mm:ss} — {1:HH:mm:ss} · 测量时长 {2}{3}' -f $Result.StartedAt, $Result.EndedAt, $durationText, $processingText)
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
    $script:StatusText.Text = if ($Running) { '已显示本次测量的最新结果；测量仍在继续。' } else { '全部项目的时间段计算已结束，结果已冻结。' }
    Update-QuotaCards
}

function Show-EmptyIntervalMeasurement {
    param([Parameter(Mandatory = $true)]$Baseline)
    $zeroUsage = [pscustomobject]@{
        Input = [Int64]0; Cached = [Int64]0; Uncached = [Int64]0
        Output = [Int64]0; ReasoningOutput = [Int64]0; Total = [Int64]0; CacheHitRate = 0.0
    }
    $script:SelectedSessionText.Text = '全部项目 · 指定时间段消耗（计算中）'
    $script:ScopeBadgeText.Text = '全部项目实时计算'
    $script:UpdatedText.Text = ('开始于 {0:HH:mm:ss} · 等待首次查看结果' -f [DateTimeOffset]$Baseline.StartedAt)
    $script:IntervalTimeText.Text = ('开始于 {0:HH:mm:ss} · 测量时长 0 秒 · 尚未执行结果计算' -f [DateTimeOffset]$Baseline.StartedAt)
    Set-UsageMetrics -Usage $zeroUsage -Model '等待模型调用'
    $script:UsdCostText.Text = Format-TokenRaderUsd 0
    $script:CostBreakdownText.Text = '尚未读取本次测量的新调用'
    $script:LongContextText.Text = '点击“查看结果”后进行精确增量计算'
    $script:InputPriceText.Text = '等待调用'
    $script:CachedPriceText.Text = '等待调用'
    $script:OutputPriceText.Text = '等待调用'
    $script:State.CurrentPriceUrl = ''
    $script:OpenPricingButton.IsEnabled = $false
    $script:FormulaText.Text = '时间段始终统计全部项目和全部 Codex 会话，不受项目下拉框影响。'
    $script:CaveatText.Text = '开始位置已经冻结；尚未运行结果查询，不代表本次消耗为零。'
    Update-QuotaCards
}

function Reset-TokenRaderComputeHost {
    # Kept as a compatibility name for the close handler.  There is no shared
    # PowerShell instance anymore; each request owns and disposes its worker.
    Stop-TokenRaderBackgroundJobs
}

function ConvertTo-TokenRaderOffsetHashtable {
    param($Value)
    $result = @{}
    if ($null -eq $Value) { return $result }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) { $result[[string]$key] = [Int64]$Value[$key] }
    } elseif ($null -ne $Value.PSObject) {
        foreach ($property in @($Value.PSObject.Properties)) {
            try { $result[[string]$property.Name] = [Int64]$property.Value } catch { }
        }
    }
    return $result
}

function Complete-TokenRaderMeasurementBaseline {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [Parameter(Mandatory = $true)][Int64]$Generation,
        [Parameter(Mandatory = $true)][Int64]$RequestId
    )
    if ($script:WindowClosing -or [Int64]$script:State.MeasurementGeneration -ne $Generation -or
        [string]$script:State.UiState -ne 'Starting' -or [Int64]$script:State.BaselineRequestId -ne $RequestId) { return }
    if ($null -eq $Baseline -or $null -eq $Baseline.PSObject.Properties['StartOffsets'] -or
        $null -eq $Baseline.PSObject.Properties['StartRateLimits']) {
        Fail-TokenRaderMeasurementRequest -Generation $Generation -RequestId $RequestId -Final $false -Message '开始计算准备结果缺少起始偏移或额度快照。'
        return
    }
    $script:State.BaselineRequestId = 0
    $script:State.PendingMeasurementStart = $false
    $script:State.IntervalBaseline = $Baseline
    $script:State.IntervalResult = $null
    $script:State.IntervalCache = $null
    Merge-LatestRateLimits -Candidate $Baseline.StartRateLimits
    Set-TokenRaderUiState -NewState 'Measuring' -StatusMessage '开始位置已冻结，正在等待 Codex 新消耗…'
    Show-EmptyIntervalMeasurement -Baseline $Baseline
}

function Complete-TokenRaderMeasurementEnd {
    param(
        [Parameter(Mandatory = $true)]$Ending,
        [Parameter(Mandatory = $true)][Int64]$Generation,
        [Parameter(Mandatory = $true)][Int64]$RequestId
    )
    if ($script:WindowClosing -or [Int64]$script:State.MeasurementGeneration -ne $Generation -or
        [string]$script:State.UiState -ne 'Stopping' -or [Int64]$script:State.EndCaptureRequestId -ne $RequestId) { return }
    if ($null -eq $Ending -or $null -eq $Ending.PSObject.Properties['EndOffsets']) {
        Fail-TokenRaderMeasurementRequest -Generation $Generation -RequestId $RequestId -Final $true -Message '结束计算结果缺少结束偏移。'
        return
    }
    $endOffsets = ConvertTo-TokenRaderOffsetHashtable -Value $Ending.EndOffsets
    $script:State.EndCaptureRequestId = 0
    $script:State.IntervalEnd = $Ending
    Set-TokenRaderUiState -NewState 'ComputingFinal' -StatusMessage '结束位置已冻结，正在后台结算指定时间段…'
    Start-TokenRaderIntervalComputeAsync `
        -Baseline $script:State.IntervalBaseline `
        -EndOffsets $endOffsets `
        -EndRevision $Ending.EndRevision `
        -EndedAt $Ending.EndedAt `
        -Final $true `
        -ScanRateLimits $true `
        -Generation $Generation
}

function Fail-TokenRaderMeasurementRequest {
    param(
        [Parameter(Mandatory = $true)][Int64]$Generation,
        [Parameter(Mandatory = $true)][Int64]$RequestId,
        [bool]$Final = $false,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($script:WindowClosing -or [Int64]$script:State.MeasurementGeneration -ne $Generation) { return }
    $matches = ([Int64]$script:State.BaselineRequestId -eq $RequestId -or
                [Int64]$script:State.EndCaptureRequestId -eq $RequestId -or
                [Int64]$script:State.IntervalComputeRequestId -eq $RequestId)
    if (-not $matches) { return }
    $script:State.BaselineRequestId = 0
    $script:State.EndCaptureRequestId = 0
    if ([Int64]$script:State.IntervalComputeRequestId -eq $RequestId) {
        $script:State.IntervalComputeRequestId = 0
        $script:State.IntervalComputing = $false
        $script:State.IntervalComputeStopping = $false
        $script:State.IntervalActiveScanRateLimits = $false
    }
    $script:State.IntervalComputePending = $false
    $script:State.IntervalComputePendingRequest = $null
    $script:State.PendingMeasurementStart = $false
    $script:State.QuotaEstimates = $null
    $script:State.QuotaCalibrationMessage = [string]$Message
    Set-TokenRaderUiState -NewState 'Error' -StatusMessage ([string]$Message)
    Update-QuotaCards
}

function Start-TokenRaderIntervalComputeAsync {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [hashtable]$EndOffsets = $null,
        $EndRevision = $null,
        $EndedAt = $null,
        [bool]$Final = $false,
        [bool]$ScanRateLimits = $false,
        [Int64]$Generation = 0,
        [Int64]$RequestId = 0
    )

    if ($script:WindowClosing) { return }
    $effectiveGeneration = if ($Generation -gt 0) { $Generation } else { [Int64]$script:State.MeasurementGeneration }
    if ([Int64]$script:State.MeasurementGeneration -ne $effectiveGeneration) { return }
    $effectiveRequestId = if ($RequestId -gt 0) { $RequestId } else { New-TokenRaderRequestId }
    if ([bool]$script:State.IntervalComputing) {
        # A final request always supersedes a preview. A quota-aware preview
        # may follow an explicitly token-only caller, while repeated equivalent
        # clicks are coalesced into the same request.
        $queueManualQuota = (-not $Final -and $ScanRateLimits -and
            -not [bool]$script:State.IntervalActiveScanRateLimits -and
            (-not [bool]$script:State.IntervalComputePending -or
                $null -eq $script:State.IntervalComputePendingRequest -or
                -not [bool]$script:State.IntervalComputePendingRequest.ScanRateLimits))
        if ($Final -or $queueManualQuota) {
            $script:State.IntervalComputePending = $true
            $script:State.IntervalComputePendingRequest = [pscustomobject]@{
                Generation = $effectiveGeneration
                RequestId = $effectiveRequestId
                BaselineStartedAt = [DateTimeOffset]$Baseline.StartedAt
                EndOffsets = $EndOffsets
                EndRevision = $EndRevision
                EndedAt = $EndedAt
                Final = $Final
                ScanRateLimits = $ScanRateLimits
            }
        }
        if ($Final -and -not [bool]$script:State.IntervalComputeStopping) {
            $activeRequestId = [Int64]$script:State.IntervalComputeRequestId
            $activeJob = if ($script:State.BackgroundJobs.ContainsKey($activeRequestId)) {
                $script:State.BackgroundJobs[$activeRequestId]
            } else { $null }
            if ($null -ne $activeJob) {
                $script:State.IntervalComputeStopping = $true
                $script:StatusText.Text = '结束边界已冻结，正在停止实时预览后执行最终结算…'
                Request-TokenRaderBackgroundStop -Job $activeJob
            }
        }
        return
    }

    $script:State.IntervalComputing = $true
    $script:State.IntervalComputeStopping = $false
    $script:State.IntervalActiveScanRateLimits = $ScanRateLimits
    $script:State.IntervalComputeRequestId = $effectiveRequestId
    $script:State.IntervalLastError = ''
    if ($Final) { $script:StatusText.Text = '正在后台结算指定时间段…' }
    elseif ($null -ne $script:State.IntervalResult) { $script:StatusText.Text = '正在后台更新；当前保留上一次结果…' }
    else { $script:StatusText.Text = '正在后台计算指定时间段消耗…' }

    $snapshots = @{}
    if ($null -ne $script:State.IntervalCache -and $null -ne $script:State.IntervalCache.PSObject.Properties['BaselineSnapshots']) {
        $snapshots = $script:State.IntervalCache.BaselineSnapshots
    }
    $progressState = [hashtable]::Synchronized(@{
        Stage = '启动后台计算'
        ProcessedRows = [Int64]0
        LastProgressAt = [DateTimeOffset]::Now
    })
    $cancellationSource = [Threading.CancellationTokenSource]::new()
    [void](Start-TokenRaderBackgroundJob `
        -ScriptBlock $script:IntervalComputeScript `
        -Parameters @{
            Baseline = $Baseline
            Snapshots = $snapshots
            EndOffsets = $EndOffsets
            EndRevision = $EndRevision
            EndedAt = $EndedAt
            PricingPath = [string]$script:Paths.PricingPath
            ModulePath = [string](Join-Path $PSScriptRoot 'TokenRader.Core.psm1')
            SessionsRoot = [string]$script:Paths.SessionsRoot
            ScanRateLimits = $ScanRateLimits
            CancellationToken = $cancellationSource.Token
            ProgressState = $progressState
        } `
        -Kind 'IntervalCompute' `
        -Generation $effectiveGeneration `
        -RequestId $effectiveRequestId `
        -CompletionHandler 'Complete-TokenRaderIntervalComputeJob' `
        -FailureHandler 'Fail-TokenRaderIntervalComputeJob' `
        -CallbackContext @{
            BaselineStartedAt = [DateTimeOffset]$Baseline.StartedAt
            Final = $Final
            EndOffsets = $EndOffsets
            EndRevision = $EndRevision
            EndedAt = $EndedAt
            ScanRateLimits = $ScanRateLimits
        } `
        -TimeoutSeconds $(if ($Final) { 60 } else { 15 }) `
        -SoftWarningSeconds 3 `
        -ProgressState $progressState `
        -CancellationSource $cancellationSource `
        -StopCompletionHandler 'Complete-TokenRaderIntervalStopJob')
}

function Complete-TokenRaderIntervalCompute {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$BaselineStartedAt,
        $Payload,
        [bool]$Final = $false,
        [bool]$ScanRateLimits = $true,
        [Int64]$Generation = 0,
        [Int64]$RequestId = 0
    )

    if ($script:WindowClosing) { return }
    $effectiveGeneration = if ($Generation -gt 0) { $Generation } else { [Int64]$script:State.MeasurementGeneration }
    $effectiveRequestId = if ($RequestId -gt 0) { $RequestId } else { [Int64]$script:State.IntervalComputeRequestId }
    if ([Int64]$script:State.MeasurementGeneration -ne $effectiveGeneration -or
        [Int64]$script:State.IntervalComputeRequestId -ne $effectiveRequestId) { return }
    if ($null -eq $script:State.IntervalBaseline -or [DateTimeOffset]$script:State.IntervalBaseline.StartedAt -ne $BaselineStartedAt) { return }

    $accepted = $false
    $succeeded = $false
    try {
        if ($null -eq $Payload -or $null -eq $Payload.Result) { throw '后台计算未返回结果。' }
        if ($Final) {
            if ([string]$script:State.UiState -ne 'ComputingFinal') { return }
        } elseif ([string]$script:State.UiState -ne 'Measuring') {
            # Stop may have won the race while a live calculation was running;
            # discard that result but allow the queued final request to proceed.
            $succeeded = $true
            return
        }
        $accepted = $true
        $result = $Payload.Result
        $script:State.IntervalResult = $result
        $script:State.IntervalLastError = ''
        if ($Final) { $script:State.IntervalFinalRetry = $null }
        if ($null -ne $Payload.PSObject.Properties['LatestRateLimits']) { Merge-LatestRateLimits -Candidate $Payload.LatestRateLimits }
        $endLimits = if ($null -ne $result.PSObject.Properties['EndRateLimits']) { $result.EndRateLimits } else { $result.RateLimits }
        Merge-LatestRateLimits -Candidate $endLimits
        # A caller may explicitly skip the quota query. Its null EndRateLimits
        # must not erase the last estimate calibrated by a quota-aware preview
        # or the final frozen settlement.
        if ($ScanRateLimits) {
            Update-QuotaEstimatesFromInterval -Result $result -Final $Final
        }
        $baselineSnapshots = if ($null -ne $result.PSObject.Properties['BaselineSnapshots']) { $result.BaselineSnapshots } else { @{} }
        $script:State.IntervalCache = [pscustomobject]@{
            BaselineStartedAt = $BaselineStartedAt
            Signature = [string]$result.Signature
            ChangeRevision = if ($null -ne $result.PSObject.Properties['ChangeRevision']) { [Int64]$result.ChangeRevision } else { -1L }
            Result = $result
            BaselineSnapshots = $baselineSnapshots
        }
        Show-IntervalResult -Result $result -Running ([bool]$script:State.IsMeasuring)
        $succeeded = $true
    } catch {
        $script:State.QuotaEstimates = $null
        $script:State.QuotaCalibrationMessage = '时间段后台计算失败：' + $_.Exception.Message
        Set-TokenRaderUiState -NewState 'Error' -StatusMessage ([string]$script:State.QuotaCalibrationMessage)
        Update-QuotaCards
    } finally {
        if ([Int64]$script:State.IntervalComputeRequestId -eq $effectiveRequestId) {
            $script:State.IntervalComputing = $false
            $script:State.IntervalComputeStopping = $false
            $script:State.IntervalActiveScanRateLimits = $false
            $script:State.IntervalComputeRequestId = 0
        }
        $hasPendingInterval = [bool]$script:State.IntervalComputePending
        if ($succeeded -and $Final) {
            Set-TokenRaderUiState -NewState 'Ready'
            # The final interval has already synchronized the index. Refresh
            # the selected rolling window from disk and remove snapshots whose
            # window ended more than seven days ago.
            Start-TokenRaderUsageHistoryRefresh -PurgeExpired $true
        } elseif ($succeeded -and $accepted -and -not $hasPendingInterval) {
            # During Measuring the five-minute timer runs an interval preview
            # instead of the idle index-sync path. Refresh the rolling card
            # after that preview so it cannot remain stale throughout a long
            # measurement.
            Start-TokenRaderUsageHistoryRefresh
        }
        if (-not $script:WindowClosing -and $succeeded -and $script:State.IntervalComputePending -and
            [Int64]$script:State.MeasurementGeneration -eq $effectiveGeneration -and
            $null -ne $script:State.IntervalBaseline) {
            $request = $script:State.IntervalComputePendingRequest
            $script:State.IntervalComputePending = $false
            $script:State.IntervalComputePendingRequest = $null
            if ($null -ne $request -and [Int64]$request.Generation -eq $effectiveGeneration -and
                [DateTimeOffset]$request.BaselineStartedAt -eq [DateTimeOffset]$script:State.IntervalBaseline.StartedAt) {
                if ([bool]$request.Final) { Set-TokenRaderUiState -NewState 'ComputingFinal' }
                $pendingEndOffsets = if ($null -eq $request.EndOffsets) {
                    $null
                } else {
                    ConvertTo-TokenRaderOffsetHashtable -Value $request.EndOffsets
                }
                Start-TokenRaderIntervalComputeAsync `
                    -Baseline $script:State.IntervalBaseline `
                    -EndOffsets $pendingEndOffsets `
                    -EndRevision $request.EndRevision `
                    -EndedAt $request.EndedAt `
                    -Final ([bool]$request.Final) `
                    -ScanRateLimits ([bool]$request.ScanRateLimits) `
                    -Generation $effectiveGeneration `
                    -RequestId ([Int64]$request.RequestId)
            }
        }
    }
}

function Update-IntervalView {
    param([switch]$Manual)
    if ($null -eq $script:State.IntervalBaseline) { return }
    if ($null -ne $script:State.IntervalResult) {
        Show-IntervalResult -Result $script:State.IntervalResult -Running ([bool]$script:State.IsMeasuring)
        if ($script:State.UiState -in @('Stopping', 'ComputingFinal')) {
            $script:StatusText.Text = '正在后台结算，当前显示上一次结果…'
        }
    }
    if ($script:State.UiState -eq 'Ready' -and $null -ne $script:State.IntervalFinalRetry) {
        if ([bool]$script:State.IntervalComputing) {
            $script:StatusText.Text = '正在重试冻结时间段结算；当前保留上一次结果…'
            return
        }
        $retry = $script:State.IntervalFinalRetry
        if ([Int64]$retry.Generation -ne [Int64]$script:State.MeasurementGeneration -or
            [DateTimeOffset]$retry.BaselineStartedAt -ne [DateTimeOffset]$script:State.IntervalBaseline.StartedAt) {
            $script:State.IntervalFinalRetry = $null
            return
        }
        Set-TokenRaderUiState -NewState 'ComputingFinal' -StatusMessage '正在按已冻结的结束边界重试结算…'
        Start-TokenRaderIntervalComputeAsync `
            -Baseline $script:State.IntervalBaseline `
            -EndOffsets (ConvertTo-TokenRaderOffsetHashtable -Value $retry.EndOffsets) `
            -EndRevision $retry.EndRevision `
            -EndedAt $retry.EndedAt `
            -Final $true `
            -ScanRateLimits ([bool]$retry.ScanRateLimits) `
            -Generation ([Int64]$retry.Generation)
        return
    }
    if ($script:State.UiState -eq 'Measuring') {
        if ([bool]$script:State.IntervalComputing) {
            if ($Manual -and -not [bool]$script:State.IntervalActiveScanRateLimits) {
                Start-TokenRaderIntervalComputeAsync `
                    -Baseline $script:State.IntervalBaseline `
                    -ScanRateLimits $true `
                    -Generation ([Int64]$script:State.MeasurementGeneration)
            }
            $script:StatusText.Text = if ($null -ne $script:State.IntervalResult) {
                '正在后台更新；当前保留上一次结果，重复请求已合并…'
            } else { '正在后台计算时间段新消耗，重复请求已合并…' }
            return
        }
        # An unchanged watcher revision is an O(1) cache hit. Never enumerate
        # the complete session tree on the WPF dispatcher.
        if (-not $Manual -and $null -ne $script:State.IntervalCache -and
            $null -ne $script:State.IntervalCache.PSObject.Properties['ChangeRevision']) {
            $currentChangeRevision = Get-TokenRaderChangeRevision -SessionsRoot $script:Paths.SessionsRoot
            if ([Int64]$currentChangeRevision -eq [Int64]$script:State.IntervalCache.ChangeRevision) {
                $script:StatusText.Text = '日志未变化，当前显示结果已是最新。'
                return
            }
        }
        Start-TokenRaderIntervalComputeAsync `
            -Baseline $script:State.IntervalBaseline `
            -ScanRateLimits $true `
            -Generation ([Int64]$script:State.MeasurementGeneration)
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
    if ([string]$script:State.UiState -notin @('Idle', 'Ready', 'Error')) { return }
    $waitForIndex = (-not [bool]$script:State.IndexReady -or [bool]$script:State.IndexSyncing)
    $generation = [Int64]$script:State.MeasurementGeneration + 1
    $requestId = New-TokenRaderRequestId
    $script:State.MeasurementGeneration = $generation
    $script:State.BaselineRequestId = $requestId
    $script:State.EndCaptureRequestId = 0
    $script:State.IntervalComputeRequestId = 0
    $script:State.IntervalComputing = $false
    $script:State.IntervalComputeStopping = $false
    $script:State.IntervalActiveScanRateLimits = $false
    $script:State.IntervalComputePending = $false
    $script:State.IntervalComputePendingRequest = $null
    $script:State.IntervalLastError = ''
    $script:State.IntervalFinalRetry = $null
    $script:State.IntervalBaseline = $null
    $script:State.IntervalResult = $null
    $script:State.IntervalCache = $null
    $script:State.PendingMeasurementStart = $waitForIndex
    $script:State.QuotaEstimates = $null
    $script:State.QuotaCalibrationMessage = '美元总额需通过一次使额度百分比上升的时间段测量进行反推。'
    $script:State.ViewMode = 'interval'
    Update-QuotaCards
    if ($waitForIndex) {
        if (-not [bool]$script:State.IndexSyncing) {
            Start-TokenRaderIndexSyncAsync -FullReconcile $true -Startup $true
        }
        Set-TokenRaderUiState -NewState 'Starting' -StatusMessage '准备中：正在等待后台索引完成，完成后会自动开始计时…'
        return
    }
    Set-TokenRaderUiState -NewState 'Starting' -StatusMessage '正在后台冻结开始位置…'
    Start-TokenRaderMeasurementBaselineAsync -Generation $generation -RequestId $requestId
}

function Cancel-TokenRaderMeasurementPreparation {
    if ([string]$script:State.UiState -ne 'Starting') { return }
    $script:State.MeasurementGeneration = [Int64]$script:State.MeasurementGeneration + 1L
    $script:State.PendingMeasurementStart = $false
    $script:State.BaselineRequestId = 0L
    $script:State.EndCaptureRequestId = 0L
    $script:State.IntervalComputeRequestId = 0L
    $script:State.IntervalComputing = $false
    $script:State.IntervalComputeStopping = $false
    $script:State.IntervalActiveScanRateLimits = $false
    $script:State.IntervalComputePending = $false
    $script:State.IntervalComputePendingRequest = $null
    $script:State.IntervalBaseline = $null
    $script:State.IntervalResult = $null
    $script:State.IntervalCache = $null

    foreach ($job in @($script:State.BackgroundJobs.Values)) {
        if ([string]$job.Kind -notin @('IndexSync', 'MeasurementBaseline')) { continue }
        if ([string]$job.Kind -eq 'IndexSync') {
            $script:State.IndexSyncing = $false
            $script:State.IndexSyncRequestId = 0L
            $script:State.IndexReady = $false
        }
        Request-TokenRaderBackgroundStop -Job $job
    }
    Set-TokenRaderUiState -NewState 'Idle' -StatusMessage '已取消准备；后台停止不会阻塞界面，可以重新开始。'
}

function Stop-IntervalMeasurement {
    if ([string]$script:State.UiState -eq 'Starting') {
        Cancel-TokenRaderMeasurementPreparation
        return
    }
    if ([string]$script:State.UiState -ne 'Measuring' -or $null -eq $script:State.IntervalBaseline) { return }
    $generation = [Int64]$script:State.MeasurementGeneration
    $requestId = New-TokenRaderRequestId
    $script:State.EndCaptureRequestId = $requestId
    $script:State.ViewMode = 'interval'
    Set-TokenRaderUiState -NewState 'Stopping' -StatusMessage '正在后台冻结结束位置…'
    Start-TokenRaderMeasurementEndAsync `
        -Baseline $script:State.IntervalBaseline `
        -Generation $generation `
        -RequestId $requestId
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

    # 尝试从 SQLite 索引获取会话数据（秒级 → 毫秒级）
    $snapshot = $null
    $index = Get-TokenRaderIndex
    if ($null -ne $index) {
        $sessionId = [string]$selected.SessionId
        $indexTable = Get-TokenRaderIndexRecords -SessionId $sessionId
        if ($null -ne $indexTable -and $indexTable.Rows.Count -gt 0) {
            $snapshot = ConvertFrom-TokenRaderIndexRecord -Row $indexTable.Rows[0] -FilePath ([string]$selected.FilePath)
        }
    }
    if ($null -eq $snapshot) {
        $snapshot = Get-TokenRaderUsageSnapshot -FilePath ([string]$selected.FilePath)
    }
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
        $script:CaveatText.Text = '整次任务已逐调用识别模型和 272K 长上下文；金额仍是标准 API 等价估算，不含工具调用、区域处理或 Priority/Batch/Flex。GPT-5.6 缓存写入按未缓存输入价的 1.25 倍计费，但日志无法区分写入量，因此未计入。账号切换前的历史日志仍无法仅凭日志可靠归属。'
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

    $script:CaveatText.Text = '最后一次调用使用 last_token_usage；若该次输入超过模型公布的 272K 阈值，会应用官方长上下文倍率。估算不包含工具调用、区域处理或 Priority/Batch/Flex。GPT-5.6 缓存写入按未缓存输入价的 1.25 倍计费，但日志无法区分写入量，因此未计入。'
    $script:StatusText.Text = ('已读取 {0} · {1} · 本地处理完成' -f $model, $scopeLabel)
    Update-QuotaCards
}

function Refresh-Application {
    if ($script:State.Refreshing) { return }
    $script:State.Refreshing = $true
    try {
        $script:StatusText.Text = '正在从本地索引读取 Codex 会话…'
        $previousPath = ''
        if ($null -ne $script:SessionListBox.SelectedItem) {
            $previousPath = [string]$script:SessionListBox.SelectedItem.FilePath
        }
        $previousProjectPath = ''
        if ($null -ne $script:ProjectComboBox.SelectedItem) {
            $previousProjectPath = [string]$script:ProjectComboBox.SelectedItem.ProjectPath
        }

        $account = Get-TokenRaderAccount -CodexRoot $script:Paths.CodexRoot
        $script:State.AccountIdentity = [string]$account.AccountId
        $script:AccountNameText.Text = [string]$account.DisplayName
        $script:AccountIdText.Text = if ([string]::IsNullOrWhiteSpace([string]$account.AccountIdShort)) { '' } else { [string]$account.AccountIdShort }
        if ($null -ne $account.WrittenAt) {
            $script:AccountHintText.Text = ('账号标签更新于 {0:MM-dd HH:mm}；历史会话归属需自行确认。' -f $account.WrittenAt)
        } else {
            $script:AccountHintText.Text = '账号只用于标记当前会话；不会读取 auth.json 中的密钥。'
        }
        $historyDays = Get-SelectedHistoryDays
        $index = Get-TokenRaderIndex
        if ($null -ne $index) {
            $sessions = @(Get-TokenRaderIndexedSessionFiles -Days $historyDays -MaximumFiles 200)
            $projects = @(Get-TokenRaderIndexedProjects -Days $historyDays)
        } else {
            # 索引组件不可用时保留直接读取日志的兼容路径。
            $sessions = @(Get-TokenRaderSessionFiles -SessionsRoot $script:Paths.SessionsRoot)
            $projects = @(Get-TokenRaderProjects -SessionsRoot $script:Paths.SessionsRoot)
        }
        $script:State.Projects = $projects
        $rangeLabel = if ($historyDays -eq 0) { '全部历史' } else { '最近 {0} 天' -f $historyDays }
        $script:SessionCountText.Text = ('{0} 个日志（最多显示 200） · {1} 个项目 · {2}' -f $sessions.Count, $projects.Count, $rangeLabel)
        $script:SessionListBox.ItemsSource = $null
        $script:SessionListBox.ItemsSource = $sessions
        $script:ProjectComboBox.ItemsSource = $null
        $script:ProjectComboBox.ItemsSource = $projects

        $projectIndex = 0
        if (-not [string]::IsNullOrWhiteSpace($previousProjectPath)) {
            $preferredProjectPath = $previousProjectPath
            for ($i = 0; $i -lt $projects.Count; $i++) {
                if ([string]$projects[$i].ProjectPath -eq $preferredProjectPath) { $projectIndex = $i; break }
            }
            if ($projects.Count -gt 0) { $script:ProjectComboBox.SelectedIndex = $projectIndex }
        } elseif ($projects.Count -gt 0) {
            # 首次打开：不自动选中项目，保持闲置（用户操作后才计算）
            $script:ProjectComboBox.SelectedIndex = -1
        }

        if (-not [string]::IsNullOrWhiteSpace($previousPath)) {
            $targetIndex = 0
            for ($i = 0; $i -lt $sessions.Count; $i++) {
                if ([string]$sessions[$i].FilePath -eq $previousPath) { $targetIndex = $i; break }
            }
            if ($sessions.Count -gt 0) { $script:SessionListBox.SelectedIndex = $targetIndex }
        } elseif ($sessions.Count -gt 0) {
            # 首次打开：不自动选中会话，等待用户点击（不对任何会话计算）
            $script:SelectedSessionText.Text = '请选择一个会话开始查看'
            $script:UpdatedText.Text = '等待选择'
            Set-EmptyMetrics
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

$script:RefreshButton.Add_Click({
    if ([string]$script:State.UiState -notin @('Idle', 'Ready', 'Error')) { return }
    Start-TokenRaderIndexSyncAsync -FullReconcile (-not [bool]$script:State.IndexReady) -Startup (-not [bool]$script:State.IndexReady)
})
$script:RebuildIndexButton.Add_Click({
    if ([string]$script:State.UiState -notin @('Idle', 'Ready', 'Error')) { return }
    $script:RebuildIndexButton.IsEnabled = $false
    $script:RefreshButton.IsEnabled = $false
    $script:StatusText.Text = '正在完整重建本地索引；原始 Codex 日志不会被修改…'
    try {
        New-TokenRaderIndex -SessionsRoot $script:Paths.SessionsRoot -Force | Out-Null
        $script:State.ProjectCache = @{}
        $script:State.RateLimitSnapshotCache = @{}
        $script:State.ToolBackfillCompleted = $false
        Refresh-Application
        $script:StatusText.Text = '本地索引已完整重建。'
        Update-TokenRaderToolBackfillButton
        Start-TokenRaderUsageHistoryRefresh -ForceRefresh $true
    } catch {
        $script:StatusText.Text = '索引重建失败：' + $_.Exception.Message
    } finally {
        $script:RebuildIndexButton.IsEnabled = $true
        $script:RefreshButton.IsEnabled = $true
    }
})
$script:PurgeOldIndexButton.Add_Click({
    if ([string]$script:State.UiState -notin @('Idle', 'Ready', 'Error')) { return }
    $script:PurgeOldIndexButton.IsEnabled = $false
    $script:RefreshButton.IsEnabled = $false
    $script:StatusText.Text = '正在清理30天以前的本地索引；原始 Codex 日志不会被修改…'
    try {
        if ($null -eq (Get-TokenRaderIndex)) {
            Open-TokenRaderIndex -SessionsRoot $script:Paths.SessionsRoot | Out-Null
        }
        $cleanup = Remove-TokenRaderIndexHistory -Days 30
        $script:State.ProjectCache = @{}
        Refresh-Application
        $script:StatusText.Text = ('已清理 {0} 个30天以前的索引记录；原始日志保持不变。' -f [int]$cleanup.RemovedFiles)
        Start-TokenRaderUsageHistoryRefresh
    } catch {
        $script:StatusText.Text = '旧索引清理失败：' + $_.Exception.Message
    } finally {
        $script:PurgeOldIndexButton.IsEnabled = $true
        $script:RefreshButton.IsEnabled = $true
    }
})
$script:HistoryRangeComboBox.Add_SelectionChanged({
    if (-not $script:State.Refreshing -and [string]$script:State.UiState -in @('Idle', 'Measuring', 'Ready', 'Error')) {
        $script:State.ProjectCache = @{}
        Refresh-Application
    }
})
$script:UsageHistoryRangeComboBox.Add_SelectionChanged({
    if (-not $script:State.Refreshing -and [string]$script:State.UiState -in @('Idle', 'Measuring', 'Ready', 'Error')) {
        Start-TokenRaderUsageHistoryRefresh -DayOffset (Get-SelectedUsageHistoryDayOffset)
    }
})
$script:BackfillToolUsageButton.Add_Click({ Start-TokenRaderToolBackfill })
$script:SessionListBox.Add_SelectionChanged({
    if (-not $script:State.Refreshing -and [string]$script:State.UiState -in @('Idle', 'Ready', 'Error')) {
        $script:State.ViewMode = 'session'
        Update-UsageView
    }
})
$script:ProjectComboBox.Add_SelectionChanged({
    if (-not $script:State.Refreshing -and [string]$script:State.UiState -in @('Idle', 'Ready', 'Error')) {
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
    if (-not $script:State.Refreshing -and [string]$script:State.UiState -in @('Idle', 'Ready', 'Error')) {
        $script:State.ViewMode = 'session'
        Update-UsageView
    }
})
$script:StartMeasureButton.Add_Click({ Start-IntervalMeasurement })
$script:StopMeasureButton.Add_Click({ Stop-IntervalMeasurement })
$script:ViewIntervalButton.Add_Click({
    if ($null -ne $script:State.IntervalBaseline) {
        $script:State.ViewMode = 'interval'
        Update-IntervalView -Manual
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
    if ($script:WindowClosing) { return }
    if ($script:AutoRefreshCheckBox.IsChecked -ne $true) { return }
    switch ([string]$script:State.UiState) {
        'Measuring' { Update-IntervalView; break }
        'Starting' { break }
        'Stopping' { break }
        'ComputingFinal' { break }
        default {
        # 只在后台读取变化队列，UI 保留上一次结果。
        Start-TokenRaderIndexSyncAsync
        break
        }
    }
})
$script:Window.Add_Closing({
    $script:WindowClosing = $true
    $script:Timer.Stop()
    Reset-TokenRaderComputeHost
    Close-TokenRaderIndex
})

Set-PricingTable
# 索引保存在项目 data/private 下。先立即显示已有结果，再在窗口出现后
# 后台核对一次目录；此后刷新只消费文件变化队列。
try {
    $openedIndex = Open-TokenRaderIndex -SessionsRoot $script:Paths.SessionsRoot
    if ($null -ne $openedIndex) {
        $script:State.IndexCatalogAvailable = ([bool]$openedIndex.CatalogInitialized -and -not [bool]$openedIndex.IsNew)
    }
} catch { }
Refresh-Application
$script:StartupIndexSyncScheduled = $false
$script:Window.Add_ContentRendered({
    if ($script:StartupIndexSyncScheduled -or $script:WindowClosing) { return }
    $script:StartupIndexSyncScheduled = $true
    Start-TokenRaderIndexSyncAsync -FullReconcile $true -Startup $true
})
Set-TokenRaderUiState -NewState 'Idle' -StatusMessage '界面已就绪，正在准备后台索引；完成前请勿启动 Codex 测量。'
$script:Timer.Start()
[void]$script:Window.ShowDialog()
