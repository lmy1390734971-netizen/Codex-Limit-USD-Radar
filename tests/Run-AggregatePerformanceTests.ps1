[CmdletBinding()]
param(
    [switch]$IncludeLegacyInterference
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-AggregateTest {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('AGGREGATE TEST FAILED: ' + $Message) }
}

function Invoke-TestSql {
    param([Parameter(Mandatory = $true)]$Connection, [Parameter(Mandatory = $true)][string]$Sql)
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Sql
        [void]$command.ExecuteNonQuery()
    } finally { $command.Dispose() }
}

function Add-TestAggregateRow {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [string]$SessionId,
        [string]$Timestamp,
        [string]$Model,
        [Int64]$TotalInput,
        [Int64]$TotalCached,
        [Int64]$TotalOutput,
        [Int64]$CallInput,
        [Int64]$CallCached,
        [Int64]$CallOutput,
        [string]$Fingerprint,
        [string]$SourcePath,
        [Int64]$SourceOffset,
        [string]$RootSessionId
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
INSERT INTO token_records
(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,
 call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,
 source_offset_end,root_session_id,index_revision)
VALUES
(@session,@timestamp,@model,@total_input,@total_cached,@total_output,0,
 @call_input,@call_cached,@call_output,0,@fingerprint,@source_path,
 @source_offset,@root_session,1)
'@
        [void]$command.Parameters.AddWithValue('@session', $SessionId)
        [void]$command.Parameters.AddWithValue('@timestamp', $Timestamp)
        [void]$command.Parameters.AddWithValue('@model', $Model)
        [void]$command.Parameters.AddWithValue('@total_input', $TotalInput)
        [void]$command.Parameters.AddWithValue('@total_cached', $TotalCached)
        [void]$command.Parameters.AddWithValue('@total_output', $TotalOutput)
        [void]$command.Parameters.AddWithValue('@call_input', $CallInput)
        [void]$command.Parameters.AddWithValue('@call_cached', $CallCached)
        [void]$command.Parameters.AddWithValue('@call_output', $CallOutput)
        [void]$command.Parameters.AddWithValue('@fingerprint', $Fingerprint)
        [void]$command.Parameters.AddWithValue('@source_path', $SourcePath)
        [void]$command.Parameters.AddWithValue('@source_offset', $SourceOffset)
        [void]$command.Parameters.AddWithValue('@root_session', $RootSessionId)
        [void]$command.ExecuteNonQuery()
    } finally { $command.Dispose() }
}

function Add-TestAggregateRelationship {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [string]$SessionId,
        [string]$ParentId,
        [string]$RootId,
        [string]$SourcePath
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
INSERT OR REPLACE INTO file_metadata
(path,length,last_write_ticks,parsed_offset,session_id,cwd,parent_thread_id,forked_from_id,content_retained,root_session_id)
VALUES (@path,10,0,10,@session,'',@parent,@parent,1,@root)
'@
        [void]$command.Parameters.AddWithValue('@path', $SourcePath)
        [void]$command.Parameters.AddWithValue('@session', $SessionId)
        [void]$command.Parameters.AddWithValue('@parent', $ParentId)
        [void]$command.Parameters.AddWithValue('@root', $RootId)
        [void]$command.ExecuteNonQuery()
    } finally { $command.Dispose() }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$sqliteDll = Join-Path $projectRoot 'indexer\System.Data.SQLite.dll'
