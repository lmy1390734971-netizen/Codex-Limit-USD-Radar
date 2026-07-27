Set-StrictMode -Version Latest

function Get-TokenRaderPaths {
    param([string]$ProjectRoot = $PSScriptRoot)

    $codexRoot = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    } else {
        Join-Path $HOME '.codex'
    }

    [pscustomobject]@{
        ProjectRoot = $ProjectRoot
        CodexRoot = $codexRoot
        SessionsRoot = Join-Path $codexRoot 'sessions'
        AccountMetadataPath = Join-Path $codexRoot '.cockpit_codex_auth.json'
        PricingPath = Join-Path $ProjectRoot 'pricing.json'
    }
}

function Get-TokenRaderAccount {
    param([Parameter(Mandatory = $true)][string]$CodexRoot)

    # This intentionally does not read auth.json, because that file contains access,
    # ID, and refresh tokens. The small cockpit metadata file contains labels only.
    $path = Join-Path $CodexRoot '.cockpit_codex_auth.json'
    $fallback = [pscustomobject]@{
        Found = $false
        Email = ''
        AccountId = ''
        AccountIdShort = ''
        WrittenAt = $null
        DisplayName = '未检测到当前账号'
    }
    if (-not (Test-Path -LiteralPath $path)) { return $fallback }

    try {
        $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
        $accountId = [string]$metadata.account_id
        $email = [string]$metadata.email
        $shortId = $accountId
        if ($shortId.Length -gt 18) {
            $shortId = $shortId.Substring(0, 8) + '…' + $shortId.Substring($shortId.Length - 6)
        }
        $display = if (-not [string]::IsNullOrWhiteSpace($email)) { $email }
                   elseif (-not [string]::IsNullOrWhiteSpace($shortId)) { $shortId }
                   else { '当前 Codex 账号' }
        $writtenAt = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$metadata.written_at)) {
            try { $writtenAt = [DateTimeOffset]::Parse([string]$metadata.written_at).ToLocalTime() } catch { }
        }
        [pscustomobject]@{
            Found = $true
            Email = $email
            AccountId = $accountId
            AccountIdShort = $shortId
            WrittenAt = $writtenAt
            DisplayName = $display
        }
    } catch {
        return $fallback
    }
}

