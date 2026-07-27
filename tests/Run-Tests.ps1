[CmdletBinding()]
param([switch]$Live)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "ASSERT FAILED: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-Near {
    param([double]$Expected, [double]$Actual, [double]$Tolerance, [string]$Message)
    if ([Math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw "ASSERT FAILED: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

function New-TestTokenRecord {
    param(
        [string]$Timestamp,
        [Int64]$TotalInput,
        [Int64]$TotalCached,
        [Int64]$TotalOutput,
        [Int64]$CallInput,
        [Int64]$CallCached,
        [Int64]$CallOutput
    )
    [ordered]@{
        timestamp = $Timestamp
        type = 'event_msg'
        payload = [ordered]@{
            type = 'token_count'
            info = [ordered]@{
                total_token_usage = [ordered]@{ input_tokens = $TotalInput; cached_input_tokens = $TotalCached; output_tokens = $TotalOutput; reasoning_output_tokens = 0; total_tokens = $TotalInput + $TotalOutput }
                last_token_usage = [ordered]@{ input_tokens = $CallInput; cached_input_tokens = $CallCached; output_tokens = $CallOutput; reasoning_output_tokens = 0; total_tokens = $CallInput + $CallOutput }
                model_context_window = 1050000
            }
        }
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$prices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')

$tempRoot = Join-Path $env:TEMP ('token-rader-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $fixturePath = Join-Path $tempRoot 'rollout-2026-07-14T00-00-00-00000000-0000-0000-0000-000000000001.jsonl'
    $records = @(
        [ordered]@{
            timestamp = '2026-07-14T00:00:00Z'
            type = 'session_meta'
            payload = [ordered]@{ id = '00000000-0000-0000-0000-000000000001'; model_provider = 'openai' }
        },
        [ordered]@{
            timestamp = '2026-07-14T00:00:01Z'
            type = 'turn_context'
            payload = [ordered]@{ model = 'gpt-5.6-sol' }
        },
        [ordered]@{
            timestamp = '2026-07-14T00:00:10Z'
            type = 'event_msg'
            payload = [ordered]@{
                type = 'token_count'
                info = [ordered]@{
                    total_token_usage = [ordered]@{ input_tokens = 350000; cached_input_tokens = 220000; output_tokens = 15000; reasoning_output_tokens = 5000; total_tokens = 365000 }
                    last_token_usage = [ordered]@{ input_tokens = 300000; cached_input_tokens = 200000; output_tokens = 10000; reasoning_output_tokens = 3000; total_tokens = 310000 }
                    model_context_window = 1050000
                }
                rate_limits = [ordered]@{
                    plan_type = 'pro'
                    primary = [ordered]@{ used_percent = 20.0; window_minutes = 300; resets_at = 1784000000 }
                    secondary = [ordered]@{ used_percent = 40.0; window_minutes = 10080; resets_at = 1784500000 }
                }
            }
        }
    )
    @($records | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $fixturePath -Encoding UTF8

    $snapshot = Get-TokenRaderUsageSnapshot -FilePath $fixturePath -Tail 100
    Assert-Equal 'gpt-5.6-sol' $snapshot.Model 'model parsing'
    Assert-Equal 220000 $snapshot.Task.Cached 'task cached input'
    Assert-Equal 130000 $snapshot.Task.Uncached 'task uncached input'
    Assert-Equal 15000 $snapshot.Task.Output 'task output'
    Assert-Equal 365000 $snapshot.Task.Total 'task total'
    Assert-Near 62.857142 $snapshot.Task.CacheHitRate 0.0001 'task cache hit rate'
    Assert-Equal 200000 $snapshot.Call.Cached 'call cached input'
    Assert-Equal 'pro' $snapshot.PlanType 'plan snapshot'
    Assert-Near 20.0 $snapshot.RateLimits.FiveHour.UsedPercent 0.0001 'five-hour usage parsing'
    Assert-Near 40.0 $snapshot.RateLimits.Weekly.UsedPercent 0.0001 'weekly usage parsing'

    $taskCost = Get-TokenRaderCost -Usage $snapshot.Task -Model $snapshot.Model -PricingDocument $prices -Scope task
    Assert-Equal $true $taskCost.Known 'known official price'
    Assert-Equal $false $taskCost.LongContextApplied 'task aggregate does not infer long context'
    Assert-Near 1.21 $taskCost.TotalCost 0.0000001 'task API equivalent cost'

    $callCost = Get-TokenRaderCost -Usage $snapshot.Call -Model $snapshot.Model -PricingDocument $prices -Scope call
    Assert-Equal $true $callCost.LongContextApplied 'call long-context rule'
    Assert-Near 1.65 $callCost.TotalCost 0.0000001 'call cost with long-context multipliers'

    $snapshotPrice = Resolve-TokenRaderPrice -Model 'gpt-5.4-mini-2026-03-17' -PricingDocument $prices
    Assert-Equal 'gpt-5.4-mini' $snapshotPrice.id 'snapshot model price resolution'
    $aliasPrice = Resolve-TokenRaderPrice -Model 'gpt-5.6' -PricingDocument $prices
    Assert-Equal 'gpt-5.6-sol' $aliasPrice.id 'model alias price resolution'
    $unknownCost = Get-TokenRaderCost -Usage $snapshot.Task -Model 'private-model-without-price' -PricingDocument $prices
    Assert-Equal $false $unknownCost.Known 'unknown models are not treated as free'

    $measurementRoot = Join-Path $tempRoot 'measurement-sessions'
    New-Item -ItemType Directory -Path $measurementRoot | Out-Null
    $existingPath = Join-Path $measurementRoot 'rollout-existing.jsonl'
    $initialMeasurementRecords = @(
        [ordered]@{ timestamp = '2026-07-14T01:00:00Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-sol' } },
        [ordered]@{
            timestamp = '2026-07-14T01:00:01Z'; type = 'event_msg'; payload = [ordered]@{
                type = 'token_count'; info = [ordered]@{
                    total_token_usage = [ordered]@{ input_tokens = 1000; cached_input_tokens = 500; output_tokens = 100; reasoning_output_tokens = 20; total_tokens = 1100 }
                    last_token_usage = [ordered]@{ input_tokens = 1000; cached_input_tokens = 500; output_tokens = 100; reasoning_output_tokens = 20; total_tokens = 1100 }
                    model_context_window = 1050000
                }
                rate_limits = [ordered]@{
                    primary = [ordered]@{ used_percent = 10.0; window_minutes = 300; resets_at = 1784000000 }
                    secondary = [ordered]@{ used_percent = 20.0; window_minutes = 10080; resets_at = 1784500000 }
                }
            }
        }
    )
    @($initialMeasurementRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $existingPath -Encoding UTF8
    $measurementBaseline = New-TokenRaderMeasurementBaseline -SessionsRoot $measurementRoot
    Assert-Equal 1 @($measurementBaseline.Files).Count 'measurement baseline file count'

    $continuedRecord = [ordered]@{
        timestamp = '2026-07-14T01:01:00Z'; type = 'event_msg'; payload = [ordered]@{
            type = 'token_count'; info = [ordered]@{
                total_token_usage = [ordered]@{ input_tokens = 3000; cached_input_tokens = 2000; output_tokens = 500; reasoning_output_tokens = 80; total_tokens = 3500 }
                last_token_usage = [ordered]@{ input_tokens = 2000; cached_input_tokens = 1500; output_tokens = 400; reasoning_output_tokens = 60; total_tokens = 2400 }
                model_context_window = 1050000
            }
            rate_limits = [ordered]@{
                primary = [ordered]@{ used_percent = 12.0; window_minutes = 300; resets_at = 1784000000 }
                secondary = [ordered]@{ used_percent = 21.0; window_minutes = 10080; resets_at = 1784500000 }
            }
        }
    }
    ($continuedRecord | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $existingPath -Encoding UTF8

    $newPath = Join-Path $measurementRoot 'rollout-new.jsonl'
    $newMeasurementRecords = @(
        [ordered]@{ timestamp = '2026-07-14T01:00:30Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-sol' } },
        [ordered]@{
            timestamp = '2026-07-14T01:01:10Z'; type = 'event_msg'; payload = [ordered]@{
                type = 'token_count'; info = [ordered]@{
                    total_token_usage = [ordered]@{ input_tokens = 1000; cached_input_tokens = 0; output_tokens = 100; reasoning_output_tokens = 10; total_tokens = 1100 }
                    last_token_usage = [ordered]@{ input_tokens = 1000; cached_input_tokens = 0; output_tokens = 100; reasoning_output_tokens = 10; total_tokens = 1100 }
                    model_context_window = 1050000
                }
                rate_limits = [ordered]@{
                    primary = [ordered]@{ used_percent = 12.0; window_minutes = 300; resets_at = 1784000000 }
                    secondary = [ordered]@{ used_percent = 21.0; window_minutes = 10080; resets_at = 1784500000 }
                }
            }
        }
    )
    @($newMeasurementRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $newPath -Encoding UTF8

    $intervalResult = Get-TokenRaderIntervalResult -Baseline $measurementBaseline -PricingDocument $prices
    Assert-Equal 1500 $intervalResult.Usage.Cached 'interval cached delta across sessions'
    Assert-Equal 1500 $intervalResult.Usage.Uncached 'interval uncached delta across sessions'
    Assert-Equal 500 $intervalResult.Usage.Output 'interval output delta across sessions'
    Assert-Equal 3500 $intervalResult.Usage.Total 'interval total delta across sessions'
    Assert-Near 50.0 $intervalResult.Usage.CacheHitRate 0.0001 'interval cache hit rate'
    Assert-Equal 2 $intervalResult.ChangedSessions 'interval changed session count'
    Assert-Near 0.02325 $intervalResult.TotalCost 0.0000001 'interval multi-session API cost'
    Assert-Equal $true $intervalResult.CostComplete 'interval cost completeness'
    Assert-Near 12.0 $intervalResult.RateLimits.FiveHour.UsedPercent 0.0001 'interval ending five-hour usage'
    Assert-Near 21.0 $intervalResult.RateLimits.Weekly.UsedPercent 0.0001 'interval ending weekly usage'
    $quotaEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $measurementBaseline.RateLimits -EndRateLimits $intervalResult.RateLimits -IntervalCost $intervalResult.TotalCost -CostComplete $intervalResult.CostComplete
    Assert-Near 1.1625 $quotaEstimate.FiveHour.TotalUsd 0.0000001 'five-hour inferred USD quota'
    Assert-Near 2.325 $quotaEstimate.Weekly.TotalUsd 0.0000001 'weekly inferred USD quota'

    # A real Codex task tree copies parent token_count history into sibling subagent
    # logs. Only exact copies within the same root task may be deduplicated; an
    # independent conversation with the same counters must still be counted.
    $dedupeRoot = Join-Path $tempRoot 'dedupe-sessions'
    New-Item -ItemType Directory -Path $dedupeRoot | Out-Null
    $parentId = '10000000-0000-0000-0000-000000000001'
    $parentPath = Join-Path $dedupeRoot ('rollout-parent-' + $parentId + '.jsonl')
    $parentInitial = @(
        [ordered]@{ timestamp = '2026-07-14T02:00:00Z'; type = 'session_meta'; payload = [ordered]@{ id = $parentId; cwd = 'C:\work\Token Rader'; model_provider = 'openai' } },
        [ordered]@{ timestamp = '2026-07-14T02:00:01Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.5' } },
        (New-TestTokenRecord -Timestamp '2026-07-14T02:00:02Z' -TotalInput 1000 -TotalCached 0 -TotalOutput 100 -CallInput 1000 -CallCached 0 -CallOutput 100)
    )
    @($parentInitial | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $parentPath -Encoding UTF8
    $dedupeBaseline = New-TokenRaderMeasurementBaseline -SessionsRoot $dedupeRoot
    (New-TestTokenRecord -Timestamp '2026-07-14T02:01:00Z' -TotalInput 2000 -TotalCached 0 -TotalOutput 200 -CallInput 1000 -CallCached 0 -CallOutput 100 | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $parentPath -Encoding UTF8

    $childSpecs = @(
        [pscustomobject]@{ Id = '20000000-0000-0000-0000-000000000001'; Model = 'gpt-5.6-sol'; TotalInput = 2500; TotalOutput = 250; CallInput = 500; CallOutput = 50 },
        [pscustomobject]@{ Id = '20000000-0000-0000-0000-000000000002'; Model = 'gpt-5.5'; TotalInput = 2600; TotalOutput = 260; CallInput = 600; CallOutput = 60 }
    )
    foreach ($spec in $childSpecs) {
        $childPath = Join-Path $dedupeRoot ('rollout-child-' + $spec.Id + '.jsonl')
        $childRecords = @(
            [ordered]@{ timestamp = '2026-07-14T02:01:05Z'; type = 'session_meta'; payload = [ordered]@{ id = $spec.Id; cwd = 'C:\work\Token Rader'; parent_thread_id = $parentId; forked_from_id = $parentId; model_provider = 'openai' } },
            [ordered]@{ timestamp = '2026-07-14T02:01:06Z'; type = 'turn_context'; payload = [ordered]@{ model = $spec.Model } },
            (New-TestTokenRecord -Timestamp '2026-07-14T02:01:07Z' -TotalInput 1000 -TotalCached 0 -TotalOutput 100 -CallInput 1000 -CallCached 0 -CallOutput 100),
            (New-TestTokenRecord -Timestamp '2026-07-14T02:01:08Z' -TotalInput 2000 -TotalCached 0 -TotalOutput 200 -CallInput 1000 -CallCached 0 -CallOutput 100),
            (New-TestTokenRecord -Timestamp '2026-07-14T02:01:09Z' -TotalInput $spec.TotalInput -TotalCached 0 -TotalOutput $spec.TotalOutput -CallInput $spec.CallInput -CallCached 0 -CallOutput $spec.CallOutput)
        )
        @($childRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $childPath -Encoding UTF8
    }

    $independentId = '30000000-0000-0000-0000-000000000001'
    $independentPath = Join-Path $dedupeRoot ('rollout-independent-' + $independentId + '.jsonl')
    $independentRecords = @(
        [ordered]@{ timestamp = '2026-07-14T02:01:10Z'; type = 'session_meta'; payload = [ordered]@{ id = $independentId; cwd = 'C:\work\Other Project'; model_provider = 'openai' } },
        [ordered]@{ timestamp = '2026-07-14T02:01:11Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.4' } },
        (New-TestTokenRecord -Timestamp '2026-07-14T02:01:12Z' -TotalInput 2000 -TotalCached 0 -TotalOutput 200 -CallInput 1000 -CallCached 0 -CallOutput 100)
    )
    @($independentRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $independentPath -Encoding UTF8

    $dedupeResult = Get-TokenRaderIntervalResult -Baseline $dedupeBaseline -PricingDocument $prices
    Assert-Equal 3100 $dedupeResult.Usage.Input 'global interval includes task-tree project plus independent other project'
    Assert-Equal 310 $dedupeResult.Usage.Output 'deduplicated task-tree output plus independent conversation'
    Assert-Equal 4 $dedupeResult.CountedEvents 'unique call event count'
    Assert-Equal 2 $dedupeResult.DuplicateEventsDropped 'shared parent events dropped across siblings'
    Assert-Equal 2 $dedupeResult.InheritedEventsDropped 'pre-baseline inherited events dropped in children'
    Assert-Equal 4 $dedupeResult.ChangedSessions 'active files retained after deduplication'
    Assert-Equal 3 @($dedupeResult.Models).Count 'per-call model attribution across task tree'
    Assert-Near 0.0208 $dedupeResult.TotalCost 0.0000001 'deduplicated per-model API cost'
    $childMetadata = Get-TokenRaderSessionMetadata -FilePath $childPath
    Assert-Equal $parentId $childMetadata.ParentThreadId 'child metadata exposes parent task id'
    Assert-Equal $parentId $childMetadata.ForkedFromId 'child metadata exposes fork source id'
    Assert-Equal 'C:\work\Token Rader' $childMetadata.Cwd 'child metadata exposes project cwd'

    $projects = @(Get-TokenRaderProjects -SessionsRoot $dedupeRoot)
    Assert-Equal 2 $projects.Count 'project discovery groups sessions by cwd'
    $tokenRaderProject = $projects | Where-Object { $_.ProjectName -eq 'Token Rader' } | Select-Object -First 1
    Assert-Equal 3 $tokenRaderProject.SessionCount 'project session count'
    $projectResult = Get-TokenRaderProjectResult -Project $tokenRaderProject -SessionsRoot $dedupeRoot -PricingDocument $prices
    Assert-Equal 3100 $projectResult.Usage.Input 'project total excludes another project and deduplicates task tree'
    Assert-Equal 310 $projectResult.Usage.Output 'project output total'
    Assert-Equal 4 $projectResult.CountedEvents 'project unique event count'
    Assert-Equal 4 $projectResult.DuplicateEventsDropped 'project duplicated inherited event count'
    Assert-Equal 2 @($projectResult.Models).Count 'project per-call models'
    Assert-Near 0.0248 $projectResult.TotalCost 0.0000001 'project multi-model API cost'

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    [xml]$xaml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'MainWindow.xaml')
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    foreach ($controlName in @('ProjectComboBox', 'ScopeComboBox', 'SessionListBox', 'StartMeasureButton', 'StopMeasureButton', 'ViewIntervalButton', 'IntervalStatusText', 'ModelMetricText', 'CachedMetricText', 'UncachedMetricText', 'OutputMetricText', 'TotalMetricText', 'HitRateMetricText', 'UsdCostText', 'FiveHourUsageText', 'FiveHourDollarText', 'WeeklyUsageText', 'WeeklyDollarText', 'PricingDataGrid')) {
        if ($null -eq $window.FindName($controlName)) { throw "ASSERT FAILED: missing XAML control $controlName" }
    }
    $window.Close()

    if ($Live) {
        $paths = Get-TokenRaderPaths -ProjectRoot $projectRoot
        $liveSession = Get-TokenRaderSessionFiles -SessionsRoot $paths.SessionsRoot | Select-Object -First 1
        if ($null -eq $liveSession) { throw 'LIVE CHECK FAILED: no local Codex session logs found.' }
        $liveSnapshot = Get-TokenRaderUsageSnapshot -FilePath $liveSession.FilePath
        if ($null -eq $liveSnapshot) { throw 'LIVE CHECK FAILED: latest log has no readable token_count in the scan window.' }
        $livePrice = Resolve-TokenRaderPrice -Model $liveSnapshot.Model -PricingDocument $prices
        Write-Output ('LIVE_OK model={0} price={1}' -f $liveSnapshot.Model, ($null -ne $livePrice))
    }

    Write-Output 'ALL_TESTS_PASSED'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolved = (Resolve-Path -LiteralPath $tempRoot).Path
        $tempResolved = (Resolve-Path -LiteralPath $env:TEMP).Path
        if ($resolved.StartsWith($tempResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}