$indexerDll = Join-Path $projectRoot 'indexer\TokenRader.Indexer.dll'
if ($null -eq ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
if ($null -eq ('TokenRaderIndexer' -as [type])) { Add-Type -Path $indexerDll }

$thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
$thresholds['gpt-5.5'] = 272000L
$thresholds['gpt-5.6-sol'] = 272000L
$none = [Threading.CancellationToken]::None
$startedAt = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')

# Small semantic fixture: an exact parent/child copy is removed, while two real
# calls with equal per-call usage are retained because their cumulative totals
# advance. Offset-zero legacy rows never enter a frozen interval.
$correctness = New-Object System.Data.SQLite.SQLiteConnection 'Data Source=:memory:;Version=3;New=True;'
$correctness.Open()
try {
    [TokenRaderIndexer]::CreateSchema($correctness)
    Add-TestAggregateRelationship $correctness 'parent' 'root' 'root' 'synthetic://parent'
    Add-TestAggregateRelationship $correctness 'child' 'parent' 'root' 'synthetic://child'
    Add-TestAggregateRow $correctness 'parent' '2026-08-28T00:00:00Z' 'gpt-5.5' 1000 100 100 1000 100 100 'fp-standard' 'synthetic://parent' 10 'root'
    Add-TestAggregateRow $correctness 'child' '2026-08-28T00:00:09Z' 'gpt-5.5' 1000 100 100 1000 100 100 'fp-standard' 'synthetic://child' 10 'root'
    Add-TestAggregateRow $correctness 'parent' '2026-08-28T00:00:01Z' 'gpt-5.5' 2000 200 200 1000 100 100 'fp-standard-2' 'synthetic://parent' 20 'root'
    Add-TestAggregateRow $correctness 'long' '2026-08-28T00:00:02Z' 'gpt-5.6-sol' 300001 100001 200 300001 100001 200 'fp-long' 'synthetic://long' 10 'long-root'
    Add-TestAggregateRow $correctness 'unknown' '2026-08-28T00:00:03Z' 'synthetic-unknown' 500 0 50 500 0 50 'fp-unknown' 'synthetic://unknown' 10 'unknown-root'
    Add-TestAggregateRow $correctness 'legacy' '2026-08-28T00:00:04Z' 'gpt-5.5' 999999 0 0 999999 0 0 'fp-legacy' '' 0 'legacy-root'

    $starts = @{
        'synthetic://parent' = 0L; 'synthetic://child' = 0L
        'synthetic://long' = 0L; 'synthetic://unknown' = 0L
    }
    $ends = @{
        'synthetic://parent' = 20L; 'synthetic://child' = 10L
        'synthetic://long' = 10L; 'synthetic://unknown' = 10L
    }
    $aggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
        $correctness, $starts, $ends, $startedAt, $thresholds, $none, $null)
    Assert-AggregateTest ($aggregate.RawEvents -eq 5) 'offset-zero legacy row entered the streamed interval'
    Assert-AggregateTest ($aggregate.CountedEvents -eq 4) 'parent/child deduplication or timestamp identity changed'
    Assert-AggregateTest ($aggregate.DuplicateEventsDropped -eq 1) 'exact copied event was not deduplicated once'
    Assert-AggregateTest ($aggregate.TotalInput -eq 302501) 'aggregated input total changed'
    Assert-AggregateTest ($aggregate.TotalCached -eq 100201) 'aggregated cached total changed'
    Assert-AggregateTest ($aggregate.TotalOutput -eq 450) 'aggregated output total changed'
    Assert-AggregateTest ($aggregate.Buckets.Count -eq 3) 'model/context buckets are not compact'
    Assert-AggregateTest (@($aggregate.Buckets | Where-Object { $_.Model -eq 'gpt-5.6-sol' -and $_.LongContext }).Count -eq 1) 'long-context call was not bucketed separately'

    # The first row after a frozen start may only repeat the last pre-start
    # snapshot. It must be removed even though its timestamp changed; the next
    # row advances cumulative usage and is one real call.
    Add-TestAggregateRow $correctness 'baseline' '2026-08-28T00:00:00Z' 'gpt-5.5' 1000 100 100 1000 100 100 'fp-before' 'synthetic://baseline' 10 'baseline-root'
    Add-TestAggregateRow $correctness 'baseline' '2026-08-28T00:00:01Z' 'gpt-5.5' 1000 100 100 1000 100 100 'fp-refresh' 'synthetic://baseline' 20 'baseline-root'
    Add-TestAggregateRow $correctness 'baseline' '2026-08-28T00:00:02Z' 'gpt-5.5' 2000 200 200 1000 100 100 'fp-next-call' 'synthetic://baseline' 30 'baseline-root'
    $seeded = [TokenRaderIndexer]::AggregateIntervalRecords(
        $correctness, @{ 'synthetic://baseline' = 10L }, @{ 'synthetic://baseline' = 30L },
        $startedAt, $thresholds, $none, $null)
    Assert-AggregateTest ($seeded.RawEvents -eq 2) 'baseline-seeded interval raw row count changed'
    Assert-AggregateTest ($seeded.CountedEvents -eq 1) 'pre-start cumulative snapshot was billed again'
    Assert-AggregateTest ($seeded.DuplicateEventsDropped -eq 1) 'repeated cumulative snapshot was not diagnosed'
    Assert-AggregateTest ($seeded.TotalInput -eq 1000 -and $seeded.TotalOutput -eq 100) 'baseline-seeded interval usage changed'

    $parentOnly = [TokenRaderIndexer]::AggregateIntervalRecords(
        $correctness, $starts, @{ 'synthetic://parent' = 20L }, $startedAt, $thresholds, $none, $null)
    Assert-AggregateTest ($parentOnly.RawEvents -eq 2) 'a baseline path omitted from EndOffsets became an unbounded range'

    Add-TestAggregateRow $correctness 'new' '2026-08-28T00:00:05Z' 'gpt-5.5' 250 25 25 250 25 25 'fp-new' 'synthetic://new' 10 'new-root'
    $withNewFile = [TokenRaderIndexer]::AggregateIntervalRecords(
        $correctness, $starts, ($ends + @{ 'synthetic://new' = 10L }), $startedAt, $thresholds, $none, $null)
    Assert-AggregateTest ($withNewFile.CountedEvents -eq 5) 'end-only file did not start at byte zero'

    # Equal usage at the exact same timestamp in two sibling subagents is two
    # independent calls. Shared task root alone must not collapse them.
    Add-TestAggregateRelationship $correctness 'sibling-a' 'sibling-root' 'sibling-root' 'synthetic://sibling-a'
    Add-TestAggregateRelationship $correctness 'sibling-b' 'sibling-root' 'sibling-root' 'synthetic://sibling-b'
    Add-TestAggregateRow $correctness 'sibling-a' '2026-08-28T00:00:10.1234567Z' 'gpt-5.5' 700 70 70 700 70 70 'fp-sibling' 'synthetic://sibling-a' 10 'sibling-root'
    Add-TestAggregateRow $correctness 'sibling-b' '2026-08-28T00:00:10.1234567Z' 'gpt-5.5' 700 70 70 700 70 70 'fp-sibling' 'synthetic://sibling-b' 10 'sibling-root'
    $siblings = [TokenRaderIndexer]::AggregateIntervalRecords(
        $correctness, @{}, @{ 'synthetic://sibling-a' = 10L; 'synthetic://sibling-b' = 10L },
        $startedAt, $thresholds, $none, $null)
    Assert-AggregateTest ($siblings.RawEvents -eq 2 -and $siblings.CountedEvents -eq 2) 'independent sibling calls were collapsed by shared-root deduplication'
    Assert-AggregateTest ($siblings.TotalInput -eq 1400 -and $siblings.TotalOutput -eq 140) 'independent sibling token totals changed'

    # Rolling history is an exact half-open 24-hour timestamp window. Seed the
    # last cumulative snapshot before the start so a later status refresh does
    # not bill the previous call again; the record at End is excluded.
    Add-TestAggregateRow $correctness 'history' '2026-08-29T00:00:00Z' 'gpt-5.5' 1000 100 100 1000 100 100 'history-before' 'synthetic://history' 10 'history-root'
    Add-TestAggregateRow $correctness 'history' '2026-08-29T00:00:01Z' 'gpt-5.5' 1000 100 100 1000 100 100 'history-refresh' 'synthetic://history' 20 'history-root'
    Add-TestAggregateRow $correctness 'history' '2026-08-29T00:00:02Z' 'gpt-5.5' 2000 200 200 1000 100 100 'history-call' 'synthetic://history' 30 'history-root'
    Add-TestAggregateRow $correctness 'history' '2026-08-29T00:00:03Z' 'gpt-5.5' 3000 300 300 1000 100 100 'history-at-end' 'synthetic://history' 40 'history-root'
    $historyAggregate = [TokenRaderIndexer]::AggregateTimeRangeRecords(
        $correctness,
        [DateTimeOffset]::Parse('2026-08-29T00:00:00.500Z'),
        [DateTimeOffset]::Parse('2026-08-29T00:00:03Z'),
        $thresholds, $none, $null)
    Assert-AggregateTest ($historyAggregate.RawEvents -eq 2) 'rolling history did not keep exact start/end boundaries'
    Assert-AggregateTest ($historyAggregate.CountedEvents -eq 1) 'rolling history billed a repeated pre-window cumulative snapshot'
    Assert-AggregateTest ($historyAggregate.DuplicateEventsDropped -eq 1) 'rolling history did not diagnose the repeated snapshot'
    Assert-AggregateTest ($historyAggregate.TotalInput -eq 1000 -and $historyAggregate.TotalCached -eq 100 -and $historyAggregate.TotalOutput -eq 100) 'rolling history token totals changed'

    $historySnapshot = New-Object TokenRaderUsageHistorySnapshot
    $historySnapshot.WindowStartTicks = [DateTimeOffset]::Parse('2026-08-29T00:00:00Z').UtcDateTime.Ticks
    $historySnapshot.WindowEndTicks = [DateTimeOffset]::Parse('2026-08-30T00:00:00Z').UtcDateTime.Ticks
    $historySnapshot.ComputedAtTicks = [DateTimeOffset]::Parse('2026-08-30T00:00:01Z').UtcDateTime.Ticks
    $historySnapshot.IndexRevision = 7
    $historySnapshot.PricingKey = 'synthetic-pricing'
    $historySnapshot.TotalInput = 1000
    $historySnapshot.TotalCached = 100
    $historySnapshot.TotalOutput = 100
    $historySnapshot.InputCost = 0.001
    $historySnapshot.CachedCost = 0.0001
    $historySnapshot.OutputCost = 0.002
    $historySnapshot.PricingComplete = $true
    $historySnapshot.ModelDisplay = 'gpt-5.5'
    $historySnapshot.Models = 'gpt-5.5'
    $historyModel = New-Object TokenRaderUsageHistoryModelSnapshot
    $historyModel.Model = 'gpt-5.5'
    $historyModel.TotalInput = 1000
    $historyModel.TotalCached = 100
    $historyModel.TotalOutput = 100
    $historyModel.InputCost = 0.001
    $historyModel.CachedCost = 0.0001
    $historyModel.OutputCost = 0.002
    $historyModel.PricingComplete = $true
    $historyModel.Events = 1
    $historySnapshot.ModelBreakdown = [TokenRaderUsageHistoryModelSnapshot[]]@($historyModel)
    [TokenRaderIndexer]::SaveUsageHistorySnapshot($correctness, $historySnapshot)
    $loadedHistory = [TokenRaderIndexer]::GetUsageHistorySnapshot(
        $correctness, $historySnapshot.WindowStartTicks, $historySnapshot.WindowEndTicks, 7, 'synthetic-pricing')
    Assert-AggregateTest ($null -ne $loadedHistory -and $loadedHistory.TotalInput -eq 1000 -and $loadedHistory.PricingComplete) 'disk usage-history snapshot did not round-trip'
    Assert-AggregateTest ($loadedHistory.ModelBreakdown.Count -eq 1 -and $loadedHistory.ModelBreakdown[0].Model -eq 'gpt-5.5' -and $loadedHistory.ModelBreakdown[0].TotalInput -eq 1000) 'disk per-model usage history did not round-trip'
    Assert-AggregateTest ([TokenRaderIndexer]::GetUsageHistoryCount($correctness) -eq 1) 'usage-history row count changed'
    $removedHistory = [TokenRaderIndexer]::PurgeUsageHistory($correctness, $historySnapshot.WindowEndTicks + 1)
    Assert-AggregateTest ($removedHistory -eq 1 -and [TokenRaderIndexer]::GetUsageHistoryCount($correctness) -eq 0) 'seven-day usage-history purge did not remove an expired snapshot'

    $cancelled = [Threading.CancellationTokenSource]::new()
    try {
        $cancelled.Cancel()
        $cancelObserved = $false
        try {
            [void][TokenRaderIndexer]::AggregateIntervalRecords(
                $correctness, $starts, $ends, $startedAt, $thresholds, $cancelled.Token, $null)
        } catch {
            $exception = $_.Exception
            while ($null -ne $exception -and $exception -isnot [OperationCanceledException]) { $exception = $exception.InnerException }
            $cancelObserved = $null -ne $exception
        }
        Assert-AggregateTest $cancelObserved 'pre-cancelled aggregate did not observe its cancellation token'
    } finally { $cancelled.Dispose() }
} finally {
    $correctness.Close()
    $correctness.Dispose()
}