function Format-TokenRaderFileSize {
    param([Int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Get-TokenRaderSessionFiles {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [int]$MaximumFiles = 200
    )

    if (-not (Test-Path -LiteralPath $SessionsRoot)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First ([Math]::Max(1, $MaximumFiles)))

    $result = foreach ($file in $files) {
        $match = [regex]::Match($file.BaseName, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$')
        $sessionId = if ($match.Success) { $match.Groups[1].Value } else { $file.BaseName }
        $shortId = if ($sessionId.Length -gt 8) { $sessionId.Substring(0, 8) } else { $sessionId }
        [pscustomobject]@{
            FilePath = $file.FullName
            SessionId = $sessionId
            ShortId = $shortId
            LastWriteTime = $file.LastWriteTime
            LastWriteTimeUtc = $file.LastWriteTimeUtc
            Length = [Int64]$file.Length
            DisplayName = ('{0:MM-dd HH:mm}   {1}   {2}' -f $file.LastWriteTime, $shortId, (Format-TokenRaderFileSize $file.Length))
        }
    }
    return @($result)
}

function New-TokenRaderUsage {
    param(
        [Int64]$InputTokens,
        [Int64]$CachedTokens,
        [Int64]$OutputTokens,
        [Int64]$ReasoningOutputTokens = 0
    )

    $cachedTokens = [Math]::Min([Math]::Max([Int64]0, $CachedTokens), [Math]::Max([Int64]0, $InputTokens))
    $inputTokens = [Math]::Max([Int64]0, $InputTokens)
    $outputTokens = [Math]::Max([Int64]0, $OutputTokens)
    $uncachedTokens = [Math]::Max([Int64]0, $inputTokens - $cachedTokens)
    $totalTokens = $inputTokens + $outputTokens
    $hitRate = if ($inputTokens -gt 0) { ($cachedTokens * 100.0) / $inputTokens } else { 0.0 }

    [pscustomobject]@{
        Input = $inputTokens
        Cached = $cachedTokens
        Uncached = $uncachedTokens
        Output = $outputTokens
        ReasoningOutput = [Math]::Max([Int64]0, $ReasoningOutputTokens)
        Total = $totalTokens
        CacheHitRate = [double]$hitRate
    }
}

function ConvertTo-TokenRaderUsage {
    param([Parameter(Mandatory = $true)]$RawUsage)

    $reasoning = if ($null -ne $RawUsage.PSObject.Properties['reasoning_output_tokens']) { [Int64]$RawUsage.reasoning_output_tokens } else { 0 }
    New-TokenRaderUsage `
        -InputTokens ([Int64]$RawUsage.input_tokens) `
        -CachedTokens ([Int64]$RawUsage.cached_input_tokens) `
        -OutputTokens ([Int64]$RawUsage.output_tokens) `
        -ReasoningOutputTokens $reasoning
}

function Get-TokenRaderSessionIdFromPath {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    $match = [regex]::Match($baseName, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$')
    if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }
    return $baseName.ToLowerInvariant()
}

function Get-TokenRaderSessionMetadata {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $fallbackId = Get-TokenRaderSessionIdFromPath -FilePath $FilePath
    $fallback = [pscustomobject]@{
        SessionId = $fallbackId
        ParentThreadId = ''
        ForkedFromId = ''
        RootHint = $fallbackId
        Cwd = ''
    }
    if (-not (Test-Path -LiteralPath $FilePath)) { return $fallback }

    $stream = $null
    $reader = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 65536)
        for ($i = 0; $i -lt 64 -and -not $reader.EndOfStream; $i++) {
            $line = $reader.ReadLine()
            if ($line.IndexOf('session_meta', [System.StringComparison]::Ordinal) -lt 0) { continue }
            try { $record = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { continue }
            if ($record.type -ne 'session_meta' -or $null -eq $record.payload) { continue }
            $payload = $record.payload
            $sessionId = if ($null -ne $payload.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.id)) {
                ([string]$payload.id).ToLowerInvariant()
            } elseif ($null -ne $payload.PSObject.Properties['session_id'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.session_id)) {
                ([string]$payload.session_id).ToLowerInvariant()
            } else { $fallbackId }
            $parentId = if ($null -ne $payload.PSObject.Properties['parent_thread_id']) { ([string]$payload.parent_thread_id).ToLowerInvariant() } else { '' }
            $forkedId = if ($null -ne $payload.PSObject.Properties['forked_from_id']) { ([string]$payload.forked_from_id).ToLowerInvariant() } else { '' }
            $cwd = if ($null -ne $payload.PSObject.Properties['cwd']) { [string]$payload.cwd } else { '' }
            return [pscustomobject]@{
                SessionId = $sessionId
                ParentThreadId = $parentId
                ForkedFromId = $forkedId
                RootHint = if (-not [string]::IsNullOrWhiteSpace($parentId)) { $parentId } elseif (-not [string]::IsNullOrWhiteSpace($forkedId)) { $forkedId } else { $sessionId }
                Cwd = $cwd
            }
        }
    } catch {
        return $fallback
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
    return $fallback
}

function Get-TokenRaderProjects {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [int]$MaximumFiles = 0
    )

    if (-not (Test-Path -LiteralPath $SessionsRoot)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($MaximumFiles -gt 0 -and $files.Count -gt $MaximumFiles) {
        $files = @($files | Select-Object -First $MaximumFiles)
    }

    $groups = @{}
    foreach ($file in $files) {
        $metadata = Get-TokenRaderSessionMetadata -FilePath $file.FullName
        $cwd = [string]$metadata.Cwd
        if ([string]::IsNullOrWhiteSpace($cwd)) { continue }
        try { $cwd = [IO.Path]::GetFullPath($cwd).TrimEnd([char]'\', [char]'/') } catch { $cwd = $cwd.TrimEnd([char]'\', [char]'/') }
        if ([string]::IsNullOrWhiteSpace($cwd)) { continue }
        $key = $cwd.ToLowerInvariant()
        if (-not $groups.ContainsKey($key)) {
            $name = [IO.Path]::GetFileName($cwd)
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $cwd }
            $groups[$key] = [pscustomobject]@{
                ProjectPath = $cwd
                ProjectName = $name
                LastWriteTime = $file.LastWriteTime
                LastWriteTimeUtc = $file.LastWriteTimeUtc
                TotalBytes = [Int64]0
                FilePaths = New-Object System.Collections.ArrayList
            }
        }
        $group = $groups[$key]
        [void]$group.FilePaths.Add($file.FullName)
        $group.TotalBytes += [Int64]$file.Length
        if ($file.LastWriteTimeUtc -gt $group.LastWriteTimeUtc) {
            $group.LastWriteTime = $file.LastWriteTime
            $group.LastWriteTimeUtc = $file.LastWriteTimeUtc
        }
    }

    $result = foreach ($group in $groups.Values) {
        $paths = @($group.FilePaths | Sort-Object)
        $signatureParts = foreach ($path in $paths) {
            try {
                $item = Get-Item -LiteralPath $path -ErrorAction Stop
                '{0}|{1}|{2}' -f $path, [Int64]$item.Length, $item.LastWriteTimeUtc.Ticks
            } catch { '{0}|missing' -f $path }
        }
        [pscustomobject]@{
            ProjectPath = [string]$group.ProjectPath
            ProjectName = [string]$group.ProjectName
            SessionCount = $paths.Count
            LastWriteTime = $group.LastWriteTime
            LastWriteTimeUtc = $group.LastWriteTimeUtc
            TotalBytes = [Int64]$group.TotalBytes
            FilePaths = $paths
            Signature = $signatureParts -join ';'
            DisplayName = ('{0}  ·  {1} 个日志' -f [string]$group.ProjectName, $paths.Count)
        }
    }
    return @($result | Sort-Object LastWriteTimeUtc -Descending)
}

function Get-TokenRaderUsageEvents {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Int64]$StartOffset = 0,
        [Int64]$EndOffset = 0,
        [string]$InitialModel = '',
        [Int64]$MaximumLineBytes = 4MB
    )

    $events = New-Object System.Collections.ArrayList
    $state = [pscustomobject]@{ Model = $InitialModel }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return [pscustomobject]@{ Events = @(); LastModel = $InitialModel; BytesRead = 0 }
    }

    $processLine = {
        param([string]$LineText)
        if ([string]::IsNullOrWhiteSpace($LineText)) { return }
        $hasTurnContext = $LineText.IndexOf('turn_context', [System.StringComparison]::Ordinal) -ge 0
        $hasTokenCount = $LineText.IndexOf('token_count', [System.StringComparison]::Ordinal) -ge 0
        if (-not $hasTurnContext -and -not $hasTokenCount) { return }
        try { $record = $LineText.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { return }

        if ($record.type -eq 'turn_context') {
            if ($null -ne $record.payload -and $null -ne $record.payload.PSObject.Properties['model']) {
                $candidate = [string]$record.payload.model
                if (-not [string]::IsNullOrWhiteSpace($candidate)) { $state.Model = $candidate }
            }
            return
        }

        $isTokenRecord = ($record.type -eq 'event_msg' -and $record.payload.type -eq 'token_count') -or ($record.type -eq 'token_count')
        if (-not $isTokenRecord -or $null -eq $record.payload -or $null -eq $record.payload.info) { return }
        $info = $record.payload.info
        if ($null -eq $info.total_token_usage -or $null -eq $info.last_token_usage) { return }
        $totalUsage = ConvertTo-TokenRaderUsage $info.total_token_usage
        $callUsage = ConvertTo-TokenRaderUsage $info.last_token_usage
        $timestamp = [DateTimeOffset]::Now
        try { $timestamp = [DateTimeOffset]::Parse([string]$record.timestamp).ToLocalTime() } catch { }
        $rateLimits = ConvertTo-TokenRaderRateLimits -RawRateLimits $(if ($null -ne $record.payload.PSObject.Properties['rate_limits']) { $record.payload.rate_limits } else { $null }) -ObservedAt $timestamp
        $fingerprint = @(
            $totalUsage.Input, $totalUsage.Cached, $totalUsage.Output, $totalUsage.ReasoningOutput,
            $callUsage.Input, $callUsage.Cached, $callUsage.Output, $callUsage.ReasoningOutput
        ) -join ':'
        [void]$events.Add([pscustomobject]@{
            Timestamp = $timestamp
            Model = [string]$state.Model
            Total = $totalUsage
            Call = $callUsage
            Fingerprint = $fingerprint
            RateLimits = $rateLimits
        })
    }

    $stream = $null
    $lineBuffer = New-Object System.IO.MemoryStream
    [Int64]$bytesReadTotal = 0
    try {
        $stream = New-Object System.IO.FileStream(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $effectiveStart = [Math]::Max([Int64]0, [Math]::Min([Int64]$stream.Length, $StartOffset))
        $effectiveEnd = if ($EndOffset -gt 0) { [Math]::Min([Int64]$stream.Length, $EndOffset) } else { [Int64]$stream.Length }
        if ($effectiveEnd -le $effectiveStart) {
            return [pscustomobject]@{ Events = @(); LastModel = [string]$state.Model; BytesRead = 0 }
        }

        $discardLine = $false
        if ($effectiveStart -gt 0) {
            [void]$stream.Seek($effectiveStart - 1, [System.IO.SeekOrigin]::Begin)
            $previousByte = $stream.ReadByte()
            $discardLine = ($previousByte -ne 10)
        }
        [void]$stream.Seek($effectiveStart, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] (1MB)
        [Int64]$remaining = $effectiveEnd - $effectiveStart
        while ($remaining -gt 0) {
            $requested = [int][Math]::Min([Int64]$buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $requested)
            if ($read -le 0) { break }
            $remaining -= $read
            $bytesReadTotal += $read
            $position = 0
            while ($position -lt $read) {
                $newLine = [Array]::IndexOf($buffer, [byte]10, $position, $read - $position)
                $segmentEnd = if ($newLine -ge 0) { $newLine } else { $read }
                $segmentLength = $segmentEnd - $position
                if (-not $discardLine -and $segmentLength -gt 0) {
                    if (($lineBuffer.Length + $segmentLength) -le $MaximumLineBytes) {
                        $lineBuffer.Write($buffer, $position, $segmentLength)
                    } else {
                        $discardLine = $true
                        $lineBuffer.SetLength(0)
                    }
                }
                if ($newLine -lt 0) { break }
                if (-not $discardLine -and $lineBuffer.Length -gt 0) {
                    $lineText = [Text.Encoding]::UTF8.GetString($lineBuffer.ToArray()).TrimEnd("`r")
                    & $processLine $lineText
                }
                $lineBuffer.SetLength(0)
                $discardLine = $false
                $position = $newLine + 1
            }
        }
        if (-not $discardLine -and $lineBuffer.Length -gt 0) {
            $lineText = [Text.Encoding]::UTF8.GetString($lineBuffer.ToArray()).TrimEnd("`r")
            & $processLine $lineText
        }
    } catch {
        return [pscustomobject]@{ Events = @($events); LastModel = [string]$state.Model; BytesRead = $bytesReadTotal }
    } finally {
        $lineBuffer.Dispose()
        if ($null -ne $stream) { $stream.Dispose() }
    }

    [pscustomobject]@{
        Events = @($events)
        LastModel = [string]$state.Model
        BytesRead = $bytesReadTotal
    }
}

function ConvertTo-TokenRaderRateWindow {
    param([Parameter(Mandatory = $true)]$RawWindow)

    $usedPercent = [Math]::Max(0.0, [Math]::Min(100.0, [double]$RawWindow.used_percent))
    $windowMinutes = [int]$RawWindow.window_minutes
    $resetValue = $null
    foreach ($propertyName in @('resets_at', 'reset_at')) {
        if ($null -ne $RawWindow.PSObject.Properties[$propertyName] -and $null -ne $RawWindow.$propertyName) {
            $resetValue = $RawWindow.$propertyName
            break
        }
    }
    $resetsAt = $null
    if ($null -ne $resetValue) {
        try { $resetsAt = [DateTimeOffset]::FromUnixTimeSeconds([Int64]$resetValue).ToLocalTime() } catch { }
    }

    [pscustomobject]@{
        UsedPercent = $usedPercent
        RemainingPercent = 100.0 - $usedPercent
        WindowMinutes = $windowMinutes
        ResetsAt = $resetsAt
    }
}

function ConvertTo-TokenRaderRateLimits {
    param(
        $RawRateLimits,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt
    )

    $fiveHour = $null
    $weekly = $null
    $planType = ''
    if ($null -ne $RawRateLimits) {
        if ($null -ne $RawRateLimits.PSObject.Properties['plan_type']) { $planType = [string]$RawRateLimits.plan_type }
        foreach ($propertyName in @('primary', 'secondary')) {
            if ($null -eq $RawRateLimits.PSObject.Properties[$propertyName]) { continue }
            $rawWindow = $RawRateLimits.$propertyName
            if ($null -eq $rawWindow -or $null -eq $rawWindow.PSObject.Properties['window_minutes'] -or $null -eq $rawWindow.PSObject.Properties['used_percent']) { continue }
            $window = ConvertTo-TokenRaderRateWindow -RawWindow $rawWindow
            if ($window.WindowMinutes -ge 240 -and $window.WindowMinutes -le 360) { $fiveHour = $window }
            elseif ($window.WindowMinutes -ge 9000) { $weekly = $window }
        }
    }

    [pscustomobject]@{
        ObservedAt = $ObservedAt
        PlanType = $planType
        FiveHour = $fiveHour
        Weekly = $weekly
    }
}

function Get-TokenRaderUsageSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [int]$Tail = 5000,
        [Int64]$MaximumTailBytes = 16MB,
        [Int64]$EndOffset = 0
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
    $stream = $null
    try {
        # Get-Content -Tail can become very slow when a JSONL log contains multi-megabyte
        # tool-output lines. Reading a bounded byte window keeps the HUD responsive while
        # still covering far more records than are normally needed for the latest count.
        $stream = New-Object System.IO.FileStream(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $effectiveEnd = if ($EndOffset -gt 0) { [Math]::Min([Int64]$stream.Length, $EndOffset) } else { [Int64]$stream.Length }
        if ($effectiveEnd -le 0) { return $null }
        $bytesToRead = [Math]::Min($effectiveEnd, [Math]::Max([Int64]65536, $MaximumTailBytes))
        [void]$stream.Seek($effectiveEnd - $bytesToRead, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ([int]$bytesToRead)
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $offset)
        if ($bytesToRead -lt $effectiveEnd) {
            $firstNewLine = $text.IndexOf("`n", [System.StringComparison]::Ordinal)
            if ($firstNewLine -ge 0) { $text = $text.Substring($firstNewLine + 1) }
        }
        $allLines = @($text -split "`r?`n")
        if ($allLines.Count -gt $Tail) {
            $lines = @($allLines | Select-Object -Last $Tail)
        } else {
            $lines = $allLines
        }
    } catch {
        return $null
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $tokenRecord = $null
    $tokenIndex = -1
    $model = ''
    $fallbackModel = ''

    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = ([string]$lines[$i]).TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.IndexOf('token_count', [System.StringComparison]::Ordinal) -lt 0 -and
            $line.IndexOf('turn_context', [System.StringComparison]::Ordinal) -lt 0) { continue }

        try { $record = $line | ConvertFrom-Json } catch { continue }

        if ($record.type -eq 'turn_context') {
            $candidate = [string]$record.payload.model
            if ([string]::IsNullOrWhiteSpace($fallbackModel) -and -not [string]::IsNullOrWhiteSpace($candidate)) {
                $fallbackModel = $candidate
            }
            if ($null -ne $tokenRecord -and [string]::IsNullOrWhiteSpace($model) -and -not [string]::IsNullOrWhiteSpace($candidate)) {
                $model = $candidate
                break
            }
            continue
        }

        $isTokenRecord = ($record.type -eq 'event_msg' -and $record.payload.type -eq 'token_count') -or
                         ($record.type -eq 'token_count')
        if ($isTokenRecord -and $null -eq $tokenRecord) {
            $tokenRecord = $record
            $tokenIndex = $i
        }
    }

    if ($null -eq $tokenRecord) { return $null }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = $fallbackModel }

    $payload = $tokenRecord.payload
    $info = $payload.info
    if ($null -eq $info -or $null -eq $info.total_token_usage -or $null -eq $info.last_token_usage) { return $null }

    $timestamp = $null
    try { $timestamp = [DateTimeOffset]::Parse([string]$tokenRecord.timestamp).ToLocalTime() } catch { $timestamp = [DateTimeOffset]::Now }
    $planType = ''
    if ($null -ne $payload.PSObject.Properties['rate_limits'] -and $null -ne $payload.rate_limits -and
        $null -ne $payload.rate_limits.PSObject.Properties['plan_type']) {
        $planType = [string]$payload.rate_limits.plan_type
    }
    $rateLimits = ConvertTo-TokenRaderRateLimits -RawRateLimits $(if ($null -ne $payload.PSObject.Properties['rate_limits']) { $payload.rate_limits } else { $null }) -ObservedAt $timestamp

    [pscustomobject]@{
        FilePath = $FilePath
        Timestamp = $timestamp
        Model = $model
        PlanType = $planType
        RateLimits = $rateLimits
        Task = ConvertTo-TokenRaderUsage $info.total_token_usage
        Call = ConvertTo-TokenRaderUsage $info.last_token_usage
        ContextWindow = [Int64]$info.model_context_window
        TailLinesRead = $lines.Count
        TokenRecordIndex = $tokenIndex
    }
}

