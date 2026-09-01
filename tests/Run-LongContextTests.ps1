[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-LongContext {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('LONG CONTEXT TEST FAILED: ' + $Message) }
}

function Assert-LongContextNear {
    param(
        [double]$Expected,
        [double]$Actual,
        [double]$Tolerance,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([Math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw ('LONG CONTEXT TEST FAILED: {0}. Expected=[{1}] Actual=[{2}]' -f $Message, $Expected, $Actual)
    }
}

function Get-LongContextExpectedCost {
    param(
        [Parameter(Mandatory = $true)]$Price,
        [Int64]$InputTokens,
        [Int64]$CachedTokens,
        [Int64]$OutputTokens,
        [bool]$LongContext,
        [Int64]$CacheCreationTokens = 0,
        [double]$UnitTokens = 1000000.0
    )
    $cached = [Math]::Min([Math]::Max(0L, $CachedTokens), [Math]::Max(0L, $InputTokens))
    $input = [Math]::Max(0L, $InputTokens)
    $uncached = [Math]::Max(0L, $input - $cached)
    $creation = [Math]::Min([Math]::Max(0L, $CacheCreationTokens), $uncached)
    $ordinary = [Math]::Max(0L, $uncached - $creation)
    $inputMultiplier = if ($LongContext) { [double]$Price.longContextInputMultiplier } else { 1.0 }
    $outputMultiplier = if ($LongContext) { [double]$Price.longContextOutputMultiplier } else { 1.0 }
    return (($ordinary / $UnitTokens) * [double]$Price.input * $inputMultiplier) +
        (($creation / $UnitTokens) * [double]$Price.input * 1.25 * $inputMultiplier) +
        (($cached / $UnitTokens) * [double]$Price.cachedInput * $inputMultiplier) +
        (($OutputTokens / $UnitTokens) * [double]$Price.output * $outputMultiplier)
}

function New-LongContextUsage {
    param(
        [Int64]$InputTokens,
        [Int64]$CachedTokens,
        [Int64]$OutputTokens
    )
    $input = [Math]::Max(0L, $InputTokens)
    $cached = [Math]::Min([Math]::Max(0L, $CachedTokens), $input)
    [pscustomobject]@{
        Input = $input
        Cached = $cached
        Uncached = $input - $cached
        Output = [Math]::Max(0L, $OutputTokens)
        ReasoningOutput = 0L
        Total = $input + [Math]::Max(0L, $OutputTokens)
        CacheHitRate = if ($input -gt 0) { ($cached * 100.0) / $input } else { 0.0 }
    }
}

function New-LongContextJsonlLine {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Model,
        [Int64]$TotalInput,
        [Int64]$TotalCached,
        [Int64]$TotalOutput,
        [Int64]$CallInput,
        [Int64]$CallCached,
        [Int64]$CallOutput,
        [string]$CacheField = '',
        [string]$CacheCreationField = '',
        [Int64]$CacheCreationTokens = 0,
        [switch]$IncludeContextWindow,
        [switch]$IncludeTurnContext
    )
    $total = [ordered]@{
        input_tokens = $TotalInput
        output_tokens = $TotalOutput
        reasoning_output_tokens = 0
    }
    $last = [ordered]@{
        input_tokens = $CallInput
        output_tokens = $CallOutput
        reasoning_output_tokens = 0
    }
    if (-not [string]::IsNullOrWhiteSpace($CacheField)) {
        $total[$CacheField] = $TotalCached
        $last[$CacheField] = $CallCached
    }
    if ($CacheCreationTokens -gt 0) {
        $creationField = if (-not [string]::IsNullOrWhiteSpace($CacheCreationField)) {
            $CacheCreationField
        } elseif ($CacheField -eq 'cache_write_tokens') {
            'cache_write_tokens'
        } else {
            'cache_creation_tokens'
        }
        $last[$creationField] = $CacheCreationTokens
    }
    $info = [ordered]@{
        total_token_usage = $total
        last_token_usage = $last
    }
    if ($IncludeContextWindow) { $info['model_context_window'] = '1050000' }
    $record = [ordered]@{
        timestamp = $Timestamp
        type = 'event_msg'
        payload = [ordered]@{
            type = 'token_count'
            info = $info
        }
    }
    if ($IncludeTurnContext) {
        return @(
            ([ordered]@{
                timestamp = ([DateTimeOffset]::Parse($Timestamp).AddMilliseconds(-1)).ToString('o')
                type = 'turn_context'
                payload = [ordered]@{ model = $Model }
            } | ConvertTo-Json -Depth 10 -Compress),
            ($record | ConvertTo-Json -Depth 10 -Compress)
        )
    }
    return ($record | ConvertTo-Json -Depth 10 -Compress)
}

function Write-LongContextJsonl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )
    [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Get-LongContextRows {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $table = New-Object System.Data.DataTable
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
SELECT model,total_input,total_cached,total_output,call_input,call_cached,call_output,
       model_context_window,long_context_threshold,long_context_applied,long_context_source,
       cache_creation_tokens,cache_write_observable
FROM token_records WHERE source_path=@path ORDER BY source_offset_end
'@
        [void]$command.Parameters.AddWithValue('@path', $Path)
        $adapter = New-Object System.Data.SQLite.SQLiteDataAdapter($command)
        try { [void]$adapter.Fill($table) } finally { $adapter.Dispose() }
    } finally { $command.Dispose() }
    return ,$table
}

