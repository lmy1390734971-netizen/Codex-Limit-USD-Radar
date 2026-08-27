[CmdletBinding()]
param([switch]$Live)

# The XAML regression check instantiates WPF controls, which behave
# consistently only on a single-threaded apartment. Relaunch ourselves in an
# STA host exactly like the documented app command so CI and local runs share
# the same apartment model (GitHub Actions invokes the script without -STA).
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $PSCommandPath + '"'))
    if ($Live) { $arguments += '-Live' }
    $hostExecutable = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    Start-Process -FilePath $hostExecutable -ArgumentList $arguments -Wait -NoNewWindow
    exit $LASTEXITCODE
}

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
        [Int64]$CallOutput,
        $RateLimits = $null
    )
    $record = [ordered]@{
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
    if ($null -ne $RateLimits) { $record.payload['rate_limits'] = $RateLimits }
    return $record
}

function New-TestRawRateLimits {
    param(
        [double]$FiveHourUsed,
        [double]$WeeklyUsed,
        $FiveHourReset,
        $WeeklyReset,
        [string]$PlanType = 'pro',
        [int]$FiveHourWindow = 300,
        [int]$WeeklyWindow = 10080
    )
    $primary = [ordered]@{ used_percent = $FiveHourUsed; window_minutes = $FiveHourWindow }
    $secondary = [ordered]@{ used_percent = $WeeklyUsed; window_minutes = $WeeklyWindow }
    if ($null -ne $FiveHourReset) { $primary['resets_at'] = $FiveHourReset }
    if ($null -ne $WeeklyReset) { $secondary['resets_at'] = $WeeklyReset }
    [ordered]@{
        plan_type = $PlanType
        primary = $primary
        secondary = $secondary
    }
}

function New-TestQuotaRateLimits {
    param(
        [double]$FiveHourUsed,
        [double]$WeeklyUsed,
        [DateTimeOffset]$FiveHourReset,
        [DateTimeOffset]$WeeklyReset,
        [string]$PlanType = 'pro',
        [int]$FiveHourWindow = 300,
        [int]$WeeklyWindow = 10080
    )
    [pscustomobject]@{
        ObservedAt = [DateTimeOffset]::Parse('2026-07-14T06:00:00Z')
        PlanType = $PlanType
        FiveHour = [pscustomobject]@{
            UsedPercent = $FiveHourUsed
            RemainingPercent = 100.0 - $FiveHourUsed
            WindowMinutes = $FiveHourWindow
            ResetsAt = $FiveHourReset
        }
        Weekly = [pscustomobject]@{
            UsedPercent = $WeeklyUsed
            RemainingPercent = 100.0 - $WeeklyUsed
            WindowMinutes = $WeeklyWindow
            ResetsAt = $WeeklyReset
        }
    }
}

function Select-TestIndexHandle {
    param([object[]]$Output)
    $candidate = $null
    foreach ($item in @($Output)) {
        if ($null -ne $item -and $null -ne $item.PSObject.Properties['DbPath']) { $candidate = $item }
    }
    return $candidate
}

function Select-TestIndexRow {
    param([object[]]$Output)
    foreach ($item in @($Output)) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Data.DataTable]) {
            if ($item.Rows.Count -gt 0) { return $item.Rows[0] }
            continue
        }
        if ($null -ne $item.PSObject.Properties['total_input']) { return $item }
    }
    return $null
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$prices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')
Assert-Equal 'USD' ([string]$prices.currency) 'pricing currency metadata'
Assert-Equal 1000000 ([Int64]$prices.unitTokens) 'pricing unit metadata'
Assert-Equal 'OpenAI API Standard processing' ([string]$prices.priceType) 'pricing type metadata'
foreach ($pricingModelId in @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-5.5', 'gpt-5.4-mini', 'gpt-5.4')) {
    $pricingModel = @($prices.models | Where-Object { [string]$_.id -eq $pricingModelId })[0]
    if ($null -eq $pricingModel) { throw "ASSERT FAILED: pricing entry missing for $pricingModelId" }
    if ([string]::IsNullOrWhiteSpace([string]$pricingModel.source)) { throw "ASSERT FAILED: pricing source missing for $pricingModelId" }
    if ([double]$pricingModel.input -lt 0 -or [double]$pricingModel.cachedInput -lt 0 -or [double]$pricingModel.output -lt 0) {
        throw "ASSERT FAILED: pricing values must be non-negative for $pricingModelId"
    }
}