function Get-TokenRaderLatestRateLimits {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [int]$MaximumFiles = 16
    )

    if (-not (Test-Path -LiteralPath $SessionsRoot)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First ([Math]::Max(1, $MaximumFiles)))
    $fiveHour = $null
    $weekly = $null
    $fiveObserved = [DateTimeOffset]::MinValue
    $weeklyObserved = [DateTimeOffset]::MinValue
    $planType = ''

    foreach ($file in $files) {
        $snapshot = Get-TokenRaderUsageSnapshot -FilePath $file.FullName
        if ($null -eq $snapshot -or $null -eq $snapshot.RateLimits) { continue }
        $rateLimits = $snapshot.RateLimits
        if ($null -ne $rateLimits.FiveHour -and $rateLimits.ObservedAt -gt $fiveObserved) {
            $fiveHour = $rateLimits.FiveHour
            $fiveObserved = $rateLimits.ObservedAt
        }
        if ($null -ne $rateLimits.Weekly -and $rateLimits.ObservedAt -gt $weeklyObserved) {
            $weekly = $rateLimits.Weekly
            $weeklyObserved = $rateLimits.ObservedAt
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$rateLimits.PlanType)) { $planType = [string]$rateLimits.PlanType }
    }

    if ($null -eq $fiveHour -and $null -eq $weekly) { return $null }
    [pscustomobject]@{
        ObservedAt = if ($fiveObserved -gt $weeklyObserved) { $fiveObserved } else { $weeklyObserved }
        PlanType = $planType
        FiveHour = $fiveHour
        Weekly = $weekly
    }
}

