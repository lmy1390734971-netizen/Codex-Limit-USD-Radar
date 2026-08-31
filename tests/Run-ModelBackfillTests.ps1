[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ModelTest {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('MODEL BACKFILL TEST FAILED: ' + $Message) }
}

function New-ModelTestTokenLine {
    param([string]$Timestamp, [int]$TotalInput, [int]$CallInput)
    return ([ordered]@{
        timestamp = $Timestamp
        type = 'event_msg'
        payload = [ordered]@{
            type = 'token_count'
            info = [ordered]@{
                total_token_usage = [ordered]@{ input_tokens = $TotalInput; cached_input_tokens = 0; output_tokens = 10; reasoning_output_tokens = 0 }
                last_token_usage = [ordered]@{ input_tokens = $CallInput; cached_input_tokens = 0; output_tokens = 10; reasoning_output_tokens = 0 }
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress)
}

function New-ModelTestTurnLine {
    param([string]$Timestamp, [string]$Model)
    return ([ordered]@{ timestamp = $Timestamp; type = 'turn_context'; payload = [ordered]@{ model = $Model } } |
        ConvertTo-Json -Depth 5 -Compress)
}

function Write-ModelTestLog {
    param([string]$Path, [string[]]$Lines)
    $text = ($Lines -join "`n") + "`n"
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
    $offsets = New-Object 'System.Collections.Generic.List[long]'
    [long]$offset = 0
    foreach ($line in $Lines) {
        $offset += [Text.Encoding]::UTF8.GetByteCount($line + "`n")
        $offsets.Add($offset)
    }
    return @($offsets)
}

function Add-ModelTestMetadata {
    param($Connection, [string]$Path, [string]$Session, [string]$Parent, [string]$Root)
    $cmd = $Connection.CreateCommand()
    try {
        $cmd.CommandText = @'
INSERT OR REPLACE INTO file_metadata
(path,length,last_write_ticks,parsed_offset,session_id,cwd,parent_thread_id,forked_from_id,content_retained,root_session_id)
VALUES (@path,0,0,0,@session,'',@parent,'',1,@root)
'@
        [void]$cmd.Parameters.AddWithValue('@path', $Path)
        [void]$cmd.Parameters.AddWithValue('@session', $Session)
        [void]$cmd.Parameters.AddWithValue('@parent', $Parent)
        [void]$cmd.Parameters.AddWithValue('@root', $Root)
        [void]$cmd.ExecuteNonQuery()
    } finally { $cmd.Dispose() }
}

function Add-ModelTestEmptyRow {
    param($Connection, [string]$Path, [string]$Session, [string]$Root, [long]$Offset, [int]$Total)
    $cmd = $Connection.CreateCommand()
    try {
        $cmd.CommandText = @'
INSERT INTO token_records
(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,
 call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,
 source_offset_end,root_session_id,index_revision,model_source)
VALUES (@session,'2026-08-30T00:00:00Z','',@total,0,10,0,@total,0,10,0,
 @fingerprint,@path,@offset,@root,1,'')
'@
        [void]$cmd.Parameters.AddWithValue('@session', $Session)
        [void]$cmd.Parameters.AddWithValue('@total', $Total)
        [void]$cmd.Parameters.AddWithValue('@fingerprint', ($Total.ToString() + ':0:10:0:' + $Total.ToString() + ':0:10:0'))
        [void]$cmd.Parameters.AddWithValue('@path', $Path)
        [void]$cmd.Parameters.AddWithValue('@offset', $Offset)
        [void]$cmd.Parameters.AddWithValue('@root', $Root)
        [void]$cmd.ExecuteNonQuery()
    } finally { $cmd.Dispose() }
}

function Get-ModelTestRows {
    param($Connection, [string]$Session)
    $table = [Data.DataTable]::new()
    $cmd = $Connection.CreateCommand()
    try {
        $cmd.CommandText = 'SELECT model,model_source,source_offset_end FROM token_records WHERE session_id=@session ORDER BY source_offset_end'
        [void]$cmd.Parameters.AddWithValue('@session', $Session)
        $adapter = [System.Data.SQLite.SQLiteDataAdapter]::new($cmd)
        try { [void]$adapter.Fill($table) } finally { $adapter.Dispose() }
    } finally { $cmd.Dispose() }
    return ,$table
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$sqliteDll = Join-Path $projectRoot 'indexer\System.Data.SQLite.dll'
$indexerDll = Join-Path $projectRoot 'indexer\TokenRader.Indexer.dll'
if ($null -eq ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
if ($null -eq ('TokenRaderIndexer' -as [type])) { Add-Type -Path $indexerDll }

$tempRoot = Join-Path $env:TEMP ('token-rader-model-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$db = [System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
$db.Open()
try {
    [TokenRaderIndexer]::CreateSchema($db)
    $rootId = '10000000-0000-0000-0000-000000000001'
    $childId = '10000000-0000-0000-0000-000000000002'
    $rootPath = Join-Path $tempRoot ('rollout-' + $rootId + '.jsonl')
    $childPath = Join-Path $tempRoot ('rollout-' + $childId + '.jsonl')
    $rootLines = @(
        (New-ModelTestTurnLine '2026-08-30T00:00:00Z' 'gpt-5.6-sol'),
        (New-ModelTestTokenLine '2026-08-30T00:00:01Z' 1000 1000)
    )
    $childLines = @(
        (New-ModelTestTokenLine '2026-08-30T00:00:02Z' 1000 1000),
        (New-ModelTestTurnLine '2026-08-30T00:00:03Z' 'gpt-5.6-luna'),
        (New-ModelTestTokenLine '2026-08-30T00:00:04Z' 2000 1000)
    )
    [void](Write-ModelTestLog $rootPath $rootLines)
    [void](Write-ModelTestLog $childPath $childLines)
    [void][TokenRaderIndexer]::ImportFile($db, $rootPath, 0L, [IO.FileInfo]::new($rootPath).Length, $rootId, '', 1L)
    [void][TokenRaderIndexer]::ImportFile($db, $childPath, 0L, [IO.FileInfo]::new($childPath).Length, $rootId, $rootId, 1L)
    $childRows = Get-ModelTestRows $db $childId
    Assert-ModelTest ($childRows.Rows.Count -eq 2) 'relationship-aware child import row count'
    Assert-ModelTest ([string]$childRows.Rows[0]['model'] -eq 'gpt-5.6-sol' -and [string]$childRows.Rows[0]['model_source'] -eq 'parent') 'pre-turn child row did not inherit its direct parent model'
    Assert-ModelTest ([string]$childRows.Rows[1]['model'] -eq 'gpt-5.6-luna' -and [string]$childRows.Rows[1]['model_source'] -eq 'turn_context') 'post-turn child row did not switch to its own model'

    $metadataId = '10000000-0000-0000-0000-000000000007'
    $metadataPath = Join-Path $tempRoot ('rollout-' + $metadataId + '.jsonl')
    $metadataLines = @(
        '{"timestamp":"2026-08-30T00:01:00Z","type":"turn_context","payload":{"turn_id":"turn-synthetic","model":"gpt-5.6-sol","service_tier":"priority","reasoning_effort":"ultra"}}',
        '{"timestamp":"2026-08-30T00:01:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":10,"reasoning_output_tokens":4},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":10,"reasoning_output_tokens":4}},"rate_limits":{"plan_type":"pro","limit_id":"codex","limit_name":"main","credits":{"balance":3,"has_credits":true,"unlimited":false},"primary":{"used_percent":25,"window_minutes":10080,"resets_at":1890000000,"used_tokens":2500,"remaining_tokens":7500,"limit_tokens":10000},"secondary":{"used_percent":10,"window_minutes":300,"resets_at":1889500000,"used_tokens":100,"remaining_tokens":900,"limit_tokens":1000}}}}'
    )
    [void](Write-ModelTestLog $metadataPath $metadataLines)
    [void][TokenRaderIndexer]::ImportFile($db, $metadataPath, 0L, [IO.FileInfo]::new($metadataPath).Length, $metadataId, '', 1L)
    $metadataCommand = $db.CreateCommand()
    try {
        $metadataCommand.CommandText = 'SELECT turn_id,identity_source,service_tier,reasoning_effort,rate_limit_id,rate_limit_name,credits_balance,credits_has,credits_unlimited,five_hour_limit_tokens,weekly_limit_tokens FROM token_records WHERE session_id=@session LIMIT 1'
        [void]$metadataCommand.Parameters.AddWithValue('@session', $metadataId)
        $reader = $metadataCommand.ExecuteReader()
        try {
            Assert-ModelTest ($reader.Read()) 'synthetic metadata token row missing'
            Assert-ModelTest ($reader.GetString(0) -eq 'turn-synthetic' -and $reader.GetString(1) -eq 'turn_id') 'turn identity was not attached to token row'
            Assert-ModelTest ($reader.GetString(2) -eq 'priority' -and $reader.GetString(3) -eq 'ultra') 'service tier or reasoning effort was not inherited'
            Assert-ModelTest ($reader.GetString(4) -eq 'codex' -and $reader.GetString(5) -eq 'main') 'quota namespace metadata missing'
            Assert-ModelTest ($reader.GetDouble(6) -eq 3 -and $reader.GetInt32(7) -eq 1 -and $reader.GetInt32(8) -eq 0) 'credits metadata missing'
            Assert-ModelTest ($reader.GetInt64(9) -eq 1000 -and $reader.GetInt64(10) -eq 10000) 'direct window token capacities missing'
        } finally { $reader.Dispose() }
    } finally { $metadataCommand.Dispose() }

    # Recreate the same child shape as a legacy empty-model index. A later
    # same-session Luna row must not leak backward before the first turn_context.
    $legacyChildId = '10000000-0000-0000-0000-000000000003'
    $legacyPath = Join-Path $tempRoot ('rollout-' + $legacyChildId + '.jsonl')
    $legacyOffsets = Write-ModelTestLog $legacyPath $childLines
    Add-ModelTestMetadata $db $legacyPath $legacyChildId $rootId $rootId
    Add-ModelTestEmptyRow $db $legacyPath $legacyChildId $rootId $legacyOffsets[0] 1000
    Add-ModelTestEmptyRow $db $legacyPath $legacyChildId $rootId $legacyOffsets[2] 2000
    [TokenRaderIndexer]::SetSetting($db, 'missing_model_backfill_version', '0')
    $revisionBefore = [TokenRaderIndexer]::GetIndexRevision($db)
    $backfill = [TokenRaderIndexer]::BackfillMissingTokenModels($db)
    $legacyRows = Get-ModelTestRows $db $legacyChildId
    Assert-ModelTest ($backfill.Completed -and $backfill.UpdatedRows -eq 2) 'legacy empty-model backfill did not complete'
    Assert-ModelTest ([string]$legacyRows.Rows[0]['model'] -eq 'gpt-5.6-sol' -and [string]$legacyRows.Rows[0]['model_source'] -eq 'parent') 'backfill assigned a later child model to a pre-turn row'
    Assert-ModelTest ([string]$legacyRows.Rows[1]['model'] -eq 'gpt-5.6-luna' -and [string]$legacyRows.Rows[1]['model_source'] -eq 'turn_context') 'backfill did not switch after child turn_context'
    Assert-ModelTest ($backfill.IndexRevision -gt $revisionBefore) 'backfill did not invalidate revision-based cost caches'
    $again = [TokenRaderIndexer]::BackfillMissingTokenModels($db)
    Assert-ModelTest ($again.Completed -and $again.UpdatedRows -eq 0 -and $again.IndexRevision -eq $backfill.IndexRevision) 'backfill is not idempotent'

    $retryId = '10000000-0000-0000-0000-000000000006'
    $retryPath = Join-Path $tempRoot ('rollout-' + $retryId + '.jsonl')
    $retryOffsets = Write-ModelTestLog $retryPath @((New-ModelTestTokenLine '2026-08-30T00:00:05Z' 600 600))
    Add-ModelTestMetadata $db $retryPath $retryId $rootId $rootId
    Add-ModelTestEmptyRow $db $retryPath $retryId $rootId ($retryOffsets[0] + 1L) 600
    [TokenRaderIndexer]::SetSetting($db, 'missing_model_backfill_version', '0')
    $failed = [TokenRaderIndexer]::BackfillMissingTokenModels($db)
    Assert-ModelTest (-not $failed.Completed -and $failed.FailedFiles -eq 1 -and $failed.FailedSourcePaths[0] -eq $retryPath) 'offset mismatch did not leave the backfill retryable'
    $fix = $db.CreateCommand()
    try {
        $fix.CommandText = 'UPDATE token_records SET source_offset_end=@offset WHERE source_path=@path'
        [void]$fix.Parameters.AddWithValue('@offset', [Int64]$retryOffsets[0])
        [void]$fix.Parameters.AddWithValue('@path', $retryPath)
        [void]$fix.ExecuteNonQuery()
    } finally { $fix.Dispose() }
    $retried = [TokenRaderIndexer]::BackfillMissingTokenModels($db)
    $retryRows = Get-ModelTestRows $db $retryId
    Assert-ModelTest ($retried.Completed -and [string]$retryRows.Rows[0]['model'] -eq 'gpt-5.6-sol') 'failed model backfill did not succeed on retry'

    # A missing source can be recovered from a root model when its direct
    # parent has no known model. A true orphan remains explicitly unresolved.
    $rootFallbackId = '10000000-0000-0000-0000-000000000004'
    $rootFallbackPath = Join-Path $tempRoot 'missing-root-fallback.jsonl'
    Add-ModelTestMetadata $db $rootFallbackPath $rootFallbackId 'no-model-parent' $rootId
    Add-ModelTestEmptyRow $db $rootFallbackPath $rootFallbackId $rootId 10 500
    $orphanId = '10000000-0000-0000-0000-000000000005'
    $orphanPath = Join-Path $tempRoot 'missing-orphan.jsonl'
    Add-ModelTestMetadata $db $orphanPath $orphanId '' $orphanId
    Add-ModelTestEmptyRow $db $orphanPath $orphanId $orphanId 10 500
    [TokenRaderIndexer]::SetSetting($db, 'missing_model_backfill_version', '0')
    $fallback = [TokenRaderIndexer]::BackfillMissingTokenModels($db)
    $rootFallbackRows = Get-ModelTestRows $db $rootFallbackId
    $orphanRows = Get-ModelTestRows $db $orphanId
    Assert-ModelTest ([string]$rootFallbackRows.Rows[0]['model'] -eq 'gpt-5.6-sol' -and [string]$rootFallbackRows.Rows[0]['model_source'] -eq 'root') 'root fallback did not recover a missing-source child model'
    Assert-ModelTest ([string]$orphanRows.Rows[0]['model'] -eq '' -and [string]$orphanRows.Rows[0]['model_source'] -eq 'unresolved') 'orphan model was guessed instead of remaining unresolved'
    Assert-ModelTest ($fallback.Completed -and $fallback.UnresolvedRows -eq 1) 'unresolved orphan diagnostics changed'

    Write-Output 'MODEL_BACKFILL_TESTS_PASSED'
} finally {
    $db.Dispose()
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