function Add-LongContextIndexedFile {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SessionId
    )
    $length = [IO.FileInfo]::new($Path).Length
    [void][TokenRaderIndexer]::ImportFile($Connection, $Path, 0L, $length, $SessionId, 1L)
    return [Int64]$length
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$prices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')
$sqliteDll = Join-Path $projectRoot 'indexer\System.Data.SQLite.dll'
$indexerDll = Join-Path $projectRoot 'indexer\TokenRader.Indexer.dll'
if ($null -eq ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
if ($null -eq ('TokenRaderIndexer' -as [type])) { Add-Type -Path $indexerDll }

# Direct cost checks exercise the same exported pricing function used by the
# UI and by all compact aggregate buckets. Every boundary is deliberately
# synthetic and uses call_input (never a cumulative total).
$boundaryModels = @('gpt-5.5', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-5.4')
foreach ($model in $boundaryModels) {
    $price = Resolve-TokenRaderPrice -Model $model -PricingDocument $prices
    Assert-LongContext ($null -ne $price) ('pricing entry exists for ' + $model)
    Assert-LongContext ([Int64]$price.contextWindow -eq 1050000L) ('1M context metadata for ' + $model)
    foreach ($callInput in @(271999L, 272000L, 272001L)) {
        $usage = New-LongContextUsage -InputTokens $callInput -CachedTokens 1000 -OutputTokens 200
        $cost = Get-TokenRaderCost -Usage $usage -Model $model -PricingDocument $prices -Scope call
        $expectedLong = $callInput -gt 272000L
        Assert-LongContext ([bool]$cost.LongContextApplied -eq $expectedLong) ('272K boundary flag for ' + $model + '/' + $callInput)
        Assert-LongContextNear (Get-LongContextExpectedCost -Price $price -InputTokens $callInput -CachedTokens 1000 -OutputTokens 200 -LongContext $expectedLong) ([double]$cost.TotalCost) 0.0000000001 ('272K boundary cost for ' + $model + '/' + $callInput)
        Assert-LongContext ([Int64]$cost.LongContextThreshold -eq 272000L) ('272K threshold metadata for ' + $model)
    }
}

# A model with a normal price but no explicitly configured long-context rule
# must remain standard-priced even when its input is over 272K.
$proPrice = [pscustomobject]@{
    id = 'gpt-5.5-pro'
    displayName = 'GPT-5.5 Pro (synthetic)'
    aliases = @()
    input = 5.0
    cachedInput = 0.5
    output = 30.0
    contextWindow = 1050000
}
$syntheticPricing = [pscustomobject]@{
    currency = 'USD'
    unitTokens = 1000000
    models = @($prices.models) + @($proPrice)
}
$proUsage = New-LongContextUsage -InputTokens 300001 -CachedTokens 1000 -OutputTokens 200
$proCost = Get-TokenRaderCost -Usage $proUsage -Model 'gpt-5.5-pro' -PricingDocument $syntheticPricing -Scope call
Assert-LongContext ([bool]$proCost.Known) 'synthetic GPT-5.5 Pro has a base price'
Assert-LongContext (-not [bool]$proCost.LongContextApplied) 'GPT-5.5 Pro without a configured multiplier stays standard-priced'
Assert-LongContext ([string]$proCost.LongContextSource -eq 'no_threshold') 'unconfigured model exposes no-threshold source'
Assert-LongContextNear (Get-LongContextExpectedCost -Price $proPrice -InputTokens 300001 -CachedTokens 1000 -OutputTokens 200 -LongContext $false) ([double]$proCost.TotalCost) 0.0000000001 'GPT-5.5 Pro standard cost'

$unknownCost = Get-TokenRaderCost -Usage $proUsage -Model 'synthetic-unknown-model' -PricingDocument $prices -Scope call
Assert-LongContext (-not [bool]$unknownCost.Known) 'unknown model is not silently priced'
Assert-LongContext (-not [bool]$unknownCost.LongContextApplied) 'unknown model does not receive a long-context multiplier'

$cacheUsage = New-LongContextUsage -InputTokens 1000 -CachedTokens 100 -OutputTokens 100
$cacheCost = Get-TokenRaderCost -Usage $cacheUsage -Model 'gpt-5.6-sol' -PricingDocument $prices -Scope call `
    -CacheCreationTokens 400 -CacheWriteObservable $true
Assert-LongContextNear 0.002 $cacheCost.CacheCreationCost 0.0000000001 'cache creation is charged once at the 1.25x write rate'
Assert-LongContextNear 0.00604 $cacheCost.TotalCost 0.0000000001 'cache read/write cost is not double counted'
Assert-LongContext ([string]$cacheCost.CostCoverage -eq 'observable_tokens_and_cache_write') 'observable cache-write coverage'
 $cacheNoWriteCost = Get-TokenRaderCost -Usage $cacheUsage -Model 'gpt-5.6-sol' -PricingDocument $prices -Scope call `
    -CacheCreationTokens 0 -CacheWriteObservable $false
Assert-LongContext ([string]$cacheNoWriteCost.CostCoverage -eq 'observable_tokens_only') 'missing cache-write coverage is explicit'

# Cache aliases and cache-write observability are parsed from synthetic JSONL,
# then checked in SQLite. The cache-creation amount is a subset of uncached
# input and is therefore charged once at 1.25x, never added a second time.
$tempRoot = Join-Path $env:TEMP ('token-rader-long-context-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$db = New-Object System.Data.SQLite.SQLiteConnection 'Data Source=:memory:;Version=3;New=True;'
$db.Open()
try {
    [TokenRaderIndexer]::CreateSchema($db)
    $sessionId = '81000000-0000-0000-0000-000000000001'
    $path = Join-Path $tempRoot ('rollout-' + $sessionId + '.jsonl')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(New-LongContextJsonlLine -Timestamp '2026-08-30T00:00:01Z' -Model 'gpt-5.6-sol' `
            -TotalInput 350000 -TotalCached 100 -TotalOutput 100 -CallInput 1000 -CallCached 100 -CallOutput 10 `
            -CacheField 'cache_read_tokens' -CacheCreationTokens 50 -IncludeContextWindow -IncludeTurnContext)) {
        [void]$lines.Add($line)
    }
    foreach ($line in @(New-LongContextJsonlLine -Timestamp '2026-08-30T00:00:02Z' -Model 'gpt-5.6-sol' `
            -TotalInput 350100 -TotalCached 120 -TotalOutput 120 -CallInput 100 -CallCached 20 -CallOutput 20 `
            -CacheField 'cache_read_tokens' -CacheCreationField 'cache_write_tokens' -CacheCreationTokens 10 -IncludeContextWindow)) {
        [void]$lines.Add($line)
    }
    foreach ($line in @(New-LongContextJsonlLine -Timestamp '2026-08-30T00:00:03Z' -Model 'gpt-5.6-sol' `
            -TotalInput 622101 -TotalCached 120 -TotalOutput 320 -CallInput 272001 -CallCached 0 -CallOutput 200 `
            -CacheField 'cache_creation_tokens' -CacheCreationTokens 30 -IncludeContextWindow)) {
        [void]$lines.Add($line)
    }
    Write-LongContextJsonl -Path $path -Lines @($lines)
    $length = Add-LongContextIndexedFile -Connection $db -Path $path -SessionId $sessionId
    $rows = Get-LongContextRows -Connection $db -Path $path
    Assert-LongContext ($rows.Rows.Count -eq 3) 'synthetic cache/context fixture imported all token rows'
    Assert-LongContext ([Int64]$rows.Rows[0]['call_cached'] -eq 100L) 'cache_read_tokens alias parsed as cached input'
    Assert-LongContext ([Int64]$rows.Rows[1]['call_cached'] -eq 20L) 'cache_write_tokens fixture retains cached input amount'
    Assert-LongContext ([Int64]$rows.Rows[0]['cache_creation_tokens'] -eq 50L -and
        [Int64]$rows.Rows[1]['cache_creation_tokens'] -eq 10L -and
        [Int64]$rows.Rows[2]['cache_creation_tokens'] -eq 30L) 'cache creation/write aliases persisted once'
    Assert-LongContext ([bool]$rows.Rows[0]['cache_write_observable'] -and [bool]$rows.Rows[1]['cache_write_observable'] -and
        [bool]$rows.Rows[2]['cache_write_observable']) 'cache write observability persisted'
    Assert-LongContext ([Int64]$rows.Rows[0]['model_context_window'] -eq 1050000L) 'quoted model_context_window parsed as integer metadata'
    Assert-LongContext ([Int64]$rows.Rows[2]['long_context_applied'] -eq 1L -and
        [Int64]$rows.Rows[2]['long_context_threshold'] -eq 272000L) 'indexed call_input over threshold is long context'
    Assert-LongContext ([Int64]$rows.Rows[0]['long_context_applied'] -eq 0L -and
        [Int64]$rows.Rows[0]['long_context_threshold'] -eq 272000L) 'cumulative total_input does not trigger long context'

    $thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    $thresholds['gpt-5.6-sol'] = 272000L
    $aggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
        $db, @{ $path = 0L }, @{ $path = $length },
        [DateTimeOffset]::Parse('2026-01-01T00:00:00Z'), $thresholds,
        [Threading.CancellationToken]::None, $null)
    Assert-LongContext ([Int64]$aggregate.CountedEvents -eq 3L) 'indexed aggregate counted all cache/context calls'
    Assert-LongContext ([Int64]$aggregate.StandardContextEvents -eq 2L -and [Int64]$aggregate.LongContextEvents -eq 1L) 'aggregate separates standard/long buckets'
    Assert-LongContext ([Int64]$aggregate.TotalCached -eq 120L) 'aggregate cached input total uses cache aliases'
    Assert-LongContext ([Int64]$aggregate.CacheCreationTokens -eq 90L) 'aggregate cache creation total is not double counted'
    Assert-LongContext ([bool]$aggregate.CacheWriteObservable) 'all cache-write fields are recognized as observable writes'
    $longBucket = @($aggregate.Buckets | Where-Object { $_.LongContext })[0]
    Assert-LongContext ([Int64]$longBucket.Input -eq 272001L -and [Int64]$longBucket.Output -eq 200L) 'long bucket uses per-call input/output'

    $noContextSession = '81000000-0000-0000-0000-000000000002'
    $noContextPath = Join-Path $tempRoot ('rollout-' + $noContextSession + '.jsonl')
    $noContextLine = New-LongContextJsonlLine -Timestamp '2026-08-30T00:00:10Z' -Model 'gpt-5.6-sol' `
        -TotalInput 1000 -TotalCached 0 -TotalOutput 10 -CallInput 1000 -CallCached 0 -CallOutput 10
    Write-LongContextJsonl -Path $noContextPath -Lines @(
        ([ordered]@{ timestamp = '2026-08-30T00:00:09Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-sol' } } | ConvertTo-Json -Depth 6 -Compress),
        $noContextLine
    )
    [void](Add-LongContextIndexedFile -Connection $db -Path $noContextPath -SessionId $noContextSession)
    $noContextRows = Get-LongContextRows -Connection $db -Path $noContextPath
    Assert-LongContext ([DBNull]::Value.Equals($noContextRows.Rows[0]['model_context_window'])) 'missing context window remains empty metadata'
    Assert-LongContext (-not [bool]$noContextRows.Rows[0]['cache_write_observable']) 'missing cache-write fields are marked unobservable'
    $missingContextSnapshot = Get-TokenRaderUsageSnapshot -FilePath $noContextPath
    Assert-LongContext ($null -ne $missingContextSnapshot) 'missing context window token snapshot remains readable'
    Assert-LongContext ([Int64]$missingContextSnapshot.ModelContextWindow -eq 0L) 'missing context window snapshot is empty rather than guessed'

    # Unexpected context-window metadata is treated as unknown rather than
    # dropping an otherwise valid token record or throwing under StrictMode.
    $invalidContextSession = '81000000-0000-0000-0000-000000000003'
    $invalidContextPath = Join-Path $tempRoot ('rollout-' + $invalidContextSession + '.jsonl')
    $invalidInfo = [ordered]@{
        total_token_usage = [ordered]@{ input_tokens = 1000; cached_input_tokens = 0; output_tokens = 10; reasoning_output_tokens = 0 }
        last_token_usage = [ordered]@{ input_tokens = 1000; cached_input_tokens = 0; output_tokens = 10; reasoning_output_tokens = 0 }
        model_context_window = 'unexpected'
    }
    Write-LongContextJsonl -Path $invalidContextPath -Lines @(
        ([ordered]@{ timestamp = '2026-08-30T00:00:19Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-sol' } } | ConvertTo-Json -Depth 6 -Compress),
        ([ordered]@{ timestamp = '2026-08-30T00:00:20Z'; type = 'event_msg'; payload = [ordered]@{ type = 'token_count'; info = $invalidInfo } } | ConvertTo-Json -Depth 10 -Compress)
    )
    [void](Add-LongContextIndexedFile -Connection $db -Path $invalidContextPath -SessionId $invalidContextSession)
    $invalidContextRows = Get-LongContextRows -Connection $db -Path $invalidContextPath
    Assert-LongContext ([DBNull]::Value.Equals($invalidContextRows.Rows[0]['model_context_window'])) 'invalid context window remains empty in the index'
    $invalidContextSnapshot = Get-TokenRaderUsageSnapshot -FilePath $invalidContextPath
    Assert-LongContext ($null -ne $invalidContextSnapshot -and [Int64]$invalidContextSnapshot.ModelContextWindow -eq 0L) 'invalid context window snapshot remains readable and unknown'
}
finally {
    $db.Dispose()
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Output 'LONG_CONTEXT_TESTS_PASSED'