function Get-TokenRaderPrices {
    param([Parameter(Mandatory = $true)][string]$PricingPath)

    if (-not (Test-Path -LiteralPath $PricingPath)) { throw "Pricing file not found: $PricingPath" }
    $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $PricingPath | ConvertFrom-Json
    return $document
}

function Resolve-TokenRaderPrice {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory = $true)]$PricingDocument
    )

    if ([string]::IsNullOrWhiteSpace($Model)) { return $null }
    $normalized = $Model.Trim().ToLowerInvariant()
    $entries = @($PricingDocument.models | Sort-Object @{ Expression = { ([string]$_.id).Length }; Descending = $true })

    foreach ($entry in $entries) {
        $id = ([string]$entry.id).ToLowerInvariant()
        $aliases = @($entry.aliases | ForEach-Object { ([string]$_).ToLowerInvariant() })
        if ($normalized -eq $id -or $aliases -contains $normalized) { return $entry }
        if ($normalized.StartsWith($id + '-20', [System.StringComparison]::OrdinalIgnoreCase)) { return $entry }
    }
    return $null
}

function Get-TokenRaderCost {
    param(
        [Parameter(Mandatory = $true)]$Usage,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [ValidateSet('task', 'call')][string]$Scope = 'task'
    )

    $price = Resolve-TokenRaderPrice -Model $Model -PricingDocument $PricingDocument
    if ($null -eq $price) {
        return [pscustomobject]@{
            Known = $false
            Model = $Model
            Price = $null
            InputCost = $null
            CachedCost = $null
            OutputCost = $null
            TotalCost = $null
            LongContextApplied = $false
            InputMultiplier = 1.0
            OutputMultiplier = 1.0
        }
    }

    $inputMultiplier = 1.0
    $outputMultiplier = 1.0
    $longContextApplied = $false
    $threshold = if ($null -ne $price.PSObject.Properties['longContextThreshold']) { [Int64]$price.longContextThreshold } else { 0 }
    if ($Scope -eq 'call' -and $threshold -gt 0 -and [Int64]$Usage.Input -gt $threshold) {
        $inputMultiplier = if ($null -ne $price.PSObject.Properties['longContextInputMultiplier']) { [double]$price.longContextInputMultiplier } else { 2.0 }
        $outputMultiplier = if ($null -ne $price.PSObject.Properties['longContextOutputMultiplier']) { [double]$price.longContextOutputMultiplier } else { 1.5 }
        $longContextApplied = $true
    }

    $inputCost = ([double]$Usage.Uncached / 1000000.0) * [double]$price.input * $inputMultiplier
    $cachedCost = ([double]$Usage.Cached / 1000000.0) * [double]$price.cachedInput * $inputMultiplier
    $outputCost = ([double]$Usage.Output / 1000000.0) * [double]$price.output * $outputMultiplier

    [pscustomobject]@{
        Known = $true
        Model = $Model
        Price = $price
        InputCost = $inputCost
        CachedCost = $cachedCost
        OutputCost = $outputCost
        TotalCost = $inputCost + $cachedCost + $outputCost
        LongContextApplied = $longContextApplied
        InputMultiplier = $inputMultiplier
        OutputMultiplier = $outputMultiplier
    }
}

