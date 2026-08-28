[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

function Assert-UiTest {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('UI CALLBACK TEST FAILED: ' + $Message) }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$uiSource = [IO.File]::ReadAllText((Join-Path $projectRoot 'TokenRader.ps1'))
Assert-UiTest ($uiSource -notmatch 'GetNewClosure\s*\(') 'production lifecycle still contains GetNewClosure'

foreach ($helperName in @('Get-TokenRaderCallbackContextValue', 'Invoke-TokenRaderBackgroundHandler',
        'Request-TokenRaderBackgroundStop', 'Start-TokenRaderBackgroundPoller', 'Start-TokenRaderBackgroundJob',
        'Complete-TokenRaderIndexSyncJob', 'Complete-TokenRaderMeasurementBaselineJob',
        'Complete-TokenRaderMeasurementBaseline', 'New-TokenRaderFinalRetryState',
        'Start-TokenRaderPendingIntervalCompute', 'Fail-TokenRaderIntervalComputeJob',
        'Complete-TokenRaderIntervalStopJob', 'Complete-TokenRaderIntervalComputeJob',
        'Complete-TokenRaderIntervalCompute')) {
    $match = [regex]::Match($uiSource, ('(?s)function ' + [regex]::Escape($helperName) + '\b.*?(?=\r?\nfunction |\z)'))
    Assert-UiTest $match.Success ('production helper not found: ' + $helperName)
    Invoke-Expression $match.Value
}

$script:WindowClosing = $false
$script:BackgroundPollTimer = $null
$script:State = @{ BackgroundJobs = @{} }

function Stop-UiTestJobs {
    if ($null -ne $script:BackgroundPollTimer) { $script:BackgroundPollTimer.Stop() }
    foreach ($job in @($script:State.BackgroundJobs.Values)) {
        try { $job.PowerShell.Stop() } catch { }
        try { $job.PowerShell.Dispose() } catch { }
    }
    $script:State.BackgroundJobs.Clear()
}

try {
    # Exercise the real production lifecycle handlers with synthetic state.
    # The index completion must update the same script scope and immediately
    # launch baseline capture; the baseline completion must enter Measuring.
    function Merge-LatestRateLimits { param($Candidate) }
    function Refresh-Application { $script:LifecycleRefreshCalled = $true }
    $script:StatusText = [pscustomobject]@{ Text = '' }
    function Set-TokenRaderUiState {
        param([string]$NewState, [string]$StatusMessage = '')
        $script:State.UiState = $NewState
        if (-not [string]::IsNullOrWhiteSpace($StatusMessage)) { $script:StatusText.Text = $StatusMessage }
    }
    function Start-TokenRaderMeasurementBaselineAsync {
        param([Int64]$Generation, [Int64]$RequestId)
        $script:LifecycleBaselineRequest = $RequestId
    }
    function Start-TokenRaderIntervalComputeAsync { param($Baseline, [Int64]$Generation); $script:LifecycleIntervalStarted = $true }
    function Show-EmptyIntervalMeasurement { param($Baseline); $script:LifecycleEmptyMeasurementShown = $true }
    $script:LifecycleRefreshCalled = $false
    $script:LifecycleBaselineRequest = 0L
    $script:LifecycleIntervalStarted = $false
    $script:LifecycleEmptyMeasurementShown = $false
    $script:State = @{
        BackgroundJobs = @{}; IndexSyncing = $true; IndexSyncRequestId = 77L; IndexReady = $false
        IndexCatalogAvailable = $false; ProjectCache = @{}; RateLimitSnapshotCache = @{}
        PendingMeasurementStart = $true; UiState = 'Starting'; BaselineRequestId = 88L
        MeasurementGeneration = 3L; IntervalResult = $null; IntervalCache = $null
    }
    Complete-TokenRaderIndexSyncJob ([pscustomobject]@{ LatestRateLimits = $null }) 0L 77L 'IndexSync' @{ Startup = $true; ColdStart = $false }
    Assert-UiTest (-not [bool]$script:State.IndexSyncing) 'index completion did not clear IndexSyncing'
    Assert-UiTest ([Int64]$script:State.IndexSyncRequestId -eq 0L) 'index completion did not clear its request id'
    Assert-UiTest ([Int64]$script:LifecycleBaselineRequest -eq 88L) 'index completion did not launch baseline capture'
    Assert-UiTest (-not $script:LifecycleRefreshCalled) 'pending measurement was delayed by a synchronous UI refresh'

    $baseline = [pscustomobject]@{
        StartedAt = [DateTimeOffset]::Now
        StartOffsets = @{ synthetic = 10L }
        StartRateLimits = [pscustomobject]@{ PlanType = 'test' }
    }
    Complete-TokenRaderMeasurementBaselineJob $baseline 3L 88L 'MeasurementBaseline' $null
    Assert-UiTest ([string]$script:State.UiState -eq 'Measuring') 'baseline completion did not transition Starting to Measuring'
    Assert-UiTest $script:LifecycleEmptyMeasurementShown 'baseline completion did not render the initial measurement placeholder'
    Assert-UiTest (-not $script:LifecycleIntervalStarted) 'baseline completion started a redundant zero-width interval calculation'

    # A token-only automatic preview has no end quota snapshot and must keep
    # the estimate produced by the last manual refresh. A manual preview is
    # explicitly allowed to recalibrate (or clear) it from synchronized limits.
    $script:QuotaUpdateCalls = 0
    function Update-QuotaEstimatesFromInterval { param($Result, [bool]$Final); $script:QuotaUpdateCalls++ }
    function Show-IntervalResult { param($Result, [bool]$Running) }
    $preservedEstimate = [pscustomobject]@{ Marker = 'keep' }
    $intervalResult = [pscustomobject]@{
        StartedAt = $baseline.StartedAt; EndedAt = [DateTimeOffset]::Now
        EndRateLimits = $null; RateLimits = $null; Signature = 'synthetic'
        ChangeRevision = 1L; BaselineSnapshots = @{}
    }
    $script:State = @{
        BackgroundJobs = @{}; MeasurementGeneration = 3L; IntervalComputeRequestId = 89L
        IntervalComputing = $true; IntervalComputeStopping = $false; IntervalActiveScanRateLimits = $false
        IntervalComputePending = $false; IntervalComputePendingRequest = $null
        IntervalLastError = ''; IntervalFinalRetry = $null; IntervalBaseline = $baseline
        IntervalResult = $null; IntervalCache = $null; QuotaEstimates = $preservedEstimate
        UiState = 'Measuring'; IsMeasuring = $true
    }
    $intervalPayload = [pscustomobject]@{ Result = $intervalResult; LatestRateLimits = $null }
    Complete-TokenRaderIntervalComputeJob $intervalPayload 3L 89L 'IntervalCompute' @{
        BaselineStartedAt = $baseline.StartedAt; Final = $false; ScanRateLimits = $false
    }
    Assert-UiTest ($script:QuotaUpdateCalls -eq 0) 'token-only automatic preview recalibrated an absent quota snapshot'
    Assert-UiTest ($script:State.QuotaEstimates -eq $preservedEstimate) 'token-only automatic preview erased the prior dollar estimate'

    $script:State.IntervalComputeRequestId = 90L
    $script:State.IntervalComputing = $true
    Complete-TokenRaderIntervalComputeJob $intervalPayload 3L 90L 'IntervalCompute' @{
        BaselineStartedAt = $baseline.StartedAt; Final = $false; ScanRateLimits = $true
    }
    Assert-UiTest ($script:QuotaUpdateCalls -eq 1) 'manual preview did not request quota recalibration'

    # A live preview timeout is recoverable: it must retain the baseline and
    # last result instead of invalidating the whole measurement.
    $preservedResult = [pscustomobject]@{ Marker = 'preserved' }
    $script:State = @{
        BackgroundJobs = @{}; MeasurementGeneration = 3L; IntervalComputeRequestId = 90L
        IntervalComputing = $true; IntervalComputePending = $false; IntervalComputePendingRequest = $null
        IntervalLastError = ''; IntervalFinalRetry = $null; IntervalBaseline = $baseline
        IntervalResult = $preservedResult; UiState = 'Measuring'
    }
    Fail-TokenRaderIntervalComputeJob 'synthetic timeout' 3L 90L 'IntervalCompute' @{ Final = $false }
    Assert-UiTest ([string]$script:State.UiState -eq 'Measuring') 'live preview failure invalidated the measurement'
    Assert-UiTest ($script:State.IntervalBaseline -eq $baseline) 'live preview failure discarded the baseline'
    Assert-UiTest ($script:State.IntervalResult -eq $preservedResult) 'live preview failure discarded the last result'
    Assert-UiTest ([Int64]$script:State.IntervalComputeRequestId -eq 0L) 'live preview failure did not unlock computation'

    # A timeout marked StopPending keeps the computation locked until the
    # underlying runspace has actually stopped. Only the stop callback may
    # release the request, preventing a second CPU-heavy worker from racing it.
    $script:State.IntervalComputeRequestId = 92L
    $script:State.IntervalComputing = $true
    $script:State.IntervalComputeStopping = $false
    $script:State.IntervalActiveScanRateLimits = $false
    $script:State.IntervalComputePending = $false
    $script:State.IntervalComputePendingRequest = $null
    $script:State.UiState = 'Measuring'
    Fail-TokenRaderIntervalComputeJob 'synthetic cancellable timeout' 3L 92L 'IntervalCompute' @{ Final = $false; StopPending = $true }
    Assert-UiTest ([bool]$script:State.IntervalComputing) 'timeout unlocked before the underlying worker stopped'
    Assert-UiTest ([bool]$script:State.IntervalComputeStopping) 'timeout did not expose the stopping state'
    Assert-UiTest ([Int64]$script:State.IntervalComputeRequestId -eq 92L) 'timeout discarded the active request before stop completion'
    Complete-TokenRaderIntervalStopJob $null 3L 92L 'IntervalCompute' @{ Final = $false; StopPending = $true }
    Assert-UiTest (-not [bool]$script:State.IntervalComputing) 'stop completion did not unlock interval computation'
    Assert-UiTest (-not [bool]$script:State.IntervalComputeStopping) 'stop completion left the stopping flag set'
    Assert-UiTest ([Int64]$script:State.IntervalComputeRequestId -eq 0L) 'stop completion did not clear the request id'

    # A final timeout preserves the immutable end boundary and becomes Ready,
    # allowing View Result to retry without including later appends.
    $frozenEnd = @{ synthetic = 25L }
    $script:State.IntervalComputeRequestId = 91L
    $script:State.IntervalComputing = $true
    $script:State.UiState = 'ComputingFinal'
    Fail-TokenRaderIntervalComputeJob 'synthetic final timeout' 3L 91L 'IntervalCompute' @{
        Final = $true; BaselineStartedAt = $baseline.StartedAt; EndOffsets = $frozenEnd
        EndRevision = 12L; EndedAt = [DateTimeOffset]::Now; ScanRateLimits = $true
    }
    Assert-UiTest ([string]$script:State.UiState -eq 'Ready') 'final failure did not enter retryable Ready state'
    Assert-UiTest ($null -ne $script:State.IntervalFinalRetry) 'final failure did not preserve retry boundaries'
    Assert-UiTest ([Int64]$script:State.IntervalFinalRetry.EndRevision -eq 12L) 'final retry revision changed'
    Assert-UiTest ($script:State.IntervalResult -eq $preservedResult) 'final failure discarded the last result'

    $script:State = @{ BackgroundJobs = @{} }
    $script:CompletionSeen = $false
    $script:CompletionValue = ''
    $script:CompletionFrame = New-Object Windows.Threading.DispatcherFrame
    function Complete-UiScopeProbe {
        param($Payload, $Generation, $RequestId, $Kind, $Context)
        $script:CompletionSeen = $true
        $script:CompletionValue = [string]$Context.Marker
        $script:CompletionFrame.Continue = $false
    }
    function Fail-UiScopeProbe {
        param($ErrorMessage, $Generation, $RequestId, $Kind, $Context)
        throw [string]$ErrorMessage
    }
    [void](Start-TokenRaderBackgroundJob `
        -ScriptBlock { Start-Sleep -Milliseconds 50; 'ok' } `
        -Kind 'ScopeProbe' `
        -RequestId 8101L `
        -CompletionHandler 'Complete-UiScopeProbe' `
        -FailureHandler 'Fail-UiScopeProbe' `
        -CallbackContext @{ Marker = 'main-script' })
    [Windows.Threading.Dispatcher]::PushFrame($script:CompletionFrame)
    Assert-UiTest $script:CompletionSeen 'named completion handler did not update main script state'
    Assert-UiTest ($script:CompletionValue -eq 'main-script') 'callback context was not preserved'

    $script:State = @{ BackgroundJobs = @{} }
    $script:TimeoutSeen = $false
    $script:TimeoutMessage = ''
    $script:TimeoutFrame = New-Object Windows.Threading.DispatcherFrame
    function Complete-UiTimeoutProbe {
        param($Payload, $Generation, $RequestId, $Kind, $Context)
        $script:TimeoutFrame.Continue = $false
    }
    function Fail-UiTimeoutProbe {
        param($ErrorMessage, $Generation, $RequestId, $Kind, $Context)
        $script:TimeoutMessage = [string]$ErrorMessage
        $script:TimeoutSeen = -not [string]::IsNullOrWhiteSpace($script:TimeoutMessage)
        $script:TimeoutFrame.Continue = $false
    }
    $timeoutWatch = [Diagnostics.Stopwatch]::StartNew()
    [void](Start-TokenRaderBackgroundJob `
        -ScriptBlock { Start-Sleep -Seconds 5 } `
        -Kind 'TimeoutProbe' `
        -RequestId 8102L `
        -CompletionHandler 'Complete-UiTimeoutProbe' `
        -FailureHandler 'Fail-UiTimeoutProbe' `
        -TimeoutSeconds 1)
    [Windows.Threading.Dispatcher]::PushFrame($script:TimeoutFrame)
    $timeoutWatch.Stop()
    Assert-UiTest $script:TimeoutSeen ('timeout did not reach the main script failure handler; message=' + $script:TimeoutMessage)
    Assert-UiTest ($timeoutWatch.Elapsed.TotalMilliseconds -le 1200) ('timeout delivery took ' + $timeoutWatch.Elapsed.TotalMilliseconds + ' ms')

    Stop-UiTestJobs
    $script:State = @{ BackgroundJobs = @{} }
    $script:CancelledCallbacks = 0
    function Complete-UiCancelProbe { param($Payload, $Generation, $RequestId, $Kind, $Context); $script:CancelledCallbacks++ }
    function Fail-UiCancelProbe { param($ErrorMessage, $Generation, $RequestId, $Kind, $Context); $script:CancelledCallbacks++ }
    [void](Start-TokenRaderBackgroundJob `
        -ScriptBlock { Start-Sleep -Milliseconds 300; 'late' } `
        -Kind 'CancelProbe' `
        -RequestId 8103L `
        -CompletionHandler 'Complete-UiCancelProbe' `
        -FailureHandler 'Fail-UiCancelProbe')
    $cancelJob = $script:State.BackgroundJobs[8103L]
    $cancelWatch = [Diagnostics.Stopwatch]::StartNew()
    Request-TokenRaderBackgroundStop -Job $cancelJob
    $cancelWatch.Stop()
    Assert-UiTest ([bool]$cancelJob.CompletionDelivered) 'cancel did not suppress late completion'
    Assert-UiTest ($cancelWatch.Elapsed.TotalMilliseconds -le 100) ('cancel blocked for ' + $cancelWatch.Elapsed.TotalMilliseconds + ' ms')

    $script:CancelFrame = New-Object Windows.Threading.DispatcherFrame
    $script:CancelTimer = New-Object Windows.Threading.DispatcherTimer
    $script:CancelTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:CancelTimer.Add_Tick({
        $script:CancelTimer.Stop()
        $script:CancelFrame.Continue = $false
    })
    $script:CancelTimer.Start()
    [Windows.Threading.Dispatcher]::PushFrame($script:CancelFrame)
    Assert-UiTest ($script:CancelledCallbacks -eq 0) 'cancelled worker delivered a late callback'

    Write-Output ('UI_CALLBACK_TESTS_PASSED edition={0} version={1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
} finally {
    Stop-UiTestJobs
}