if ($IncludeLegacyInterference) {
    # Large in-memory fixture reproduces the production shape without reading
    # or retaining any real Codex content: 108,010 valid offset rows plus
    # 1,885,000 legacy rows that have no source path/offset.
    $performance = New-Object System.Data.SQLite.SQLiteConnection 'Data Source=:memory:;Version=3;New=True;'
    $performance.Open()
    try {
        [TokenRaderIndexer]::CreateSchema($performance)
        Invoke-TestSql $performance 'DROP INDEX IF EXISTS idx_records_session; DROP INDEX IF EXISTS idx_records_timestamp; DROP INDEX IF EXISTS idx_records_model; DROP INDEX IF EXISTS idx_records_source_offset; DROP INDEX IF EXISTS idx_records_root_session;'
        Invoke-TestSql $performance @'
WITH RECURSIVE n(x) AS (SELECT 0 UNION ALL SELECT x+1 FROM n WHERE x<999)
INSERT INTO token_records
(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,
 call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,
 source_offset_end,root_session_id,index_revision)
SELECT 'valid-' || seq, '2026-08-28T00:00:00Z',
       CASE WHEN seq % 2 = 0 THEN 'gpt-5.5' ELSE 'gpt-5.6-sol' END,
       seq,100,10,0,1000,100,10,0,CAST(seq AS TEXT),'synthetic://valid',seq,
       'root-' || seq,1
FROM (SELECT a.x*1000+b.x+1 AS seq FROM n AS a CROSS JOIN n AS b)
WHERE seq<=108010;
'@
        Invoke-TestSql $performance @'
WITH RECURSIVE n(x) AS (SELECT 0 UNION ALL SELECT x+1 FROM n WHERE x<999),
two(x) AS (SELECT 0 UNION ALL SELECT 1)
INSERT INTO token_records
(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,
 call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,
 source_offset_end,root_session_id,index_revision)
SELECT 'legacy-' || seq,'2026-08-01T00:00:00Z','gpt-5.5',seq,0,0,0,
       1,0,0,0,CAST(seq AS TEXT),'',0,'legacy-root-' || seq,0
FROM (SELECT c.x*1000000+a.x*1000+b.x+1 AS seq
      FROM two AS c CROSS JOIN n AS a CROSS JOIN n AS b)
WHERE seq<=1885000;
'@
        Invoke-TestSql $performance 'CREATE INDEX idx_records_source_offset ON token_records(source_path,source_offset_end);'

        $starts = @{ 'synthetic://valid' = 0L }
        foreach ($profile in @(
            [pscustomobject]@{ Rows = 25815L; MaximumMs = 1000.0 },
            [pscustomobject]@{ Rows = 108010L; MaximumMs = 3000.0 }
        )) {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $aggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
                $performance, $starts, @{ 'synthetic://valid' = [Int64]$profile.Rows },
                $startedAt, $thresholds, $none, $null)
            $watch.Stop()
            Assert-AggregateTest ($aggregate.CountedEvents -eq [Int64]$profile.Rows) ('large interval count changed for ' + $profile.Rows)
            Assert-AggregateTest ($aggregate.ProcessedRows -eq [Int64]$profile.Rows) ('large processed-row diagnostic changed for ' + $profile.Rows)
            Assert-AggregateTest ($watch.Elapsed.TotalMilliseconds -le [double]$profile.MaximumMs) (
                'streamed aggregate exceeded target: rows={0}, elapsed={1:0.0} ms, target={2:0.0} ms' -f
                    $profile.Rows, $watch.Elapsed.TotalMilliseconds, $profile.MaximumMs)
            Write-Output ('AGGREGATE_PERF rows={0} elapsedMs={1:0.0} internalMs={2}' -f
                $profile.Rows, $watch.Elapsed.TotalMilliseconds, $aggregate.ProcessingMilliseconds)
        }
        Invoke-TestSql $performance 'CREATE INDEX idx_records_timestamp ON token_records(timestamp);'
        $historyWatch = [Diagnostics.Stopwatch]::StartNew()
        $historyAggregate = [TokenRaderIndexer]::AggregateTimeRangeRecords(
            $performance,
            [DateTimeOffset]::Parse('2026-08-28T00:00:00Z'),
            [DateTimeOffset]::Parse('2026-08-29T00:00:00Z'),
            $thresholds, $none, $null)
        $historyWatch.Stop()
        Assert-AggregateTest ($historyAggregate.CountedEvents -eq 108010L) 'large rolling history count changed'
        Assert-AggregateTest ($historyWatch.Elapsed.TotalMilliseconds -le 4000.0) (
            'rolling history aggregate exceeded target: rows={0}, elapsed={1:0.0} ms, target=4000.0 ms' -f
                $historyAggregate.CountedEvents, $historyWatch.Elapsed.TotalMilliseconds)
        Write-Output ('HISTORY_PERF rows={0} elapsedMs={1:0.0} internalMs={2}' -f
            $historyAggregate.CountedEvents, $historyWatch.Elapsed.TotalMilliseconds, $historyAggregate.ProcessingMilliseconds)
    } finally {
        $performance.Close()
        $performance.Dispose()
    }
}

Write-Output ('AGGREGATE_TESTS_PASSED edition={0} version={1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