function New-TokenRaderMeasurementBaseline {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)

    $files = @()
    if (Test-Path -LiteralPath $SessionsRoot) {
        $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                FilePath = $_.FullName
                Length = [Int64]$_.Length
                LastWriteTimeUtc = $_.LastWriteTimeUtc
                BaselineLoaded = $false
                BaselineTask = $null
                BaselineModel = ''
            }
        })
    }

    [pscustomobject]@{
        StartedAt = [DateTimeOffset]::Now
        SessionsRoot = $SessionsRoot
        Files = $files
        RateLimits = Get-TokenRaderLatestRateLimits -SessionsRoot $SessionsRoot
    }
}

function Get-TokenRaderIntervalResult {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [string[]]$IncludedFiles = @()
    )

    $baselineMap = @{}
    foreach ($entry in @($Baseline.Files)) { $baselineMap[[string]$entry.FilePath] = $entry }

    $currentFiles = @()
    if (@($IncludedFiles).Count -gt 0) {
        $currentFiles = @($IncludedFiles | ForEach-Object {
            if (Test-Path -LiteralPath $_) { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue }
        })
    } elseif (Test-Path -LiteralPath ([string]$Baseline.SessionsRoot)) {
        $currentFiles = @(Get-ChildItem -LiteralPath ([string]$Baseline.SessionsRoot) -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
    }
    $fileBySessionId = @{}
    foreach ($file in $currentFiles) { $fileBySessionId[(Get-TokenRaderSessionIdFromPath -FilePath $file.FullName)] = $file.FullName }

    $metadataByPath = @{}
    $metadataBySessionId = @{}
    $loadMetadata = {
        param([string]$FilePath)
        if ($metadataByPath.ContainsKey($FilePath)) { return $metadataByPath[$FilePath] }
        $metadata = Get-TokenRaderSessionMetadata -FilePath $FilePath
        $metadataByPath[$FilePath] = $metadata
        $metadataBySessionId[[string]$metadata.SessionId] = $metadata
        if (-not $fileBySessionId.ContainsKey([string]$metadata.SessionId)) { $fileBySessionId[[string]$metadata.SessionId] = $FilePath }
        return $metadata
    }
    $loadBaselineSnapshot = {
        param($Entry)
        if ($null -eq $Entry) { return $null }
        if (-not [bool]$Entry.BaselineLoaded) {
            $snapshot = Get-TokenRaderUsageSnapshot -FilePath ([string]$Entry.FilePath) -EndOffset ([Int64]$Entry.Length)
            $Entry.BaselineTask = if ($null -ne $snapshot) { $snapshot.Task } else { $null }
            $Entry.BaselineModel = if ($null -ne $snapshot) { [string]$snapshot.Model } else { '' }
            $Entry.BaselineLoaded = $true
        }
        return $Entry.BaselineTask
    }

    $changed = New-Object System.Collections.ArrayList
    foreach ($file in $currentFiles) {
        $baselineEntry = if ($baselineMap.ContainsKey($file.FullName)) { $baselineMap[$file.FullName] } else { $null }
        if ($null -ne $baselineEntry -and [Int64]$file.Length -eq [Int64]$baselineEntry.Length) { continue }
        $metadata = & $loadMetadata $file.FullName
        [void]$changed.Add([pscustomobject]@{
            File = $file
            BaselineEntry = $baselineEntry
            Metadata = $metadata
            IsNew = ($null -eq $baselineEntry)
            RootId = [string]$metadata.SessionId
            Depth = 0
            BaselineAncestor = $null
        })
    }

    foreach ($change in @($changed)) {
        $currentMetadata = $change.Metadata
        $rootId = [string]$currentMetadata.SessionId
        $depth = 0
        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        while ($null -ne $currentMetadata -and $depth -lt 64) {
            if (-not $visited.Add([string]$currentMetadata.SessionId)) { break }
            $parentId = if (-not [string]::IsNullOrWhiteSpace([string]$currentMetadata.ParentThreadId)) {
                [string]$currentMetadata.ParentThreadId
            } else { [string]$currentMetadata.ForkedFromId }
            if ([string]::IsNullOrWhiteSpace($parentId)) { break }
            $rootId = $parentId
            $depth++
            if (-not $fileBySessionId.ContainsKey($parentId)) { break }
            $parentPath = [string]$fileBySessionId[$parentId]
            if ($null -eq $change.BaselineAncestor -and $baselineMap.ContainsKey($parentPath)) {
                $change.BaselineAncestor = $baselineMap[$parentPath]
            }
            $currentMetadata = & $loadMetadata $parentPath
            if ($null -ne $currentMetadata) { $rootId = [string]$currentMetadata.SessionId }
        }
        $change.RootId = $rootId
        $change.Depth = $depth
    }

    [Int64]$aggregateInput = 0
    [Int64]$cached = 0
    [Int64]$output = 0
    [Int64]$reasoning = 0
    [double]$inputCost = 0
    [double]$cachedCost = 0
    [double]$outputCost = 0
    [Int64]$rawEventCount = 0
    [Int64]$countedEventCount = 0
    [Int64]$duplicateEventCount = 0
    [Int64]$inheritedEventCount = 0
    [Int64]$bytesRead = 0
    $seenEvents = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $activeFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $models = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $unknownModels = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $costBuckets = @{}
    $latestRateLimits = $null
    $latestRateObserved = [DateTimeOffset]::MinValue

    foreach ($change in @($changed | Sort-Object Depth, @{ Expression = { $_.File.CreationTimeUtc } })) {
        $baselineTask = $null
        $initialModel = ''
        $startOffset = 0
        if ($null -ne $change.BaselineEntry) {
            $baselineTask = & $loadBaselineSnapshot $change.BaselineEntry
            $initialModel = [string]$change.BaselineEntry.BaselineModel
            $startOffset = [Int64]$change.BaselineEntry.Length
        }
        $ancestorTask = if ($change.IsNew -and $null -ne $change.BaselineAncestor) { & $loadBaselineSnapshot $change.BaselineAncestor } else { $null }
        $parsed = Get-TokenRaderUsageEvents -FilePath $change.File.FullName -StartOffset $startOffset -InitialModel $initialModel
        $bytesRead += [Int64]$parsed.BytesRead
        if (@($parsed.Events).Count -gt 0) { [void]$activeFiles.Add([string]$change.File.FullName) }
        $fallbackModel = [string]$parsed.LastModel

        foreach ($event in @($parsed.Events)) {
            $rawEventCount++
            if ($null -ne $event.RateLimits -and $event.RateLimits.ObservedAt -gt $latestRateObserved -and
                ($null -ne $event.RateLimits.FiveHour -or $null -ne $event.RateLimits.Weekly)) {
                $latestRateLimits = $event.RateLimits
                $latestRateObserved = $event.RateLimits.ObservedAt
            }
            if ($null -ne $ancestorTask -and [Int64]$event.Total.Input -le [Int64]$ancestorTask.Input -and
                [Int64]$event.Total.Output -le [Int64]$ancestorTask.Output) {
                $inheritedEventCount++
                continue
            }
            $eventKey = ([string]$change.RootId) + '|' + ([string]$event.Fingerprint)
            if (-not $seenEvents.Add($eventKey)) {
                $duplicateEventCount++
                continue
            }
            $call = $event.Call
            if ([Int64]$call.Input -le 0 -and [Int64]$call.Output -le 0) { continue }
            $countedEventCount++
            $aggregateInput += [Int64]$call.Input
            $cached += [Int64]$call.Cached
            $output += [Int64]$call.Output
            $reasoning += [Int64]$call.ReasoningOutput

            $model = if (-not [string]::IsNullOrWhiteSpace([string]$event.Model)) { [string]$event.Model } else { $fallbackModel }
            if (-not [string]::IsNullOrWhiteSpace($model)) { [void]$models.Add($model) }
            $price = Resolve-TokenRaderPrice -Model $model -PricingDocument $PricingDocument
            $longContext = $false
            if ($null -ne $price -and $null -ne $price.PSObject.Properties['longContextThreshold']) {
                $longContext = ([Int64]$price.longContextThreshold -gt 0 -and [Int64]$call.Input -gt [Int64]$price.longContextThreshold)
            }
            $bucketKey = $model.ToLowerInvariant() + '|' + $(if ($longContext) { 'long' } else { 'standard' })
            if (-not $costBuckets.ContainsKey($bucketKey)) {
                $costBuckets[$bucketKey] = [pscustomobject]@{
                    Model = $model
                    LongContext = $longContext
                    Input = [Int64]0
                    Cached = [Int64]0
                    Output = [Int64]0
                    Reasoning = [Int64]0
                    Events = [Int64]0
                }
            }
            $bucket = $costBuckets[$bucketKey]
            $bucket.Input += [Int64]$call.Input
            $bucket.Cached += [Int64]$call.Cached
            $bucket.Output += [Int64]$call.Output
            $bucket.Reasoning += [Int64]$call.ReasoningOutput
            $bucket.Events++
        }
    }

    $items = New-Object System.Collections.ArrayList
    foreach ($bucket in @($costBuckets.Values)) {
        $bucketUsage = New-TokenRaderUsage -InputTokens $bucket.Input -CachedTokens $bucket.Cached -OutputTokens $bucket.Output -ReasoningOutputTokens $bucket.Reasoning
        $cost = Get-TokenRaderCost -Usage $bucketUsage -Model ([string]$bucket.Model) -PricingDocument $PricingDocument -Scope task
        if ($cost.Known) {
            $bucketInputCost = [double]$cost.InputCost
            $bucketCachedCost = [double]$cost.CachedCost
            $bucketOutputCost = [double]$cost.OutputCost
            if ([bool]$bucket.LongContext) {
                $price = $cost.Price
                $inputMultiplier = if ($null -ne $price.PSObject.Properties['longContextInputMultiplier']) { [double]$price.longContextInputMultiplier } else { 2.0 }
                $outputMultiplier = if ($null -ne $price.PSObject.Properties['longContextOutputMultiplier']) { [double]$price.longContextOutputMultiplier } else { 1.5 }
                $bucketInputCost *= $inputMultiplier
                $bucketCachedCost *= $inputMultiplier
                $bucketOutputCost *= $outputMultiplier
            }
            $inputCost += $bucketInputCost
            $cachedCost += $bucketCachedCost
            $outputCost += $bucketOutputCost
        } else {
            $unknownLabel = if ([string]::IsNullOrWhiteSpace([string]$bucket.Model)) { '未知模型' } else { [string]$bucket.Model }
            [void]$unknownModels.Add($unknownLabel)
        }
        [void]$items.Add([pscustomobject]@{
            Model = [string]$bucket.Model
            LongContext = [bool]$bucket.LongContext
            Usage = $bucketUsage
            Cost = $cost
            Events = [Int64]$bucket.Events
        })
    }

    $usage = New-TokenRaderUsage -InputTokens $aggregateInput -CachedTokens $cached -OutputTokens $output -ReasoningOutputTokens $reasoning
    $modelList = @($models | Sort-Object)
    $modelDisplay = if ($modelList.Count -eq 0) { '等待模型调用' }
                    elseif ($modelList.Count -eq 1) { $modelList[0] }
                    else { ('{0} 个模型' -f $modelList.Count) }

    [pscustomobject]@{
        StartedAt = $Baseline.StartedAt
        EndedAt = [DateTimeOffset]::Now
        Usage = $usage
        Models = $modelList
        ModelDisplay = $modelDisplay
        ChangedSessions = $activeFiles.Count
        Items = @($items)
        InputCost = $inputCost
        CachedCost = $cachedCost
        OutputCost = $outputCost
        TotalCost = $inputCost + $cachedCost + $outputCost
        CostComplete = ($unknownModels.Count -eq 0)
        UnknownModels = @($unknownModels | Sort-Object)
        RateLimits = $latestRateLimits
        RawEvents = $rawEventCount
        CountedEvents = $countedEventCount
        DuplicateEventsDropped = $duplicateEventCount
        InheritedEventsDropped = $inheritedEventCount
        BytesRead = $bytesRead
    }
}