$tempRoot = Join-Path $env:TEMP ('token-rader-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
# Resolve to the canonical long path: $env:TEMP may contain an 8.3 short name
# (e.g. RUNNER~1) on CI runners, while Get-ChildItem returns the long form.
$tempRoot = (Get-Item -LiteralPath $tempRoot).FullName
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
    Assert-Near 0.908 $taskCost.TotalCost 0.0000001 'task API equivalent cost'

    $callCost = Get-TokenRaderCost -Usage $snapshot.Call -Model $snapshot.Model -PricingDocument $prices -Scope call
    Assert-Equal $true $callCost.LongContextApplied 'call long-context rule'
    Assert-Near 1.26 $callCost.TotalCost 0.0000001 'call cost with long-context multipliers'

    $snapshotPrice = Resolve-TokenRaderPrice -Model 'gpt-5.4-mini-2026-03-17' -PricingDocument $prices
    Assert-Equal 'gpt-5.4-mini' $snapshotPrice.id 'snapshot model price resolution'
    $aliasPrice = Resolve-TokenRaderPrice -Model 'gpt-5.6' -PricingDocument $prices
    Assert-Equal 'gpt-5.6-sol' $aliasPrice.id 'model alias price resolution'
    Assert-Equal '2026-08-28' ([string]$prices.verifiedAt) 'pricing verification date'
    Assert-Equal 'Promotional' ([string]$aliasPrice.pricingStatus) 'Sol promotional price status'
    Assert-Equal '2026-11-21' ([string]$aliasPrice.promotionalPriceValidThroughAtLeast) 'Sol promotional price minimum validity'
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
    Assert-Near 4.0 $customUnitCost.TotalCost 0.0000001 'pricing document unitTokens is honored'
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
    Assert-Near 0.0166 $intervalResult.TotalCost 0.0000001 'interval multi-session API cost'
    Assert-Equal $true $intervalResult.CostComplete 'interval cost completeness'
    Assert-Equal $true $intervalResult.PricingComplete 'interval pricing completeness'
    Assert-Equal $measurementBaseline.RateLimits.Weekly.UsedPercent $intervalResult.StartRateLimits.Weekly.UsedPercent 'interval start weekly snapshot'
    Assert-Near 12.0 $intervalResult.EndRateLimits.FiveHour.UsedPercent 0.0001 'interval end five-hour snapshot'
    Assert-Near 12.0 $intervalResult.RateLimits.FiveHour.UsedPercent 0.0001 'interval ending five-hour usage'
    Assert-Near 21.0 $intervalResult.RateLimits.Weekly.UsedPercent 0.0001 'interval ending weekly usage'
    $quotaEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $measurementBaseline.RateLimits -EndRateLimits $intervalResult.RateLimits -IntervalCost $intervalResult.TotalCost -CostComplete $intervalResult.CostComplete
    Assert-Near 0.83 $quotaEstimate.FiveHour.TotalUsd 0.0000001 'five-hour inferred USD quota'
    Assert-Near 1.66 $quotaEstimate.Weekly.TotalUsd 0.0000001 'weekly inferred USD quota'

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
    Assert-Near 0.0198 $dedupeResult.TotalCost 0.0000001 'deduplicated per-model API cost'
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
    Assert-Near 0.0238 $projectResult.TotalCost 0.0000001 'project multi-model API cost'

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
        Assert-Equal $directResult.PricingComplete $remoteResult.PricingComplete 'runspace pricing completeness'
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

    # --- Baseline snapshot cache and EndOffsets ---
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

    $cacheFirst = Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices -BaselineSnapshots @{}
    Assert-Equal 1 $cacheFirst.CountedEvents 'cache first compute counts the appended call'
    Assert-Equal 1 @($cacheFirst.BaselineSnapshots.Keys).Count 'baseline snapshot cache populated'
    $cacheAgain = Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices -BaselineSnapshots $cacheFirst.BaselineSnapshots
    Assert-Equal $cacheFirst.Usage.Input $cacheAgain.Usage.Input 'baseline snapshot reuse yields identical input'
    Assert-Equal $cacheFirst.CountedEvents $cacheAgain.CountedEvents 'baseline snapshot reuse yields identical events'
    Assert-Near $cacheFirst.TotalCost $cacheAgain.TotalCost 0.0000001 'baseline snapshot reuse yields identical cost'

    # --- EndOffsets freeze equivalence ---
    $frozen = Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices -EndOffsets @{ $cachePath = $twoRecordLength }
    Assert-Equal 1 $frozen.CountedEvents 'end offsets freeze counted events'
    Assert-Equal $cacheFirst.Usage.Input $frozen.Usage.Input 'end offsets freeze input'
    Assert-Near $cacheFirst.TotalCost $frozen.TotalCost 0.0000001 'end offsets freeze cost'
    $baselineEntryForPath = @($cacheBaseline.Files | Where-Object { [string]$_.FilePath -eq $cachePath } | Select-Object -First 1)
    $baselineLength = if ($baselineEntryForPath.Count -gt 0) { [Int64]$baselineEntryForPath[0].Length } else { [Int64]$cacheBaseline.Files[0].Length }
    $frozenZero = Get-TokenRaderIntervalResult -Baseline $cacheBaseline -PricingDocument $prices -EndOffsets @{ $cachePath = $baselineLength }
    if ($frozenZero.CountedEvents -ne 0) {
        throw ("ENDDBG baselineLength={0} twoRecordLength={1} currentLength={2} baselineFilesCount={3} firstFilePath={4} cachePath={5} counted={6} raw={7} changed={8}" -f
            $baselineLength, $twoRecordLength, (Get-Item -LiteralPath $cachePath).Length,
            @($cacheBaseline.Files).Count, [string]$cacheBaseline.Files[0].FilePath, $cachePath,
            $frozenZero.CountedEvents, $frozenZero.RawEvents, $frozenZero.ChangedSessions)
    }

    # --- Rate-limit reset formats and rate snapshot fallback ---
    # Codex has emitted reset timestamps in several wire formats over time.
    # Every format must normalize to the same Unix-second instant, and a
    # token_count line without rate_limits must inherit the previous valid
    # snapshot instead of erasing the quota cards.
    $rateFormatRoot = Join-Path $tempRoot 'rate-format-sessions'
    New-Item -ItemType Directory -Path $rateFormatRoot | Out-Null
    $observedAt = [DateTimeOffset]::Parse('2026-07-14T06:00:00Z')
    $fiveReset = $observedAt.AddMinutes(5)
    $weeklyReset = $observedAt.AddDays(7)
    $resetCases = @(
        [pscustomobject]@{ Name = 'unix-seconds'; Field = 'resets_at'; Value = $fiveReset.ToUnixTimeSeconds(); Expected = $fiveReset.ToUnixTimeSeconds() },
        [pscustomobject]@{ Name = 'unix-milliseconds'; Field = 'reset_at'; Value = $fiveReset.ToUnixTimeMilliseconds(); Expected = $fiveReset.ToUnixTimeSeconds() },
        [pscustomobject]@{ Name = 'iso'; Field = 'resets_at'; Value = $fiveReset.ToString('o'); Expected = $fiveReset.ToUnixTimeSeconds() },
        [pscustomobject]@{ Name = 'relative-seconds'; Field = 'resets_in_seconds'; Value = 300; Expected = $observedAt.AddSeconds(300).ToUnixTimeSeconds() }
    )
    foreach ($resetCase in @($resetCases)) {
        $rawRate = New-TestRawRateLimits -FiveHourUsed 11 -WeeklyUsed 22 -FiveHourReset $null -WeeklyReset $weeklyReset.ToUnixTimeSeconds()
        $rawRate.primary[$resetCase.Field] = $resetCase.Value
        $formatPath = Join-Path $rateFormatRoot ('rollout-reset-' + $resetCase.Name + '.jsonl')
        $formatRecord = New-TestTokenRecord -Timestamp $observedAt.ToString('o') -TotalInput 1000 -TotalCached 100 -TotalOutput 100 -CallInput 1000 -CallCached 100 -CallOutput 100 -RateLimits $rawRate
        @($formatRecord | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $formatPath -Encoding UTF8
        $formatSnapshot = Get-TokenRaderUsageSnapshot -FilePath $formatPath -Tail 100
        $actualReset = if ($null -ne $formatSnapshot -and $null -ne $formatSnapshot.RateLimits -and $null -ne $formatSnapshot.RateLimits.FiveHour -and $null -ne $formatSnapshot.RateLimits.FiveHour.ResetsAt) {
            $formatSnapshot.RateLimits.FiveHour.ResetsAt.ToUniversalTime().ToUnixTimeSeconds()
        } else { -1 }
        Assert-Equal ([Int64]$resetCase.Expected) ([Int64]$actualReset) ($resetCase.Name + ' reset timestamp parsing')
        $formatBaseline = [pscustomobject]@{
            StartedAt = [DateTimeOffset]::MinValue
            SessionsRoot = $rateFormatRoot
            Files = @()
            RateLimits = $null
        }
        $formatInterval = Get-TokenRaderIntervalResult -Baseline $formatBaseline -PricingDocument $prices -IncludedFiles @($formatPath)
        $fastRate = if ($null -ne $formatInterval.EndRateLimits -and $null -ne $formatInterval.EndRateLimits.FiveHour) {
            $formatInterval.EndRateLimits.FiveHour.ResetsAt.ToUniversalTime().ToUnixTimeSeconds()
        } else { -1 }
        Assert-Equal ([Int64]$resetCase.Expected) ([Int64]$fastRate) ($resetCase.Name + ' fast and full JSON reset parsing agree')
    }

    $fallbackRatePath = Join-Path $rateFormatRoot 'rollout-rate-fallback.jsonl'
    $fallbackRate = New-TestRawRateLimits -FiveHourUsed 9 -WeeklyUsed 19 -FiveHourReset $fiveReset.ToUnixTimeSeconds() -WeeklyReset $weeklyReset.ToUnixTimeSeconds()
    $fallbackRecords = @(
        (New-TestTokenRecord -Timestamp $observedAt.AddSeconds(-1).ToString('o') -TotalInput 1000 -TotalCached 100 -TotalOutput 100 -CallInput 1000 -CallCached 100 -CallOutput 100 -RateLimits $fallbackRate),
        (New-TestTokenRecord -Timestamp $observedAt.ToString('o') -TotalInput 2000 -TotalCached 200 -TotalOutput 200 -CallInput 1000 -CallCached 100 -CallOutput 100)
    )
    @($fallbackRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $fallbackRatePath -Encoding UTF8
    $fallbackRateSnapshot = Get-TokenRaderUsageSnapshot -FilePath $fallbackRatePath -Tail 100
    Assert-Equal 2000 $fallbackRateSnapshot.Task.Input 'latest token remains the usage source when rate snapshot is older'
    Assert-Near 9.0 $fallbackRateSnapshot.RateLimits.FiveHour.UsedPercent 0.0001 'latest token falls back to previous five-hour rate snapshot'
    Assert-Near 19.0 $fallbackRateSnapshot.RateLimits.Weekly.UsedPercent 0.0001 'latest token falls back to previous weekly rate snapshot'
    Assert-Equal $fiveReset.ToUnixTimeSeconds() $fallbackRateSnapshot.RateLimits.FiveHour.ResetsAt.ToUniversalTime().ToUnixTimeSeconds() 'fallback five-hour reset timestamp'

    # --- Rate-limit discovery scans all files and excludes 30-day windows ---
    # The newest rate event intentionally lives in the oldest-modified file;
    # this catches any hidden "latest 16 files" truncation.
    $manyRateRoot = Join-Path $tempRoot 'many-rate-sessions'
    New-Item -ItemType Directory -Path $manyRateRoot | Out-Null
    $manyMtimeBase = [DateTime]::UtcNow.AddMinutes(-2)
    $targetRatePath = Join-Path $manyRateRoot 'rollout-target.jsonl'
    $targetRecord = New-TestTokenRecord -Timestamp '2026-07-14T07:00:00Z' -TotalInput 1000 -TotalCached 0 -TotalOutput 1 -CallInput 1000 -CallCached 0 -CallOutput 1 -RateLimits (New-TestRawRateLimits -FiveHourUsed 77 -WeeklyUsed 77 -FiveHourReset $fiveReset.ToUnixTimeSeconds() -WeeklyReset $weeklyReset.ToUnixTimeSeconds())
    @($targetRecord | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $targetRatePath -Encoding UTF8
    [IO.File]::SetLastWriteTimeUtc($targetRatePath, $manyMtimeBase.AddMinutes(-1))
    for ($i = 1; $i -le 16; $i++) {
        $distractorPath = Join-Path $manyRateRoot ('rollout-distractor-{0:D2}.jsonl' -f $i)
        $distractorRecord = New-TestTokenRecord -Timestamp ('2026-07-14T05:{0:D2}:00Z' -f $i) -TotalInput 1000 -TotalCached 0 -TotalOutput 1 -CallInput 1000 -CallCached 0 -CallOutput 1 -RateLimits (New-TestRawRateLimits -FiveHourUsed $i -WeeklyUsed $i -FiveHourReset $fiveReset.ToUnixTimeSeconds() -WeeklyReset $weeklyReset.ToUnixTimeSeconds())
        @($distractorRecord | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $distractorPath -Encoding UTF8
        [IO.File]::SetLastWriteTimeUtc($distractorPath, $manyMtimeBase.AddSeconds($i))
    }
    $manyRateLimits = Get-TokenRaderLatestRateLimits -SessionsRoot $manyRateRoot
    Assert-Near 77.0 $manyRateLimits.FiveHour.UsedPercent 0.0001 'latest rate limit is not limited to sixteen files'
    Assert-Near 77.0 $manyRateLimits.Weekly.UsedPercent 0.0001 'latest weekly rate limit is not limited to sixteen files'

    $longWindowRoot = Join-Path $tempRoot 'long-window-sessions'
    New-Item -ItemType Directory -Path $longWindowRoot | Out-Null
    $thirtyDayPath = Join-Path $longWindowRoot 'rollout-thirty-day.jsonl'
    $thirtyDayRates = New-TestRawRateLimits -FiveHourUsed 31 -WeeklyUsed 41 -FiveHourReset $fiveReset.ToUnixTimeSeconds() -WeeklyReset $weeklyReset.ToUnixTimeSeconds() -FiveHourWindow 43200 -WeeklyWindow 43200
    $thirtyDayRecord = New-TestTokenRecord -Timestamp $observedAt.ToString('o') -TotalInput 1000 -TotalCached 0 -TotalOutput 1 -CallInput 1000 -CallCached 0 -CallOutput 1 -RateLimits $thirtyDayRates
    @($thirtyDayRecord | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $thirtyDayPath -Encoding UTF8
    $thirtyDaySnapshot = Get-TokenRaderUsageSnapshot -FilePath $thirtyDayPath -Tail 100
    Assert-Equal $null $thirtyDaySnapshot.RateLimits.FiveHour '30-day window is not classified as five-hour'
    Assert-Equal $null $thirtyDaySnapshot.RateLimits.Weekly '30-day window is not classified as weekly'

    $mixedWindowPath = Join-Path $longWindowRoot 'rollout-thirty-day-plus-week.jsonl'
    $mixedWindowRates = New-TestRawRateLimits -FiveHourUsed 32 -WeeklyUsed 42 -FiveHourReset $fiveReset.ToUnixTimeSeconds() -WeeklyReset $weeklyReset.ToUnixTimeSeconds() -FiveHourWindow 43200 -WeeklyWindow 10080
    $mixedWindowRecord = New-TestTokenRecord -Timestamp $observedAt.AddMinutes(1).ToString('o') -TotalInput 1000 -TotalCached 0 -TotalOutput 1 -CallInput 1000 -CallCached 0 -CallOutput 1 -RateLimits $mixedWindowRates
    @($mixedWindowRecord | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $mixedWindowPath -Encoding UTF8
    $mixedWindowSnapshot = Get-TokenRaderUsageSnapshot -FilePath $mixedWindowPath -Tail 100
    Assert-Equal $null $mixedWindowSnapshot.RateLimits.FiveHour '30-day primary does not hide missing five-hour window'
    Assert-Near 42.0 $mixedWindowSnapshot.RateLimits.Weekly.UsedPercent 0.0001 'valid weekly window remains available beside 30-day window'

    # --- Quota inference validation and Pro 5x arithmetic ---
    $quotaFiveReset = [DateTimeOffset]::Parse('2026-07-14T11:00:00Z')
    $quotaWeeklyReset = [DateTimeOffset]::Parse('2026-07-21T00:00:00Z')
    $quotaStart = New-TestQuotaRateLimits -FiveHourUsed 3 -WeeklyUsed 3 -FiveHourReset $quotaFiveReset -WeeklyReset $quotaWeeklyReset -PlanType 'pro'
    $quotaEnd = New-TestQuotaRateLimits -FiveHourUsed 8 -WeeklyUsed 8 -FiveHourReset $quotaFiveReset -WeeklyReset $quotaWeeklyReset -PlanType 'pro'
    $quota = Get-TokenRaderQuotaEstimate -StartRateLimits $quotaStart -EndRateLimits $quotaEnd -IntervalCost 12.5 -CostComplete $true
    Assert-Near 250.0 $quota.FiveHour.TotalUsd 0.0000001 '3 percent to 8 percent infers 250 API-equivalent USD without a Pro multiplier'
    Assert-Near 250.0 $quota.Weekly.TotalUsd 0.0000001 'weekly 3 percent to 8 percent infers 250 API-equivalent USD'
    Assert-Near 20.0 $quota.FiveHour.UsedUsd 0.0000001 'five-hour used USD inference'
    Assert-Near 230.0 $quota.Weekly.RemainingUsd 0.0000001 'weekly remaining USD inference'

    $crossResetEnd = New-TestQuotaRateLimits -FiveHourUsed 8 -WeeklyUsed 8 -FiveHourReset $quotaFiveReset.AddHours(1) -WeeklyReset $quotaWeeklyReset -PlanType 'pro'
    $crossResetEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $quotaStart -EndRateLimits $crossResetEnd -IntervalCost 12.5 -CostComplete $true
    $crossResetFive = if ($null -eq $crossResetEstimate) { $null } else { $crossResetEstimate.FiveHour }
    Assert-Equal $null $crossResetFive 'cross-reset five-hour window is not inferred'
    Assert-Near 250.0 $crossResetEstimate.Weekly.TotalUsd 0.0000001 'unaffected weekly window remains independently inferable'

    $missingResetStart = New-TestQuotaRateLimits -FiveHourUsed 3 -WeeklyUsed 3 -FiveHourReset $quotaFiveReset -WeeklyReset $quotaWeeklyReset -PlanType 'pro'
    $missingResetStart.FiveHour.ResetsAt = $null
    $missingResetEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $missingResetStart -EndRateLimits $quotaEnd -IntervalCost 12.5 -CostComplete $true
    $missingResetFive = if ($null -eq $missingResetEstimate) { $null } else { $missingResetEstimate.FiveHour }
    Assert-Equal $null $missingResetFive 'missing reset timestamp disables five-hour inference'

    $planChangedEnd = New-TestQuotaRateLimits -FiveHourUsed 8 -WeeklyUsed 8 -FiveHourReset $quotaFiveReset -WeeklyReset $quotaWeeklyReset -PlanType 'plus'
    $planChangedEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $quotaStart -EndRateLimits $planChangedEnd -IntervalCost 12.5 -CostComplete $true
    $planChangedFive = if ($null -eq $planChangedEstimate) { $null } else { $planChangedEstimate.FiveHour }
    $planChangedWeekly = if ($null -eq $planChangedEstimate) { $null } else { $planChangedEstimate.Weekly }
    Assert-Equal $null $planChangedFive 'plan changes disable five-hour inference'
    Assert-Equal $null $planChangedWeekly 'plan changes disable weekly inference'

    $windowChangedEnd = New-TestQuotaRateLimits -FiveHourUsed 8 -WeeklyUsed 8 -FiveHourReset $quotaFiveReset -WeeklyReset $quotaWeeklyReset -PlanType 'pro' -FiveHourWindow 360
    $windowChangedEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $quotaStart -EndRateLimits $windowChangedEnd -IntervalCost 12.5 -CostComplete $true
    $windowChangedFive = if ($null -eq $windowChangedEstimate) { $null } else { $windowChangedEstimate.FiveHour }
    Assert-Equal $null $windowChangedFive 'window length changes disable five-hour inference'

    # --- EndOffsets freeze both cost and rate-limit snapshots ---
    $freezeRoot = Join-Path $tempRoot 'frozen-interval-sessions'
    New-Item -ItemType Directory -Path $freezeRoot | Out-Null
    $freezePath = Join-Path $freezeRoot 'rollout-frozen.jsonl'
    $freezeReset = [DateTimeOffset]::Parse('2026-07-14T12:00:00Z')
    $freezeWeeklyReset = [DateTimeOffset]::Parse('2026-07-21T00:00:00Z')
    $freezeInitial = @(
        [ordered]@{ timestamp = '2026-07-14T08:00:00Z'; type = 'session_meta'; payload = [ordered]@{ id = '40000000-0000-0000-0000-000000000001'; model_provider = 'openai' } },
        [ordered]@{ timestamp = '2026-07-14T08:00:01Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.5' } },
        (New-TestTokenRecord -Timestamp '2026-07-14T08:00:02Z' -TotalInput 0 -TotalCached 0 -TotalOutput 0 -CallInput 0 -CallCached 0 -CallOutput 0 -RateLimits (New-TestRawRateLimits -FiveHourUsed 3 -WeeklyUsed 3 -FiveHourReset $freezeReset.ToUnixTimeSeconds() -WeeklyReset $freezeWeeklyReset.ToUnixTimeSeconds()))
    )
    @($freezeInitial | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $freezePath -Encoding UTF8
    $freezeBaseline = New-TokenRaderMeasurementBaseline -SessionsRoot $freezeRoot
    # Keep input below the 272K long-context threshold. 250K input ($1.25)
    # plus 375K output ($11.25) gives exactly $12.50 at the standard GPT-5.5
    # prices without invoking the long-context multiplier.
    $freezeFirstRecord = New-TestTokenRecord -Timestamp '2026-07-14T08:01:00Z' -TotalInput 250000 -TotalCached 0 -TotalOutput 375000 -CallInput 250000 -CallCached 0 -CallOutput 375000 -RateLimits (New-TestRawRateLimits -FiveHourUsed 8 -WeeklyUsed 8 -FiveHourReset $freezeReset.ToUnixTimeSeconds() -WeeklyReset $freezeWeeklyReset.ToUnixTimeSeconds())
    ($freezeFirstRecord | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $freezePath -Encoding UTF8
    $freezeEndOffset = (Get-Item -LiteralPath $freezePath).Length
    $frozenBeforeAppend = Get-TokenRaderIntervalResult -Baseline $freezeBaseline -PricingDocument $prices -EndOffsets @{ $freezePath = $freezeEndOffset }
    Assert-Equal 1 $frozenBeforeAppend.CountedEvents 'frozen interval counts only records before end offset'
    Assert-Near 12.5 $frozenBeforeAppend.TotalCost 0.0000001 'frozen interval API cost'
    Assert-Near 3.0 $frozenBeforeAppend.StartRateLimits.FiveHour.UsedPercent 0.0001 'frozen interval start five-hour snapshot'
    Assert-Near 8.0 $frozenBeforeAppend.EndRateLimits.FiveHour.UsedPercent 0.0001 'frozen interval end five-hour snapshot'
    Assert-Near 8.0 $frozenBeforeAppend.RateLimits.FiveHour.UsedPercent 0.0001 'legacy rate-limit alias uses frozen end snapshot'

    $freezeSecondRecord = New-TestTokenRecord -Timestamp '2026-07-14T08:02:00Z' -TotalInput 1000000 -TotalCached 0 -TotalOutput 0 -CallInput 1000000 -CallCached 0 -CallOutput 0 -RateLimits (New-TestRawRateLimits -FiveHourUsed 30 -WeeklyUsed 30 -FiveHourReset $freezeReset.ToUnixTimeSeconds() -WeeklyReset $freezeWeeklyReset.ToUnixTimeSeconds())
    ($freezeSecondRecord | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $freezePath -Encoding UTF8
    $frozenAfterAppend = Get-TokenRaderIntervalResult -Baseline $freezeBaseline -PricingDocument $prices -EndOffsets @{ $freezePath = $freezeEndOffset }
    Assert-Equal 1 $frozenAfterAppend.CountedEvents 'appending after end offset does not change frozen event count'
    Assert-Near $frozenBeforeAppend.TotalCost $frozenAfterAppend.TotalCost 0.0000001 'appending after end offset does not change frozen cost'
    Assert-Near $frozenBeforeAppend.EndRateLimits.FiveHour.UsedPercent $frozenAfterAppend.EndRateLimits.FiveHour.UsedPercent 0.0001 'appending after end offset does not change frozen rate snapshot'
    $unfrozenAfterAppend = Get-TokenRaderIntervalResult -Baseline $freezeBaseline -PricingDocument $prices
    Assert-Equal 2 $unfrozenAfterAppend.CountedEvents 'unfrozen interval sees the appended event'
    Assert-Near 30.0 $unfrozenAfterAppend.EndRateLimits.FiveHour.UsedPercent 0.0001 'unfrozen interval sees latest rate snapshot'

    # --- Same token counts at different times are distinct; copied task-tree events dedupe ---
    $repeatRoot = Join-Path $tempRoot 'repeat-event-sessions'
    New-Item -ItemType Directory -Path $repeatRoot | Out-Null
    $repeatParentId = '50000000-0000-0000-0000-000000000001'
    $repeatParentPath = Join-Path $repeatRoot 'rollout-repeat-parent.jsonl'
    $repeatInitial = @(
        [ordered]@{ timestamp = '2026-07-14T09:00:00Z'; type = 'session_meta'; payload = [ordered]@{ id = $repeatParentId; model_provider = 'openai' } },
        [ordered]@{ timestamp = '2026-07-14T09:00:01Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.5' } }
    )
    @($repeatInitial | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $repeatParentPath -Encoding UTF8
    $repeatBaseline = New-TokenRaderMeasurementBaseline -SessionsRoot $repeatRoot
    $repeatEventOne = New-TestTokenRecord -Timestamp '2026-07-14T09:01:00Z' -TotalInput 1000 -TotalCached 0 -TotalOutput 100 -CallInput 1000 -CallCached 0 -CallOutput 100
    $repeatEventTwo = New-TestTokenRecord -Timestamp '2026-07-14T09:01:01Z' -TotalInput 1000 -TotalCached 0 -TotalOutput 100 -CallInput 1000 -CallCached 0 -CallOutput 100
    @($repeatEventOne, $repeatEventTwo | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Add-Content -LiteralPath $repeatParentPath -Encoding UTF8
    $repeatChildId = '50000000-0000-0000-0000-000000000002'
    $repeatChildPath = Join-Path $repeatRoot 'rollout-repeat-child.jsonl'
    $repeatChildRecords = @(
        [ordered]@{ timestamp = '2026-07-14T09:01:02Z'; type = 'session_meta'; payload = [ordered]@{ id = $repeatChildId; parent_thread_id = $repeatParentId; forked_from_id = $repeatParentId; model_provider = 'openai' } },
        [ordered]@{ timestamp = '2026-07-14T09:01:03Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.5' } },
        $repeatEventOne
    )
    @($repeatChildRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $repeatChildPath -Encoding UTF8
    $repeatResult = Get-TokenRaderIntervalResult -Baseline $repeatBaseline -PricingDocument $prices
    Assert-Equal 2 $repeatResult.CountedEvents 'same token counts at different timestamps remain distinct'
    Assert-Equal 1 $repeatResult.DuplicateEventsDropped 'exact copied task-tree event is deduplicated once'
    Assert-Equal 2000 $repeatResult.Usage.Input 'repeated calls with same token count are both included'
    Assert-Equal 200 $repeatResult.Usage.Output 'repeated calls with same output count are both included'

    # --- Two independent conversations using GPT-5.6 and GPT-5.5 ---
    $hybridRoot = Join-Path $tempRoot 'hybrid-model-sessions'
    New-Item -ItemType Directory -Path $hybridRoot | Out-Null
    $hybridSpecs = @(
        [pscustomobject]@{ Id = '60000000-0000-0000-0000-000000000001'; Model = 'gpt-5.6-sol'; Timestamp = '2026-07-14T10:00:00Z' },
        [pscustomobject]@{ Id = '60000000-0000-0000-0000-000000000002'; Model = 'gpt-5.5'; Timestamp = '2026-07-14T10:01:00Z' }
    )
    foreach ($hybridSpec in @($hybridSpecs)) {
        $hybridPath = Join-Path $hybridRoot ('rollout-hybrid-' + $hybridSpec.Id + '.jsonl')
        $hybridRecords = @(
            [ordered]@{ timestamp = $hybridSpec.Timestamp; type = 'session_meta'; payload = [ordered]@{ id = $hybridSpec.Id; model_provider = 'openai' } },
            [ordered]@{ timestamp = ([DateTimeOffset]::Parse($hybridSpec.Timestamp).AddSeconds(1)).ToString('o'); type = 'turn_context'; payload = [ordered]@{ model = $hybridSpec.Model } },
            # Keep both calls below the long-context threshold so this fixture
            # isolates model-specific standard input prices.
            (New-TestTokenRecord -Timestamp ([DateTimeOffset]::Parse($hybridSpec.Timestamp).AddSeconds(2)).ToString('o') -TotalInput 250000 -TotalCached 0 -TotalOutput 0 -CallInput 250000 -CallCached 0 -CallOutput 0)
        )
        @($hybridRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $hybridPath -Encoding UTF8
    }
    $hybridBaseline = [pscustomobject]@{ StartedAt = [DateTimeOffset]::MinValue; SessionsRoot = $hybridRoot; Files = @(); RateLimits = $null }
    $hybridResult = Get-TokenRaderIntervalResult -Baseline $hybridBaseline -PricingDocument $prices
    Assert-Equal 2 $hybridResult.CountedEvents 'mixed-model independent conversations count separately'
    Assert-Equal 500000 $hybridResult.Usage.Input 'mixed-model input total'
    Assert-Equal 2 @($hybridResult.Models).Count 'mixed-model model attribution'
    Assert-Near 2.25 $hybridResult.TotalCost 0.0000001 'GPT-5.6 and GPT-5.5 use separate official input prices'
    $hybridSolItem = @($hybridResult.Items | Where-Object { $_.Model -eq 'gpt-5.6-sol' })[0]
    $hybrid55Item = @($hybridResult.Items | Where-Object { $_.Model -eq 'gpt-5.5' })[0]
    Assert-Near 1.0 $hybridSolItem.Cost.TotalCost 0.0000001 'GPT-5.6 per-model cost'
    Assert-Near 1.25 $hybrid55Item.Cost.TotalCost 0.0000001 'GPT-5.5 per-model cost'

    # --- Persistent incremental SQLite index ---
    # Keep this fixture under a unique temporary project. The production index
    # must place its database below that project's data/private directory, so
    # tests never read or mutate the user's real Codex logs or index.
    $indexProjectRoot = Join-Path $tempRoot 'index-project'
    $indexSessionsRoot = Join-Path $indexProjectRoot 'sessions'
    $indexPrivateRoot = Join-Path $indexProjectRoot 'data\private'
    New-Item -ItemType Directory -Path $indexSessionsRoot -Force | Out-Null
    $indexProjectA = Join-Path $indexProjectRoot 'Project A'
    $indexProjectB = Join-Path $indexProjectRoot 'Project B'
    $indexProjectC = Join-Path $indexProjectRoot 'Project C'
    $indexNow = [DateTimeOffset]::Now.ToUniversalTime()
    $indexRecentAAt = $indexNow.AddDays(-2)
    $indexRecentBAt = $indexNow.AddDays(-1)
    $indexOldAAt = $indexNow.AddDays(-45)
    $indexRecentCAt = $indexNow.AddHours(-2)
    $indexReset = $indexNow.AddDays(5).ToUnixTimeSeconds()
    $indexWeeklyReset = $indexNow.AddDays(7).ToUnixTimeSeconds()

    $indexRecentAId = '70000000-0000-0000-0000-000000000001'
    $indexRecentBId = '70000000-0000-0000-0000-000000000002'
    $indexOldAId = '70000000-0000-0000-0000-000000000003'
    $indexRecentCId = '70000000-0000-0000-0000-000000000004'
    $indexRecentAPath = Join-Path $indexSessionsRoot ('rollout-index-' + $indexRecentAId + '.jsonl')
    $indexRecentBPath = Join-Path $indexSessionsRoot ('rollout-index-' + $indexRecentBId + '.jsonl')
    $indexOldAPath = Join-Path $indexSessionsRoot ('rollout-index-' + $indexOldAId + '.jsonl')
    $indexRecentCPath = Join-Path $indexSessionsRoot ('rollout-index-' + $indexRecentCId + '.jsonl')

    $writeIndexFixture = {
        param([string]$Path, [string]$SessionId, [string]$Model, [string]$Cwd, [DateTimeOffset]$Timestamp, [Int64]$InputTokens, [Int64]$CachedTokens, [Int64]$OutputTokens)
        $indexRecords = @(
            [ordered]@{ timestamp = $Timestamp.ToString('o'); type = 'session_meta'; payload = [ordered]@{ id = $SessionId; cwd = $Cwd; model_provider = 'openai' } },
            [ordered]@{ timestamp = $Timestamp.AddSeconds(1).ToString('o'); type = 'turn_context'; payload = [ordered]@{ model = $Model } },
            (New-TestTokenRecord -Timestamp $Timestamp.AddSeconds(2).ToString('o') -TotalInput $InputTokens -TotalCached $CachedTokens -TotalOutput $OutputTokens -CallInput $InputTokens -CallCached $CachedTokens -CallOutput $OutputTokens -RateLimits (New-TestRawRateLimits -FiveHourUsed 5 -WeeklyUsed 7 -FiveHourReset $indexReset -WeeklyReset $indexWeeklyReset))
        )
        @($indexRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) | Set-Content -LiteralPath $Path -Encoding UTF8
    }
    & $writeIndexFixture $indexRecentAPath $indexRecentAId 'gpt-5.6-sol' $indexProjectA $indexRecentAAt 1000 200 100
    & $writeIndexFixture $indexRecentBPath $indexRecentBId 'gpt-5.5' $indexProjectB $indexRecentBAt 2000 500 200
    & $writeIndexFixture $indexOldAPath $indexOldAId 'gpt-5.6-sol' $indexProjectA $indexOldAAt 3000 600 300
    [IO.File]::SetLastWriteTimeUtc($indexRecentAPath, $indexRecentAAt.UtcDateTime)
    [IO.File]::SetLastWriteTimeUtc($indexRecentBPath, $indexRecentBAt.UtcDateTime)
    [IO.File]::SetLastWriteTimeUtc($indexOldAPath, $indexOldAAt.UtcDateTime)

    $indexCommandNames = @('Open-TokenRaderIndex', 'New-TokenRaderIndex', 'Update-TokenRaderIndex', 'Close-TokenRaderIndex', 'Clear-TokenRaderIndex', 'Remove-TokenRaderIndexHistory', 'Get-TokenRaderIndexedSessionFiles', 'Get-TokenRaderIndexedProjects')
    $missingIndexCommands = @($indexCommandNames | Where-Object { $null -eq (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missingIndexCommands.Count -gt 0) {
        throw ('INDEX CONTRACT FAILED: missing command(s): ' + ($missingIndexCommands -join ', '))
    }

    # Isolate the persistence test from the user's normal project database.
    # Production resolves its default to <module>/data/private/index/index.db,
    # while this process override points at the synthetic fixture project.
    $indexOverridePath = Join-Path $indexPrivateRoot 'index\index.db'
    $indexOverrideDirectory = Split-Path -Parent $indexOverridePath
    New-Item -ItemType Directory -Path $indexOverrideDirectory -Force | Out-Null
    $previousIndexOverride = [Environment]::GetEnvironmentVariable('TOKEN_RADER_INDEX_DB', 'Process')
    $indexHandle = $null
    $indexDbPath = $null
    $indexLeftBehind = $false
    try {
            $env:TOKEN_RADER_INDEX_DB = $indexOverridePath
            $indexHandle = Select-TestIndexHandle -Output @(New-TokenRaderIndex -SessionsRoot $indexSessionsRoot -Force)
            if ($null -eq $indexHandle) { throw 'INDEX TEST FAILED: New-TokenRaderIndex returned null' }
            $indexDbPath = [IO.Path]::GetFullPath([string]$indexHandle.DbPath)
            $expectedIndexPath = [IO.Path]::GetFullPath($indexOverridePath)
            Assert-Equal $expectedIndexPath $indexDbPath 'index DbPath uses isolated project data/private/index override'
            if (-not (Test-Path -LiteralPath $indexDbPath)) { throw 'INDEX TEST FAILED: index database was not created on disk' }

            $recentSessions = @(Get-TokenRaderIndexedSessionFiles -Days 30 -MaximumFiles 200)
            Assert-Equal 2 $recentSessions.Count 'indexed session query honors 30-day history range'
            $recentIds = @($recentSessions | ForEach-Object { [string]$_.SessionId })
            if ($recentIds -notcontains $indexRecentAId -or $recentIds -notcontains $indexRecentBId) {
                throw 'ASSERT FAILED: indexed session query omitted a recent synthetic session'
            }
            $allSessions = @(Get-TokenRaderIndexedSessionFiles -Days 60 -MaximumFiles 200)
            Assert-Equal 3 $allSessions.Count 'indexed session query includes older history when range expands'

            $recentProjects = @(Get-TokenRaderIndexedProjects -Days 30)
            Assert-Equal 2 $recentProjects.Count 'indexed project query honors 30-day history range'
            $recentProjectNames = @($recentProjects | ForEach-Object { [string]$_.ProjectName })
            if ($recentProjectNames -notcontains 'Project A' -or $recentProjectNames -notcontains 'Project B') {
                throw 'ASSERT FAILED: indexed project query omitted a recent synthetic project'
            }
            $allProjects = @(Get-TokenRaderIndexedProjects -Days 60)
            Assert-Equal 2 $allProjects.Count 'indexed project query includes old session in existing project without creating a new project'

            # Close must release the connection without deleting the persistent
            # database; reopening must reuse the same path and rows.
            Close-TokenRaderIndex
            Assert-Equal $true (Test-Path -LiteralPath $indexDbPath) 'Close preserves persistent index file'
            $reopenedIndex = Select-TestIndexHandle -Output @(Open-TokenRaderIndex -SessionsRoot $indexSessionsRoot)
            Assert-Equal $indexDbPath ([IO.Path]::GetFullPath([string]$reopenedIndex.DbPath)) 'reopen reuses the same project index path'
            Assert-Equal 2 @((Get-TokenRaderIndexedSessionFiles -Days 30 -MaximumFiles 200)).Count 'reopen preserves indexed session rows'

            # Updating only the candidate file must import appended records and
            # avoid a full source-tree scan. Existing query API exposes row count
            # as a latest-snapshot row, so compare its stable values instead of
            # assuming the compatibility query returns all historical rows.
            $beforeA = Select-TestIndexRow -Output @(Get-TokenRaderIndexRecords -SessionId $indexRecentAId)
            Assert-Equal 1000 ([Int64]$beforeA['total_input']) 'initial indexed latest row for candidate session'
            $appendedAAt = $indexNow.AddHours(-1)
            $appendedA = New-TestTokenRecord -Timestamp $appendedAAt.ToString('o') -TotalInput 1500 -TotalCached 300 -TotalOutput 150 -CallInput 500 -CallCached 100 -CallOutput 50
            ($appendedA | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $indexRecentAPath -Encoding UTF8
            $afterAUpdate = Update-TokenRaderIndex -SessionsRoot $indexSessionsRoot -CandidateFiles @($indexRecentAPath)
            $afterA = Select-TestIndexRow -Output @(Get-TokenRaderIndexRecords -SessionId $indexRecentAId)
            Assert-Equal 1500 ([Int64]$afterA['total_input']) 'candidate update imports appended session record'
            $afterAUpdateHandle = Select-TestIndexHandle -Output @($afterAUpdate)
            Assert-Equal $indexSessionsRoot ([string]$afterAUpdateHandle.SessionsRoot) 'candidate update keeps the indexed sessions root'

            # A refresh can race with Codex while the final JSONL line is only
            # partly written. The index must wait for its newline, then import
            # the completed record exactly once on the next candidate update.
            $partialA = New-TestTokenRecord -Timestamp $indexNow.AddMinutes(-40).ToString('o') -TotalInput 1750 -TotalCached 350 -TotalOutput 175 -CallInput 250 -CallCached 50 -CallOutput 25
            $partialLine = $partialA | ConvertTo-Json -Depth 8 -Compress
            $partialSplit = [int][Math]::Floor($partialLine.Length / 2)
            [IO.File]::AppendAllText($indexRecentAPath, $partialLine.Substring(0, $partialSplit), (New-Object Text.UTF8Encoding($false)))
            Update-TokenRaderIndex -SessionsRoot $indexSessionsRoot -CandidateFiles @($indexRecentAPath) | Out-Null
            $duringPartialA = Select-TestIndexRow -Output @(Get-TokenRaderIndexRecords -SessionId $indexRecentAId)
            Assert-Equal 1500 ([Int64]$duringPartialA['total_input']) 'unterminated JSONL tail is not indexed'
            [IO.File]::AppendAllText($indexRecentAPath, ($partialLine.Substring($partialSplit) + "`r`n"), (New-Object Text.UTF8Encoding($false)))
            Update-TokenRaderIndex -SessionsRoot $indexSessionsRoot -CandidateFiles @($indexRecentAPath) | Out-Null
            $afterPartialA = Select-TestIndexRow -Output @(Get-TokenRaderIndexRecords -SessionId $indexRecentAId)
            Assert-Equal 1750 ([Int64]$afterPartialA['total_input']) 'completed JSONL tail is indexed on the next refresh'

            $beforeB = Select-TestIndexRow -Output @(Get-TokenRaderIndexRecords -SessionId $indexRecentBId)
            Assert-Equal 2000 ([Int64]$beforeB['total_input']) 'non-candidate session starts with original latest row'
            $appendedBAt = $indexNow.AddMinutes(-30)
            $appendedB = New-TestTokenRecord -Timestamp $appendedBAt.ToString('o') -TotalInput 2200 -TotalCached 400 -TotalOutput 220 -CallInput 200 -CallCached 50 -CallOutput 20
            ($appendedB | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $indexRecentBPath -Encoding UTF8
            Update-TokenRaderIndex -SessionsRoot $indexSessionsRoot -CandidateFiles @($indexRecentAPath) | Out-Null
            $unchangedB = Get-TokenRaderIndexRecords -SessionId $indexRecentBId
            $unchangedBRow = Select-TestIndexRow -Output @($unchangedB)
            Assert-Equal 2000 ([Int64]$unchangedBRow['total_input']) 'candidate update does not scan an unlisted modified session'
            Update-TokenRaderIndex -SessionsRoot $indexSessionsRoot -CandidateFiles @($indexRecentBPath) | Out-Null
            $afterB = Select-TestIndexRow -Output @(Get-TokenRaderIndexRecords -SessionId $indexRecentBId)
            Assert-Equal 2200 ([Int64]$afterB['total_input']) 'candidate update imports a listed modified session'

            # A newly created file is also eligible when explicitly listed as a
            # candidate; the source log remains untouched by indexing.
            & $writeIndexFixture $indexRecentCPath $indexRecentCId 'gpt-5.4' $indexProjectC $indexRecentCAt 4000 800 400
            [IO.File]::SetLastWriteTimeUtc($indexRecentCPath, $indexRecentCAt.UtcDateTime)
            $sourceBeforeForce = @{
                A = [IO.File]::ReadAllText($indexRecentAPath)
                B = [IO.File]::ReadAllText($indexRecentBPath)
                C = [IO.File]::ReadAllText($indexRecentCPath)
                Old = [IO.File]::ReadAllText($indexOldAPath)
            }
            Update-TokenRaderIndex -SessionsRoot $indexSessionsRoot -CandidateFiles @($indexRecentCPath) | Out-Null
            Assert-Equal 3 @((Get-TokenRaderIndexedSessionFiles -Days 30 -MaximumFiles 200)).Count 'candidate update imports a newly created session'
            Assert-Equal 3 @((Get-TokenRaderIndexedProjects -Days 30)).Count 'candidate update exposes newly created project'

            # Force rebuild must operate on the database only, never rewrite
            # source JSONL files.
            New-TokenRaderIndex -SessionsRoot $indexSessionsRoot -Force | Out-Null
            Assert-Equal $sourceBeforeForce.A ([IO.File]::ReadAllText($indexRecentAPath)) 'force rebuild leaves recent A source log unchanged'
            Assert-Equal $sourceBeforeForce.B ([IO.File]::ReadAllText($indexRecentBPath)) 'force rebuild leaves recent B source log unchanged'
            Assert-Equal $sourceBeforeForce.C ([IO.File]::ReadAllText($indexRecentCPath)) 'force rebuild leaves recent C source log unchanged'
            Assert-Equal $sourceBeforeForce.Old ([IO.File]::ReadAllText($indexOldAPath)) 'force rebuild leaves old source log unchanged'
            Assert-Equal 3 @((Get-TokenRaderIndexedSessionFiles -Days 30 -MaximumFiles 200)).Count 'force rebuild preserves recent indexed session count'

            # Purging history removes old rows from the persistent index only;
            # it must not rewrite source JSONL or make an ordinary refresh
            # rediscover the purged file. The boundary must survive a close /
            # reopen cycle, while an explicitly listed file whose modification
            # time becomes recent is allowed to re-enter the index.
            $sourceBeforePurge = @{
                A = [IO.File]::ReadAllText($indexRecentAPath)
                B = [IO.File]::ReadAllText($indexRecentBPath)
                C = [IO.File]::ReadAllText($indexRecentCPath)
                Old = [IO.File]::ReadAllText($indexOldAPath)
            }
            Remove-TokenRaderIndexHistory -Days 30 | Out-Null
            Assert-Equal 3 @((Get-TokenRaderIndexedSessionFiles -Days 60 -MaximumFiles 200)).Count 'history purge removes the 45-day indexed session'
            Assert-Equal 3 @((Get-TokenRaderIndexedSessionFiles -Days 30 -MaximumFiles 200)).Count 'history purge retains recent indexed sessions'
            Assert-Equal $sourceBeforePurge.Old ([IO.File]::ReadAllText($indexOldAPath)) 'history purge leaves old source log unchanged'

            # A normal update without candidates must not re-import a purged
            # historical file, even though it remains under SessionsRoot.
            Update-TokenRaderIndex -SessionsRoot $indexSessionsRoot | Out-Null
            Assert-Equal 3 @((Get-TokenRaderIndexedSessionFiles -Days 60 -MaximumFiles 200)).Count 'ordinary update does not re-import purged history'
            Assert-Equal $sourceBeforePurge.A ([IO.File]::ReadAllText($indexRecentAPath)) 'ordinary update leaves recent A source log unchanged'
            Assert-Equal $sourceBeforePurge.B ([IO.File]::ReadAllText($indexRecentBPath)) 'ordinary update leaves recent B source log unchanged'
            Assert-Equal $sourceBeforePurge.C ([IO.File]::ReadAllText($indexRecentCPath)) 'ordinary update leaves recent C source log unchanged'
            Assert-Equal $sourceBeforePurge.Old ([IO.File]::ReadAllText($indexOldAPath)) 'ordinary update leaves purged old source log unchanged'

            # The purge boundary is persisted, not just held by the open
            # connection. Closing and reopening must keep the old row absent.
            Close-TokenRaderIndex
            $reopenedAfterPurge = Select-TestIndexHandle -Output @(Open-TokenRaderIndex -SessionsRoot $indexSessionsRoot)
            Assert-Equal $indexDbPath ([IO.Path]::GetFullPath([string]$reopenedAfterPurge.DbPath)) 'reopen after purge reuses the same index path'
            Assert-Equal 3 @((Get-TokenRaderIndexedSessionFiles -Days 60 -MaximumFiles 200)).Count 'reopen preserves the history purge boundary'
            Update-TokenRaderIndex -SessionsRoot $indexSessionsRoot | Out-Null
            Assert-Equal 3 @((Get-TokenRaderIndexedSessionFiles -Days 60 -MaximumFiles 200)).Count 'ordinary update after reopen still excludes purged history'

            # Explicit candidate updates may intentionally restore a purged
            # file after its source modification time becomes recent.
            [IO.File]::SetLastWriteTimeUtc($indexOldAPath, $indexNow.UtcDateTime)
            Update-TokenRaderIndex -SessionsRoot $indexSessionsRoot -CandidateFiles @($indexOldAPath) | Out-Null
            Assert-Equal 4 @((Get-TokenRaderIndexedSessionFiles -Days 30 -MaximumFiles 200)).Count 'recently modified explicit candidate re-enters the index'
            Assert-Equal $sourceBeforePurge.Old ([IO.File]::ReadAllText($indexOldAPath)) 'candidate re-entry leaves old source log content unchanged'

            # Establish the purge boundary again while the same file is old,
            # then verify Force rebuild clears that boundary and restores all
            # source logs without modifying any JSONL content.
            [IO.File]::SetLastWriteTimeUtc($indexOldAPath, $indexOldAAt.UtcDateTime)
            Update-TokenRaderIndex -SessionsRoot $indexSessionsRoot -CandidateFiles @($indexOldAPath) | Out-Null
            Remove-TokenRaderIndexHistory -Days 30 | Out-Null
            Assert-Equal 3 @((Get-TokenRaderIndexedSessionFiles -Days 60 -MaximumFiles 200)).Count 'second history purge removes the old candidate row'
            New-TokenRaderIndex -SessionsRoot $indexSessionsRoot -Force | Out-Null
            Assert-Equal 4 @((Get-TokenRaderIndexedSessionFiles -Days 60 -MaximumFiles 200)).Count 'force rebuild clears purge boundary and restores all logs'
            Assert-Equal 3 @((Get-TokenRaderIndexedSessionFiles -Days 30 -MaximumFiles 200)).Count 'force rebuild keeps the source modification-time range intact'
            Assert-Equal $sourceBeforePurge.A ([IO.File]::ReadAllText($indexRecentAPath)) 'force rebuild after purge leaves recent A source log unchanged'
            Assert-Equal $sourceBeforePurge.B ([IO.File]::ReadAllText($indexRecentBPath)) 'force rebuild after purge leaves recent B source log unchanged'
            Assert-Equal $sourceBeforePurge.C ([IO.File]::ReadAllText($indexRecentCPath)) 'force rebuild after purge leaves recent C source log unchanged'
            Assert-Equal $sourceBeforePurge.Old ([IO.File]::ReadAllText($indexOldAPath)) 'force rebuild after purge leaves old source log unchanged'
    } finally {
        try { Close-TokenRaderIndex } catch { }
        try { Clear-TokenRaderIndex } catch { }
        $indexLeftBehind = ($null -ne $indexDbPath -and (Test-Path -LiteralPath $indexDbPath))
        if ($null -eq $previousIndexOverride) {
            Remove-Item Env:TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue
        } else {
            $env:TOKEN_RADER_INDEX_DB = $previousIndexOverride
        }
    }
    if ($indexLeftBehind) {
        throw 'INDEX TEST FAILED: Clear-TokenRaderIndex left the private test database behind'
    }
    Assert-Equal $previousIndexOverride ([Environment]::GetEnvironmentVariable('TOKEN_RADER_INDEX_DB', 'Process')) 'index database override environment restoration'

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
    Assert-Near 19.2 $largeResult.TotalCost 0.0000001 'large fixture API cost'
        Assert-Equal $true $largeResult.CostComplete 'large fixture cost completeness'
    Assert-Equal $true $largeResult.PricingComplete 'large fixture pricing completeness'
    Write-Output ('LARGE_OK events={0} ms={1}' -f $largeCount, $largeStopwatch.ElapsedMilliseconds)

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    [xml]$xaml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'MainWindow.xaml')
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    foreach ($controlName in @('ProjectComboBox', 'ScopeComboBox', 'SessionListBox', 'HistoryRangeComboBox', 'RefreshButton', 'RebuildIndexButton', 'PurgeOldIndexButton', 'StartMeasureButton', 'StopMeasureButton', 'ViewIntervalButton', 'IntervalStatusText', 'ModelMetricText', 'CachedMetricText', 'UncachedMetricText', 'OutputMetricText', 'TotalMetricText', 'HitRateMetricText', 'UsdCostText', 'FiveHourUsageText', 'FiveHourDollarText', 'WeeklyUsageText', 'WeeklyDollarText', 'PricingDataGrid')) {
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
