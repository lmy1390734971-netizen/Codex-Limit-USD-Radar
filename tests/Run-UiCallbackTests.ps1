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
        'Complete-TokenRaderMeasurementBaseline')) {
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
    function Set-TokenRaderUiState {
        param([string]$NewState, [string]$StatusMessage = '')
        $script:State.UiState = $NewState
    }
    function Start-TokenRaderMeasurementBaselineAsync {
        param([Int64]$Generation, [Int64]$RequestId)
        $script:LifecycleBaselineRequest = $RequestId
    }
    function Start-TokenRaderIntervalComputeAsync {
        param($Baseline, [Int64]$Generation)
        $script:LifecycleIntervalStarted = $true
    }
    $script:LifecycleRefreshCalled = $false
    $script:LifecycleBaselineRequest = 0L
    $script:LifecycleIntervalStarted = $false
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
    Assert-UiTest $script:LifecycleIntervalStarted 'baseline completion did not start interval calculation'

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