function Get-TokenRaderProjectResult {
    param(
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [Parameter(Mandatory = $true)]$PricingDocument
    )

    $filePaths = @($Project.FilePaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($filePaths.Count -eq 0) { return $null }
    $baseline = [pscustomobject]@{
        StartedAt = [DateTimeOffset]::MinValue
        SessionsRoot = $SessionsRoot
        Files = @()
        RateLimits = $null
    }
    $result = Get-TokenRaderIntervalResult -Baseline $baseline -PricingDocument $PricingDocument -IncludedFiles $filePaths
    $result | Add-Member -NotePropertyName ProjectPath -NotePropertyValue ([string]$Project.ProjectPath)
    $result | Add-Member -NotePropertyName ProjectName -NotePropertyValue ([string]$Project.ProjectName)
    $result | Add-Member -NotePropertyName ProjectSessionCount -NotePropertyValue $filePaths.Count
    return $result
}

function Get-TokenRaderQuotaEstimate {
    param(
        $StartRateLimits,
        $EndRateLimits,
        [double]$IntervalCost,
        [bool]$CostComplete = $true
    )

    function Get-WindowEstimate {
        param($StartWindow, $EndWindow)
        if (-not $CostComplete -or $IntervalCost -le 0 -or $null -eq $StartWindow -or $null -eq $EndWindow) { return $null }
        if ($null -ne $StartWindow.ResetsAt -and $null -ne $EndWindow.ResetsAt -and $StartWindow.ResetsAt -ne $EndWindow.ResetsAt) { return $null }
        $deltaPercent = [double]$EndWindow.UsedPercent - [double]$StartWindow.UsedPercent
        if ($deltaPercent -le 0) { return $null }
        $totalUsd = $IntervalCost / ($deltaPercent / 100.0)
        [pscustomobject]@{
            DeltaPercent = $deltaPercent
            TotalUsd = $totalUsd
            UsedUsd = $totalUsd * ([double]$EndWindow.UsedPercent / 100.0)
            RemainingUsd = $totalUsd * ([double]$EndWindow.RemainingPercent / 100.0)
        }
    }

    [pscustomobject]@{
        FiveHour = if ($null -ne $StartRateLimits -and $null -ne $EndRateLimits) { Get-WindowEstimate $StartRateLimits.FiveHour $EndRateLimits.FiveHour } else { $null }
        Weekly = if ($null -ne $StartRateLimits -and $null -ne $EndRateLimits) { Get-WindowEstimate $StartRateLimits.Weekly $EndRateLimits.Weekly } else { $null }
    }
}

function Format-TokenRaderNumber {
    param([Int64]$Value)
    return $Value.ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
}

function Format-TokenRaderUsd {
    param([double]$Value)
    if ($Value -lt 0.0001) { return ('$' + $Value.ToString('0.000000')) }
    if ($Value -lt 1.0) { return ('$' + $Value.ToString('0.0000')) }
    return ('$' + $Value.ToString('N4'))
}

Export-ModuleMember -Function Get-TokenRaderPaths, Get-TokenRaderAccount, Get-TokenRaderSessionFiles, Get-TokenRaderSessionMetadata, Get-TokenRaderProjects, Get-TokenRaderUsageSnapshot, Get-TokenRaderLatestRateLimits, Get-TokenRaderPrices, Resolve-TokenRaderPrice, Get-TokenRaderCost, New-TokenRaderMeasurementBaseline, Get-TokenRaderIntervalResult, Get-TokenRaderProjectResult, Get-TokenRaderQuotaEstimate, Format-TokenRaderNumber, Format-TokenRaderUsd
