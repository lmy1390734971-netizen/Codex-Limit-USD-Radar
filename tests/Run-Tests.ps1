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
    Assert-Equal '2026-08-02' ([string]$prices.verifiedAt) 'pricing verification date'
    $terraPrice = Resolve-TokenRaderPrice -Model 'gpt-5.6-terra' -PricingDocument $prices
    Assert-Near 2.0 $terraPrice.input 0.0000001 'Terra official input price'
    Assert-Near 0.2 $terraPrice.cachedInput 0.0000001 'Terra official cached input price'
    Assert-Near 12.0 $terraPrice.output 0.0000001 'Terra official output price'
    $lunaPrice = Resolve-TokenRaderPrice -Model 'gpt-5.6-luna' -PricingDocument $prices
    Assert-Near 0.2 $lunaPrice.input 0.0000001 'Luna official input price'
    Assert-Near 0.02 $lunaPrice.cachedInput 0.0000001 'Luna official cached input price'
    Assert-Near 1.2 $lunaPrice.output 0.0000001 'Luna official output price'
    $customUnitPrices = [pscustomobject]@{ unitTokens = 1000; models = @($prices.models) }
    $customUnitUsage = [pscustomobject]@{ Input = 1000; Uncached = 1000; Cached = 0; Output = 0 }
    $customUnitCost = Get-TokenRaderCost -Usage $customUnitUsage -Model 'gpt-5.6-sol' -PricingDocument $customUnitPrices
    Assert-Near 5.0 $customUnitCost.TotalCost 0.0000001 'pricing document unitTokens is honored'
    $unknownCost = Get-TokenRaderCost -Usage $snapshot.Task -Model 'private-model-without-price' -PricingDocument $prices
    Assert-Equal $false $unknownCost.Known 'unknown models are not treated as free'

    $mixedPath = Join-Path $tempRoot 'rollout-mixed-model.jsonl'
    $mixedRecords = @(
        [ordered]@{ timestamp = '2026-07-14T00:00:00Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-terra' } },
        (New-TestTokenRecord -Timestamp '2026-07-14T00:00:01Z' -TotalInput 1000000 -TotalCached 200000 -TotalOutput 100000 -CallInput 1000000 -CallCached 200000 -CallOutput 100000),
        [ordered]@{ timestamp = '2026-07-14T00:00:02Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-luna' } },
        (New-TestTokenRecord -Timestamp '2026-07-14T00:00:03Z' -TotalInput 2000000 -TotalCached 700000 -TotalOutput 200000 -CallInput 1000000 -CallCached 500000 -CallOutput 100000)
    )
    @($mixedRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $mixedPath -Encoding UTF8
    $mixedResult = Get-TokenRaderSessionResult -FilePath $mixedPath -SessionsRoot $tempRoot -PricingDocument $prices
    Assert-Equal 2 @($mixedResult.Models).Count 'task supports per-call mixed-model pricing'
    Assert-Equal 2 @($mixedResult.Items | Where-Object { $_.LongContext }).Count 'task applies per-call long-context pricing'
    Assert-Near 5.48 $mixedResult.TotalCost 0.0000001 'task mixed-model API cost'

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
    $tokenRaderProjectPath = Join-Path $tempRoot 'Token Rader'
    $otherProjectPath = Join-Path $tempRoot 'Other Project'
    $parentId = '10000000-0000-0000-0000-000000000001'
    $parentPath = Join-Path $dedupeRoot ('rollout-parent-' + $parentId + '.jsonl')
    $parentInitial = @(
        [ordered]@{ timestamp = '2026-07-14T02:00:00Z'; type = 'session_meta'; payload = [ordered]@{ id = $parentId; cwd = $tokenRaderProjectPath; model_provider = 'openai' } },
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
            [ordered]@{ timestamp = '2026-07-14T02:01:05Z'; type = 'session_meta'; payload = [ordered]@{ id = $spec.Id; cwd = $tokenRaderProjectPath; parent_thread_id = $parentId; forked_from_id = $parentId; model_provider = 'openai' } },
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
        [ordered]@{ timestamp = '2026-07-14T02:01:10Z'; type = 'session_meta'; payload = [ordered]@{ id = $independentId; cwd = $otherProjectPath; model_provider = 'openai' } },
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
    Assert-Equal $tokenRaderProjectPath $childMetadata.Cwd 'child metadata exposes project cwd'

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

    # --- Runspace round-trip equivalence ---
    # The desktop UI runs interval computation in a background runspace; the
    # serialized result must be identical to a direct in-process computation.
    $computeModulePath = Join-Path $projectRoot 'TokenRader.Core.psm1'
    $computePricingPath = Join-Path $projectRoot 'pricing.json'
    $computePs = [powershell]::Create()
    try {
        [void]$computePs.AddScript('param($Baseline, $PricingPath, $ModulePath) Set-StrictMode -Version Latest; $ErrorActionPreference = ''Stop''; Import-Module $ModulePath -Force; $prices = Get-TokenRaderPrices -PricingPath $PricingPath; Get-TokenRaderIntervalResult -Baseline $Baseline -PricingDocument $prices')
        [void]$computePs.AddParameter('Baseline', $measurementBaseline)
        [void]$computePs.AddParameter('PricingPath', $computePricingPath)
        [void]$computePs.AddParameter('ModulePath', $computeModulePath)
        $computeOutput = @($computePs.Invoke())
        Assert-Equal 1 $computeOutput.Count 'runspace interval compute returns one object'
        $remoteResult = $computeOutput[0]
        $directResult = Get-TokenRaderIntervalResult -Baseline $measurementBaseline -PricingDocument $prices
        Assert-Equal $directResult.Usage.Input $remoteResult.Usage.Input 'runspace usage input'
        Assert-Equal $directResult.Usage.Cached $remoteResult.Usage.Cached 'runspace usage cached'
        Assert-Equal $directResult.Usage.Uncached $remoteResult.Usage.Uncached 'runspace usage uncached'
        Assert-Equal $directResult.Usage.Output $remoteResult.Usage.Output 'runspace usage output'
        Assert-Equal $directResult.Usage.Total $remoteResult.Usage.Total 'runspace usage total'
        Assert-Near $directResult.Usage.CacheHitRate $remoteResult.Usage.CacheHitRate 0.0001 'runspace cache hit rate'
        Assert-Near $directResult.TotalCost $remoteResult.TotalCost 0.0000001 'runspace total cost'
        Assert-Equal $directResult.CostComplete $remoteResult.CostComplete 'runspace cost completeness'
        Assert-Equal $directResult.CountedEvents $remoteResult.CountedEvents 'runspace counted events'
        Assert-Equal $directResult.DuplicateEventsDropped $remoteResult.DuplicateEventsDropped 'runspace duplicate events'
        Assert-Equal $directResult.InheritedEventsDropped $remoteResult.InheritedEventsDropped 'runspace inherited events'
        Assert-Equal $directResult.ChangedSessions $remoteResult.ChangedSessions 'runspace changed sessions'
        Assert-Equal $directResult.Models.Count $remoteResult.Models.Count 'runspace model count'
        Assert-Equal $directResult.Signature $remoteResult.Signature 'runspace signature'
        Assert-Equal $directResult.BytesRead $remoteResult.BytesRead 'runspace bytes read'
        Assert-Equal $true ($remoteResult.StartedAt -is [DateTimeOffset]) 'runspace preserves DateTimeOffset'
        Assert-Equal $true ($remoteResult.RateLimits.ObservedAt -is [DateTimeOffset]) 'runspace preserves rate limit timestamp'
        Assert-Near $directResult.RateLimits.FiveHour.UsedPercent $remoteResult.RateLimits.FiveHour.UsedPercent 0.0001 'runspace five-hour usage'
        Assert-Near $directResult.RateLimits.Weekly.UsedPercent $remoteResult.RateLimits.Weekly.UsedPercent 0.0001 'runspace weekly usage'
    } finally {
        $computePs.Dispose()
    }

    # --- Event cache and baseline snapshot cache equivalence ---
    $cacheRoot = Join-Path $tempRoot 'cache-sessions'
    New-Item -ItemType Directory -Path $cacheRoot | Out-Null
    $cachePath = Join-Path $cacheRoot 'rollout-cache.jsonl'
    $cacheInitial = @(
        [ordered]@{ timestamp = '2026-07-14T03:00:00Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-sol' } },
        (New-TestTokenRecord -Timestamp '2026-07-14T03:00:01Z' -TotalInput 1000 -TotalCached 200 -TotalOutput 100 -CallInput 1000 -CallCached 200 -CallOutput 100)
    )
    @($cacheInitial | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $cachePath -Encoding UTF8
    $cacheBaseline = New-TokenRaderMeasurementBaseline -SessionsRoot $cacheRoot

    (New-TestTokenRecord -Timestamp '2026-07-14T03:00:02Z' -TotalInput 2000 -TotalCached 400 -TotalOutput 200 -CallInput 1000 -CallCached 200 -CallOutput 100 | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $cachePath -Encoding UTF8
    $twoRecordLength = (Get-Item -LiteralPath $cachePath).Length

    $cacheFirst = Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices -BaselineSnapshots @{} -EventCache @{}
    Assert-Equal 1 $cacheFirst.CountedEvents 'cache first compute counts the appended call'
    Assert-Equal 1 @($cacheFirst.BaselineSnapshots.Keys).Count 'baseline snapshot cache populated'
    Assert-Equal 1 @($cacheFirst.EventCache.Keys).Count 'event cache populated'

    (New-TestTokenRecord -Timestamp '2026-07-14T03:00:03Z' -TotalInput 3000 -TotalCached 600 -TotalOutput 300 -CallInput 1000 -CallCached 200 -CallOutput 100 | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $cachePath -Encoding UTF8

    $cacheSecond = Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices -BaselineSnapshots $cacheFirst.BaselineSnapshots -EventCache $cacheFirst.EventCache
    $cacheFresh = Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices
    Assert-Equal $cacheFresh.Usage.Input $cacheSecond.Usage.Input 'cached recompute input equals fresh'
    Assert-Equal $cacheFresh.Usage.Cached $cacheSecond.Usage.Cached 'cached recompute cached equals fresh'
    Assert-Equal $cacheFresh.Usage.Output $cacheSecond.Usage.Output 'cached recompute output equals fresh'
    Assert-Equal $cacheFresh.Usage.Total $cacheSecond.Usage.Total 'cached recompute total equals fresh'
    Assert-Near $cacheFresh.Usage.CacheHitRate $cacheSecond.Usage.CacheHitRate 0.0001 'cached recompute hit rate equals fresh'
    Assert-Equal $cacheFresh.CountedEvents $cacheSecond.CountedEvents 'cached recompute events equals fresh'
    Assert-Equal $cacheFresh.DuplicateEventsDropped $cacheSecond.DuplicateEventsDropped 'cached recompute duplicates equals fresh'
    Assert-Equal $cacheFresh.InheritedEventsDropped $cacheSecond.InheritedEventsDropped 'cached recompute inherited equals fresh'
    Assert-Near $cacheFresh.TotalCost $cacheSecond.TotalCost 0.0000001 'cached recompute cost equals fresh'
    Assert-Equal 2 $cacheSecond.CountedEvents 'cached recompute counts both appended calls'

    $cacheThird = Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices -BaselineSnapshots $cacheSecond.BaselineSnapshots -EventCache $cacheSecond.EventCache
    Assert-Equal $cacheFresh.Usage.Input $cacheThird.Usage.Input 'idempotent cached recompute input'
    Assert-Equal $cacheFresh.Usage.Total $cacheThird.Usage.Total 'idempotent cached recompute total'
    Assert-Near $cacheFresh.TotalCost $cacheThird.TotalCost 0.0000001 'idempotent cached recompute cost'

    # --- EndOffsets freeze equivalence ---
    $frozen = Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices -EndOffsets @{ $cachePath = $twoRecordLength }
    Assert-Equal 1 $frozen.CountedEvents 'end offsets freeze counted events'
    Assert-Equal $cacheFirst.Usage.Input $frozen.Usage.Input 'end offsets freeze input'
    Assert-Near $cacheFirst.TotalCost $frozen.TotalCost 0.0000001 'end offsets freeze cost'
    $baselineLength = [Int64]$cacheBaseline.Files[0].Length
    $frozenZero = Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices -EndOffsets @{ $cachePath = $baselineLength }
    Assert-Equal 0 $frozenZero.CountedEvents 'end offsets at baseline freeze counts nothing'

    # --- Session tree signature stability ---
    $sigBefore = Get-TokenRaderSessionTreeSignature -SessionsRoot $cacheRoot
    $sigAgain = Get-TokenRaderSessionTreeSignature -SessionsRoot $cacheRoot
    Assert-Equal $sigBefore $sigAgain 'signature identical for unchanged tree'
    (New-TestTokenRecord -Timestamp '2026-07-14T03:00:04Z' -TotalInput 4000 -TotalCached 800 -TotalOutput 400 -CallInput 1000 -CallCached 200 -CallOutput 100 | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $cachePath -Encoding UTF8
    $sigAfter = Get-TokenRaderSessionTreeSignature -SessionsRoot $cacheRoot
    Assert-Equal $false ($sigBefore -eq $sigAfter) 'signature changes after append'
    $sigFromResult = [string](Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices).Signature
    Assert-Equal $sigAfter $sigFromResult 'interval result signature matches tree signature'

    # --- Fallback full-JSON parsing equivalence (non-canonical shapes) ---
    $fallbackPath = Join-Path $tempRoot 'rollout-fallback.jsonl'
    $fallbackRecords = @(
        [ordered]@{ timestamp = '2026-07-14T05:00:00Z'; type = 'turn_context'; payload = [ordered]@{ note = [ordered]@{ a = 1 }; model = 'gpt-5.6-luna' } },
        [ordered]@{
            timestamp = '2026-07-14T05:00:01Z'
            type = 'event_msg'
            payload = [ordered]@{
                app = 'codex'
                type = 'token_count'
                extra = [ordered]@{ x = 1 }
                info = [ordered]@{
                    total_token_usage = [ordered]@{ input_tokens = 3000; cached_input_tokens = 1000; output_tokens = 300; reasoning_output_tokens = 50; total_tokens = 3300 }
                    last_token_usage = [ordered]@{ input_tokens = 3000; cached_input_tokens = 1000; output_tokens = 300; reasoning_output_tokens = 50; total_tokens = 3300 }
                    model_context_window = 1050000
                }
                rate_limits = [ordered]@{
                    plan_type = 'pro'
                    primary = [ordered]@{ used_percent = 33.3; window_minutes = 300; resets_at = 1784000000 }
                    secondary = [ordered]@{ used_percent = 55.5; window_minutes = 10080; resets_at = 1784500000 }
                }
            }
        }
    )
    @($fallbackRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $fallbackPath -Encoding UTF8
    $fallbackResult = Get-TokenRaderSessionResult -FilePath $fallbackPath -SessionsRoot $tempRoot -PricingDocument $prices
    Assert-Equal 1 $fallbackResult.CountedEvents 'fallback parsing counted events'
    Assert-Equal 'gpt-5.6-luna' $fallbackResult.Models[0] 'fallback model binding'
    Assert-Equal 3000 $fallbackResult.Usage.Input 'fallback usage input'
    Assert-Equal 1000 $fallbackResult.Usage.Cached 'fallback usage cached'
    Assert-Equal 300 $fallbackResult.Usage.Output 'fallback usage output'
    Assert-Near 33.3 $fallbackResult.RateLimits.FiveHour.UsedPercent 0.0001 'fallback five-hour usage'
    Assert-Near 55.5 $fallbackResult.RateLimits.Weekly.UsedPercent 0.0001 'fallback weekly usage'

    # --- Large synthetic log correctness (exercises the fast parse path) ---
    $largeRoot = Join-Path $tempRoot 'large-sessions'
    New-Item -ItemType Directory -Path $largeRoot | Out-Null
    $largePath = Join-Path $largeRoot 'rollout-large.jsonl'
    $largeInitial = '{"timestamp":"2026-07-14T04:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}' + "`n" + '{"timestamp":"2026-07-14T04:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":1010},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":1010},"model_context_window":1050000}}}' + "`n"
    [System.IO.File]::WriteAllText($largePath, $largeInitial, (New-Object System.Text.UTF8Encoding($false)))
    $largeBaseline = New-TokenRaderMeasurementBaseline -SessionsRoot $largeRoot
    $largeCount = 5000
    $largeBuilder = New-Object System.Text.StringBuilder
    for ($i = 1; $i -le $largeCount; $i++) {
        [void]$largeBuilder.AppendLine(('{{"timestamp":"2026-07-14T04:00:{0:D2}Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":{1},"cached_input_tokens":{2},"output_tokens":{3},"reasoning_output_tokens":{4},"total_tokens":{5}}},"last_token_usage":{{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":1010}},"model_context_window":1050000}}}}}}' -f ($i % 60), ($i * 1000), ($i * 100), ($i * 10), ($i * 2), ($i * 1010)))
    }
    [System.IO.File]::AppendAllText($largePath, $largeBuilder.ToString(), (New-Object System.Text.UTF8Encoding($false)))

    $largeStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $largeResult = Get-TokenRaderIntervalResult -Baseline $largeBaseline -PricingDocument $prices
    $largeStopwatch.Stop()
    Assert-Equal $largeCount $largeResult.CountedEvents 'large fixture counted events'
    Assert-Equal 5000000 $largeResult.Usage.Input 'large fixture input'
    Assert-Equal 500000 $largeResult.Usage.Cached 'large fixture cached'
    Assert-Equal 4500000 $largeResult.Usage.Uncached 'large fixture uncached'
    Assert-Equal 50000 $largeResult.Usage.Output 'large fixture output'
    Assert-Equal 5050000 $largeResult.Usage.Total 'large fixture total'
    Assert-Near 24.25 $largeResult.TotalCost 0.0000001 'large fixture API cost'
    Assert-Equal $true $largeResult.CostComplete 'large fixture cost completeness'
    Write-Output ('LARGE_OK events={0} ms={1}' -f $largeCount, $largeStopwatch.ElapsedMilliseconds)

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
