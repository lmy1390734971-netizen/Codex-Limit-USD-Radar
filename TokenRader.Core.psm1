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

    $reasoning = if ($null -ne $RawUsage.PSObject.Properties['reasoning_output_tokens']) { ConvertTo-TokenRaderSafeInt64 $RawUsage.reasoning_output_tokens } else { 0L }
    # Codex has used several names for the cache-read portion over time.  The
    # canonical cached_input_tokens field wins, then the equivalent
    # cache_read_tokens/cached_tokens aliases.  Missing cache fields mean zero,
    # not a malformed usage record.
    $cachedRaw = $null
    foreach ($name in @('cached_input_tokens', 'cache_read_tokens', 'cached_tokens')) {
        if ($null -ne $RawUsage.PSObject.Properties[$name]) {
            $cachedRaw = $RawUsage.PSObject.Properties[$name].Value
            break
        }
    }
    New-TokenRaderUsage `
        -InputTokens (ConvertTo-TokenRaderSafeInt64 $RawUsage.input_tokens) `
        -CachedTokens $(if ($null -eq $cachedRaw) { 0L } else { ConvertTo-TokenRaderSafeInt64 $cachedRaw }) `
        -OutputTokens (ConvertTo-TokenRaderSafeInt64 $RawUsage.output_tokens) `
        -ReasoningOutputTokens $reasoning
}

# JSON produced by different Codex builds may encode numeric metadata as a
# number, a numeric string, null, or an unexpected value.  Metadata must never
# abort an otherwise valid token record, so keep conversion tolerant and
# return the caller-provided default when the value is not a finite Int64.
function ConvertTo-TokenRaderSafeInt64 {
    param(
        $Value,
        [Int64]$Default = 0
    )
    if ($null -eq $Value -or $Value -is [DBNull]) { return $Default }
    try {
        if ($Value -is [string]) {
            $text = $Value.Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
            [Int64]$parsed = 0
            if ([Int64]::TryParse($text, [Globalization.NumberStyles]::Integer,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                return $parsed
            }
            return $Default
        }
        return [Convert]::ToInt64($Value, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $Default
    }
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

function ConvertFrom-TokenRaderUsageTextFast {
    param([Parameter(Mandatory = $true)][string]$InnerText)

    # Builds the same usage object as New-TokenRaderUsage without the
    # function-call and [Math]::* overhead. Regex-extracted values are already
    # non-negative, so the original clamping rules reduce to a single check.
    $inputMatch = [regex]::Match($InnerText, '"input_tokens"\s*:\s*"?(\d+)"?')
    $cachedMatch = [regex]::Match($InnerText, '"(?:cached_input_tokens|cache_read_tokens|cached_tokens)"\s*:\s*"?(\d+)"?')
    $outputMatch = [regex]::Match($InnerText, '"output_tokens"\s*:\s*"?(\d+)"?')
    if (-not $inputMatch.Success -or -not $outputMatch.Success) { return $null }
    $reasoningMatch = [regex]::Match($InnerText, '"reasoning_output_tokens"\s*:\s*"?(\d+)"?')

    $inputTokens = [Int64]$inputMatch.Groups[1].Value
    $cachedTokens = if ($cachedMatch.Success) { [Int64]$cachedMatch.Groups[1].Value } else { 0L }
    $outputTokens = [Int64]$outputMatch.Groups[1].Value
    $reasoningTokens = if ($reasoningMatch.Success) { [Int64]$reasoningMatch.Groups[1].Value } else { 0 }
    if ($cachedTokens -gt $inputTokens) { $cachedTokens = $inputTokens }
    $uncachedTokens = $inputTokens - $cachedTokens
    $totalTokens = $inputTokens + $outputTokens
    $hitRate = if ($inputTokens -gt 0) { ($cachedTokens * 100.0) / $inputTokens } else { 0.0 }

    [pscustomobject]@{
        Input = $inputTokens
        Cached = $cachedTokens
        Uncached = $uncachedTokens
        Output = $outputTokens
        ReasoningOutput = $reasoningTokens
        Total = $totalTokens
        CacheHitRate = [double]$hitRate
    }
}

function ConvertTo-TokenRaderResetTime {
    param(
        $Value,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
        [bool]$RelativeSeconds = $false
    )

    if ($null -eq $Value) { return $null }
    if ($RelativeSeconds) {
        try { return $ObservedAt.AddSeconds([double]$Value).ToLocalTime() } catch { return $null }
    }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToLocalTime() }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToLocalTime() }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $number = [Int64]0
    if ([Int64]::TryParse($text, [ref]$number)) {
        try {
            if ([Math]::Abs([double]$number) -ge 100000000000.0) {
                return [DateTimeOffset]::FromUnixTimeMilliseconds($number).ToLocalTime()
            }
            return [DateTimeOffset]::FromUnixTimeSeconds($number).ToLocalTime()
        } catch { return $null }
    }
    try { return [DateTimeOffset]::Parse($text).ToLocalTime() } catch { return $null }
}

function Get-TokenRaderResetIdentity {
    param(
        [int]$WindowMinutes,
        $ResetsAt
    )

    if ($null -eq $ResetsAt) { return '' }
    try {
        $utcMinute = [Math]::Floor(([DateTimeOffset]$ResetsAt).ToUniversalTime().ToUnixTimeSeconds() / 60.0)
        return ('{0}|{1}' -f $WindowMinutes, [Int64]$utcMinute)
    } catch { return '' }
}

function Get-TokenRaderRateWindowKind {
    param([int]$WindowMinutes)

    if ($WindowMinutes -ge 240 -and $WindowMinutes -le 360) { return 'FiveHour' }
    if ($WindowMinutes -ge 9000 -and $WindowMinutes -le 11520) { return 'Weekly' }
    return ''
}

function New-TokenRaderEventFingerprint {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$Timestamp,
        [string]$Model,
        [Parameter(Mandatory = $true)]$TotalUsage,
        [Parameter(Mandatory = $true)]$CallUsage
    )

    @(
        $Timestamp.ToUniversalTime().Ticks,
        ([string]$Model).ToLowerInvariant(),
        $TotalUsage.Input, $TotalUsage.Cached, $TotalUsage.Output, $TotalUsage.ReasoningOutput,
        $CallUsage.Input, $CallUsage.Cached, $CallUsage.Output, $CallUsage.ReasoningOutput
    ) -join ':'
}

function New-TokenRaderUsageFingerprint {
    param(
        [Parameter(Mandatory = $true)]$TotalUsage,
        [Parameter(Mandatory = $true)]$CallUsage
    )

    @(
        $TotalUsage.Input, $TotalUsage.Cached, $TotalUsage.Output, $TotalUsage.ReasoningOutput,
        $CallUsage.Input, $CallUsage.Cached, $CallUsage.Output, $CallUsage.ReasoningOutput
    ) -join ':'
}

function New-TokenRaderCumulativeFingerprint {
    param([Parameter(Mandatory = $true)]$TotalUsage)

    @(
        $TotalUsage.Input, $TotalUsage.Cached, $TotalUsage.Output, $TotalUsage.ReasoningOutput
    ) -join ':'
}

function ConvertFrom-TokenRaderRateWindowTextFast {
    param(
        [Parameter(Mandatory = $true)][string]$InnerText,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
        [string]$SourceFile = '',
        [string]$PlanType = ''
    )

    if ([string]::IsNullOrWhiteSpace($InnerText)) { return $null }
    $used = [regex]::Match($InnerText, '"used_percent"\s*:\s*"?([0-9.]+)"?')
    $minutes = [regex]::Match($InnerText, '"window_minutes"\s*:\s*"?(\d+)"?')
    if (-not $used.Success -or -not $minutes.Success) { return $null }
    $usedPercent = [Math]::Max(0.0, [Math]::Min(100.0, [double]$used.Groups[1].Value))
    $windowMinutes = [int]$minutes.Groups[1].Value
    $resetsAt = $null
    $resetMatch = [regex]::Match($InnerText, '"(?:resets_at|reset_at)"\s*:\s*(?:"([^"]+)"|([-0-9.]+))')
    if ($resetMatch.Success) {
        $resetValue = if ($resetMatch.Groups[1].Success) { $resetMatch.Groups[1].Value } else { $resetMatch.Groups[2].Value }
        $resetsAt = ConvertTo-TokenRaderResetTime -Value $resetValue -ObservedAt $ObservedAt
    } else {
        $relativeMatch = [regex]::Match($InnerText, '"resets_in_seconds"\s*:\s*"?([-0-9.]+)"?')
        if ($relativeMatch.Success) {
            $resetsAt = ConvertTo-TokenRaderResetTime -Value $relativeMatch.Groups[1].Value -ObservedAt $ObservedAt -RelativeSeconds $true
        }
    }
    $usedTokensMatch = [regex]::Match($InnerText, '"used_tokens"\s*:\s*"?(\d+)"?')
    $remainingTokensMatch = [regex]::Match($InnerText, '"remaining_tokens"\s*:\s*"?(\d+)"?')
    $limitTokensMatch = [regex]::Match($InnerText, '"limit_tokens"\s*:\s*"?(\d+)"?')
    [pscustomobject]@{
        UsedPercent = $usedPercent
        RemainingPercent = 100.0 - $usedPercent
        WindowMinutes = $windowMinutes
        ResetsAt = $resetsAt
        ResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes $windowMinutes -ResetsAt $resetsAt
        ObservedAt = $ObservedAt
        SourceFile = $SourceFile
        PlanType = $PlanType
        UsedTokens = if ($usedTokensMatch.Success) { ConvertTo-TokenRaderSafeInt64 $usedTokensMatch.Groups[1].Value } else { $null }
        RemainingTokens = if ($remainingTokensMatch.Success) { ConvertTo-TokenRaderSafeInt64 $remainingTokensMatch.Groups[1].Value } else { $null }
        LimitTokens = if ($limitTokensMatch.Success) { ConvertTo-TokenRaderSafeInt64 $limitTokensMatch.Groups[1].Value } else { $null }
    }
}

function ConvertFrom-TokenRaderTokenLineFast {
    param(
        [Parameter(Mandatory = $true)][string]$LineText,
        [string]$Model,
        [string]$SourceFile = ''
    )

    # Fast path: extract the fields this program needs from a well-formed
    # token_count line without a full JSON parse (ConvertFrom-Json is slow on
    # Windows PowerShell 5.1). Any structural mismatch falls back to the full
    # JSON parser so behaviour is always identical to the original logic.
    $structure = [regex]::Match($LineText, '^\{\s*"timestamp"\s*:\s*"([^"]+)"\s*,\s*"type"\s*:\s*"(?:event_msg|token_count)"\s*,\s*"payload"\s*:\s*\{\s*"type"\s*:\s*"token_count"\s*,\s*"info"\s*:\s*\{')
    if (-not $structure.Success) { return $null }

    $totalMatch = [regex]::Match($LineText, '"total_token_usage"\s*:\s*\{([^{}]*)\}')
    $lastMatch = [regex]::Match($LineText, '"last_token_usage"\s*:\s*\{([^{}]*)\}')
    if (-not $totalMatch.Success -or -not $lastMatch.Success) { return $null }

    $totalUsage = ConvertFrom-TokenRaderUsageTextFast -InnerText $totalMatch.Groups[1].Value
    $callUsage = ConvertFrom-TokenRaderUsageTextFast -InnerText $lastMatch.Groups[1].Value
    if ($null -eq $totalUsage -or $null -eq $callUsage) { return $null }
    $contextMatch = [regex]::Match($LineText, '"model_context_window"\s*:\s*"?(\d+)"?')
    $cacheCreationMatch = [regex]::Match($lastMatch.Groups[1].Value, '"(?:cache_creation_tokens|cache_write_tokens)"\s*:\s*"?(\d+)"?')

    $timestamp = [DateTimeOffset]::Now
    try { $timestamp = [DateTimeOffset]::Parse($structure.Groups[1].Value).ToLocalTime() } catch { }

    # Events without a rate_limits block carry no rate-limit snapshot; the
    # interval aggregation treats that exactly like a snapshot with empty
    # windows, so a plain $null is equivalent and much cheaper.
    $rateLimits = $null
    if ($LineText.Contains('rate_limits')) {
        $planMatch = [regex]::Match($LineText, '"plan_type"\s*:\s*"([^"]*)"')
        $planType = if ($planMatch.Success) { $planMatch.Groups[1].Value } else { '' }
        $primaryMatch = [regex]::Match($LineText, '"primary"\s*:\s*\{([^{}]*)\}')
        $secondaryMatch = [regex]::Match($LineText, '"secondary"\s*:\s*\{([^{}]*)\}')
        $primaryWindow = if ($primaryMatch.Success) { ConvertFrom-TokenRaderRateWindowTextFast -InnerText $primaryMatch.Groups[1].Value -ObservedAt $timestamp -SourceFile $SourceFile -PlanType $planType } else { $null }
        $secondaryWindow = if ($secondaryMatch.Success) { ConvertFrom-TokenRaderRateWindowTextFast -InnerText $secondaryMatch.Groups[1].Value -ObservedAt $timestamp -SourceFile $SourceFile -PlanType $planType } else { $null }
        if (($primaryMatch.Success -and $null -eq $primaryWindow) -or ($secondaryMatch.Success -and $null -eq $secondaryWindow)) { return $null }

        # Inline equivalent of ConvertTo-TokenRaderRateLimits over the two
        # windows in the original primary-then-secondary order.
        $fiveHour = $null
        $weekly = $null
        if ($null -ne $primaryWindow) {
            $kind = Get-TokenRaderRateWindowKind -WindowMinutes $primaryWindow.WindowMinutes
            if ($kind -eq 'FiveHour') { $fiveHour = $primaryWindow }
            elseif ($kind -eq 'Weekly') { $weekly = $primaryWindow }
        }
        if ($null -ne $secondaryWindow) {
            $kind = Get-TokenRaderRateWindowKind -WindowMinutes $secondaryWindow.WindowMinutes
            if ($kind -eq 'FiveHour') { $fiveHour = $secondaryWindow }
            elseif ($kind -eq 'Weekly') { $weekly = $secondaryWindow }
        }
        $rateLimits = [pscustomobject]@{
            ObservedAt = $timestamp
            PlanType = $planType
            FiveHour = $fiveHour
            Weekly = $weekly
        }
    }

    $fingerprint = New-TokenRaderEventFingerprint -Timestamp $timestamp -Model $Model -TotalUsage $totalUsage -CallUsage $callUsage
    $usageFingerprint = New-TokenRaderUsageFingerprint -TotalUsage $totalUsage -CallUsage $callUsage
    return [pscustomobject]@{
        Timestamp = $timestamp
        Model = $Model
        Total = $totalUsage
        Call = $callUsage
        Fingerprint = $fingerprint
        UsageFingerprint = $usageFingerprint
        RateLimits = $rateLimits
        ModelContextWindow = if ($contextMatch.Success) { ConvertTo-TokenRaderSafeInt64 $contextMatch.Groups[1].Value } else { 0L }
        CacheCreationTokens = if ($cacheCreationMatch.Success) { ConvertTo-TokenRaderSafeInt64 $cacheCreationMatch.Groups[1].Value } else { 0L }
        CacheWriteObservable = $cacheCreationMatch.Success
    }
}

function Add-TokenRaderLineEvent {
    param(
        [Parameter(Mandatory = $true)][string]$LineText,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Events
    )

    if ([string]::IsNullOrWhiteSpace($LineText)) { return }
    $trimmed = $LineText.TrimStart([char]0xFEFF)
    $hasTurnContext = $trimmed.Contains('turn_context')
    $hasTokenCount = $trimmed.Contains('token_count')
    if (-not $hasTurnContext -and -not $hasTokenCount) { return }

    # Fast paths only apply to complete JSON object lines; anything else falls
    # back to the original full JSON parsing below.
    $completeObject = $trimmed.EndsWith('}')

    if ($hasTurnContext -and $completeObject) {
        $turnMatch = [regex]::Match($trimmed, '^\{\s*"timestamp"\s*:\s*"[^"]*"\s*,\s*"type"\s*:\s*"turn_context"\s*,\s*"payload"\s*:\s*\{[^{}]*"model"\s*:\s*"([^"]+)"[^{}]*\}\s*\}$')
        if ($turnMatch.Success) {
            $State.Model = $turnMatch.Groups[1].Value
            return
        }
    }

    if ($hasTokenCount -and $completeObject) {
        $event = ConvertFrom-TokenRaderTokenLineFast -LineText $trimmed -Model ([string]$State.Model) -SourceFile ([string]$State.SourceFile)
        if ($null -ne $event) {
            [void]$Events.Add($event)
            return
        }
    }

    # Fallback: full JSON parsing with the original dispatch rules.
    try {
        $record = $trimmed | ConvertFrom-Json
    } catch { return }

    if ($record.type -eq 'turn_context') {
        if ($null -ne $record.payload -and $null -ne $record.payload.PSObject.Properties['model']) {
            $candidate = [string]$record.payload.model
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { $State.Model = $candidate }
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
    $rateLimits = ConvertTo-TokenRaderRateLimits -RawRateLimits $(if ($null -ne $record.payload.PSObject.Properties['rate_limits']) { $record.payload.rate_limits } else { $null }) -ObservedAt $timestamp -SourceFile ([string]$State.SourceFile)
    $contextWindow = if ($null -ne $info.PSObject.Properties['model_context_window']) { ConvertTo-TokenRaderSafeInt64 $info.model_context_window } else { 0L }
    $cacheCreationTokens = if ($null -ne $info.last_token_usage.PSObject.Properties['cache_creation_tokens']) { ConvertTo-TokenRaderSafeInt64 $info.last_token_usage.cache_creation_tokens } elseif ($null -ne $info.last_token_usage.PSObject.Properties['cache_write_tokens']) { ConvertTo-TokenRaderSafeInt64 $info.last_token_usage.cache_write_tokens } else { 0L }
    $cacheWriteObservable = $null -ne $info.last_token_usage.PSObject.Properties['cache_creation_tokens'] -or $null -ne $info.last_token_usage.PSObject.Properties['cache_write_tokens']
    $fingerprint = New-TokenRaderEventFingerprint -Timestamp $timestamp -Model ([string]$State.Model) -TotalUsage $totalUsage -CallUsage $callUsage
    $usageFingerprint = New-TokenRaderUsageFingerprint -TotalUsage $totalUsage -CallUsage $callUsage
    [void]$Events.Add([pscustomobject]@{
        Timestamp = $timestamp
        Model = [string]$State.Model
        Total = $totalUsage
        Call = $callUsage
        Fingerprint = $fingerprint
        UsageFingerprint = $usageFingerprint
        RateLimits = $rateLimits
        ModelContextWindow = $contextWindow
        CacheCreationTokens = $cacheCreationTokens
        CacheWriteObservable = $cacheWriteObservable
    })
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
    $state = [pscustomobject]@{ Model = $InitialModel; SourceFile = $FilePath }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return [pscustomobject]@{ Events = @(); LastModel = $InitialModel; BytesRead = 0 }
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
                    Add-TokenRaderLineEvent -LineText $lineText -State $state -Events $events
                }
                $lineBuffer.SetLength(0)
                $discardLine = $false
                $position = $newLine + 1
            }
        }
        if (-not $discardLine -and $lineBuffer.Length -gt 0) {
            $lineText = [Text.Encoding]::UTF8.GetString($lineBuffer.ToArray()).TrimEnd("`r")
            Add-TokenRaderLineEvent -LineText $lineText -State $state -Events $events
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
    param(
        [Parameter(Mandatory = $true)]$RawWindow,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
        [string]$SourceFile = '',
        [string]$PlanType = ''
    )

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
        $resetsAt = ConvertTo-TokenRaderResetTime -Value $resetValue -ObservedAt $ObservedAt
    } elseif ($null -ne $RawWindow.PSObject.Properties['resets_in_seconds'] -and $null -ne $RawWindow.resets_in_seconds) {
        $resetsAt = ConvertTo-TokenRaderResetTime -Value $RawWindow.resets_in_seconds -ObservedAt $ObservedAt -RelativeSeconds $true
    }

    [pscustomobject]@{
        UsedPercent = $usedPercent
        RemainingPercent = 100.0 - $usedPercent
        WindowMinutes = $windowMinutes
        ResetsAt = $resetsAt
        ResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes $windowMinutes -ResetsAt $resetsAt
        ObservedAt = $ObservedAt
        SourceFile = $SourceFile
        PlanType = $PlanType
        UsedTokens = if ($null -ne $RawWindow.PSObject.Properties['used_tokens']) { [Int64]$RawWindow.used_tokens } else { $null }
        RemainingTokens = if ($null -ne $RawWindow.PSObject.Properties['remaining_tokens']) { [Int64]$RawWindow.remaining_tokens } else { $null }
        LimitTokens = if ($null -ne $RawWindow.PSObject.Properties['limit_tokens']) { [Int64]$RawWindow.limit_tokens } else { $null }
    }
}

function ConvertTo-TokenRaderRateLimits {
    param(
        $RawRateLimits,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
        [string]$SourceFile = ''
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
            $window = ConvertTo-TokenRaderRateWindow -RawWindow $rawWindow -ObservedAt $ObservedAt -SourceFile $SourceFile -PlanType $planType
            $kind = Get-TokenRaderRateWindowKind -WindowMinutes $window.WindowMinutes
            if ($kind -eq 'FiveHour') { $fiveHour = $window }
            elseif ($kind -eq 'Weekly') { $weekly = $window }
        }
    }

    [pscustomobject]@{
        ObservedAt = $ObservedAt
        PlanType = $planType
        LimitId = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['limit_id']) { [string]$RawRateLimits.limit_id } else { '' }
        LimitName = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['limit_name']) { [string]$RawRateLimits.limit_name } else { '' }
        IndividualLimit = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['individual_limit']) { [bool]$RawRateLimits.individual_limit } else { $null }
        RateLimitReachedType = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['rate_limit_reached_type']) { [string]$RawRateLimits.rate_limit_reached_type } else { '' }
        SpendControlReached = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['spend_control_reached']) { [bool]$RawRateLimits.spend_control_reached } else { $null }
        CreditsBalance = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['credits'] -and $null -ne $RawRateLimits.credits -and $null -ne $RawRateLimits.credits.PSObject.Properties['balance']) { [double]$RawRateLimits.credits.balance } else { $null }
        CreditsHas = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['credits'] -and $null -ne $RawRateLimits.credits -and $null -ne $RawRateLimits.credits.PSObject.Properties['has_credits']) { [bool]$RawRateLimits.credits.has_credits } else { $null }
        CreditsUnlimited = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['credits'] -and $null -ne $RawRateLimits.credits -and $null -ne $RawRateLimits.credits.PSObject.Properties['unlimited']) { [bool]$RawRateLimits.credits.unlimited } else { $null }
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
    $latestRateLimits = $null
    $latestRateLimitsFallback = $null

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
                if ($null -ne $latestRateLimits) { break }
            }
            continue
        }

        $isTokenRecord = ($record.type -eq 'event_msg' -and $record.payload.type -eq 'token_count') -or
                         ($record.type -eq 'token_count')
        if (-not $isTokenRecord -or $null -eq $record.payload) { continue }

        $recordTimestamp = [DateTimeOffset]::Now
        try { $recordTimestamp = [DateTimeOffset]::Parse([string]$record.timestamp).ToLocalTime() } catch { }
        if ($null -eq $latestRateLimits -and $null -ne $record.payload.PSObject.Properties['rate_limits']) {
            $candidateLimits = ConvertTo-TokenRaderRateLimits -RawRateLimits $record.payload.rate_limits -ObservedAt $recordTimestamp -SourceFile $FilePath
            if ($null -eq $latestRateLimitsFallback) { $latestRateLimitsFallback = $candidateLimits }
            if ($null -ne $candidateLimits.FiveHour -or $null -ne $candidateLimits.Weekly) {
                $latestRateLimits = $candidateLimits
            }
        }
        if ($null -eq $tokenRecord -and $null -ne $record.payload.info -and
            $null -ne $record.payload.info.total_token_usage -and $null -ne $record.payload.info.last_token_usage) {
            $tokenRecord = $record
            $tokenIndex = $i
        }
        if ($null -ne $tokenRecord -and -not [string]::IsNullOrWhiteSpace($model) -and $null -ne $latestRateLimits) {
            break
        }
    }

    if ($null -eq $tokenRecord) { return $null }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = $fallbackModel }

    $payload = $tokenRecord.payload
    $info = $payload.info
    if ($null -eq $info -or $null -eq $info.total_token_usage -or $null -eq $info.last_token_usage) { return $null }

    $timestamp = $null
    try { $timestamp = [DateTimeOffset]::Parse([string]$tokenRecord.timestamp).ToLocalTime() } catch { $timestamp = [DateTimeOffset]::Now }
    $snapshotRateLimits = if ($null -ne $latestRateLimits) { $latestRateLimits } else { $latestRateLimitsFallback }
    $planType = if ($null -ne $snapshotRateLimits) { [string]$snapshotRateLimits.PlanType } else { '' }
    # Older or synthetic token_count records may omit the model context
    # window. Keep that metadata explicitly unknown instead of dereferencing
    # an uninitialised variable under StrictMode.
    [Int64]$contextWindow = 0L
    if ($null -ne $info.PSObject.Properties['model_context_window']) {
        $contextWindow = ConvertTo-TokenRaderSafeInt64 $info.model_context_window
    }
    $cacheCreationTokens = 0L
    $cacheWriteObservable = $false
    foreach ($name in @('cache_creation_tokens', 'cache_write_tokens')) {
        if ($null -ne $info.last_token_usage.PSObject.Properties[$name]) {
            $cacheCreationTokens = [Math]::Max(0L, (ConvertTo-TokenRaderSafeInt64 $info.last_token_usage.PSObject.Properties[$name].Value))
            $cacheWriteObservable = $true
            break
        }
    }

    [pscustomobject]@{
        FilePath = $FilePath
        Timestamp = $timestamp
        Model = $model
        PlanType = $planType
        RateLimits = $snapshotRateLimits
        Task = ConvertTo-TokenRaderUsage $info.total_token_usage
        Call = ConvertTo-TokenRaderUsage $info.last_token_usage
        ContextWindow = $contextWindow
        ModelContextWindow = $contextWindow
        CacheCreationTokens = $cacheCreationTokens
        CacheWriteObservable = $cacheWriteObservable
        TailLinesRead = $lines.Count
        TokenRecordIndex = $tokenIndex
    }
}

function Get-TokenRaderLatestRateLimits {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [int]$MaximumFiles = 0,
        [hashtable]$EndOffsets = $null,
        [hashtable]$SnapshotCache = $null
    )

    if (-not (Test-Path -LiteralPath $SessionsRoot)) { return $null }
    $endOffsetMap = $null
    if ($null -ne $EndOffsets) {
        $endOffsetMap = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($EndOffsets.Keys)) {
            $endOffsetMap[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$key))] = [Int64]$EndOffsets[$key]
        }
    }
    $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($MaximumFiles -gt 0 -and $files.Count -gt $MaximumFiles) {
        $files = @($files | Select-Object -First $MaximumFiles)
    }
    $fiveHour = $null
    $weekly = $null
    $fiveObserved = [DateTimeOffset]::MinValue
    $weeklyObserved = [DateTimeOffset]::MinValue
    $planType = ''

    foreach ($file in $files) {
        $canonicalPath = ConvertTo-TokenRaderCanonicalPath -Path ([string]$file.FullName)
        if ($null -ne $endOffsetMap -and -not $endOffsetMap.ContainsKey($canonicalPath)) { continue }
        $effectiveEnd = [Int64]$file.Length
        if ($null -ne $endOffsetMap) { $effectiveEnd = [Math]::Min($effectiveEnd, [Int64]$endOffsetMap[$canonicalPath]) }
        if ($effectiveEnd -le 0) { continue }

        $snapshot = $null
        if ($null -ne $SnapshotCache -and $SnapshotCache.ContainsKey($canonicalPath)) {
            $cachedEntry = $SnapshotCache[$canonicalPath]
            if ([Int64]$cachedEntry.EndOffset -eq $effectiveEnd -and
                [Int64]$cachedEntry.LastWriteTimeUtcTicks -eq [Int64]$file.LastWriteTimeUtc.Ticks) {
                $snapshot = $cachedEntry.Snapshot
            }
        }
        if ($null -eq $snapshot) {
            $snapshot = Get-TokenRaderUsageSnapshot -FilePath $canonicalPath -EndOffset $effectiveEnd
            if ($null -ne $SnapshotCache) {
                $SnapshotCache[$canonicalPath] = [pscustomobject]@{
                    EndOffset = $effectiveEnd
                    LastWriteTimeUtcTicks = [Int64]$file.LastWriteTimeUtc.Ticks
                    Snapshot = $snapshot
                }
            }
        }
        if ($null -eq $snapshot -or $null -eq $snapshot.RateLimits) { continue }
        $rateLimits = $snapshot.RateLimits
        if ($null -ne $rateLimits.FiveHour -and $rateLimits.FiveHour.ObservedAt -gt $fiveObserved) {
            $fiveHour = $rateLimits.FiveHour
            $fiveObserved = $rateLimits.FiveHour.ObservedAt
        }
        if ($null -ne $rateLimits.Weekly -and $rateLimits.Weekly.ObservedAt -gt $weeklyObserved) {
            $weekly = $rateLimits.Weekly
            $weeklyObserved = $rateLimits.Weekly.ObservedAt
        }
    }

    if ($null -eq $fiveHour -and $null -eq $weekly) { return $null }
    if ($fiveObserved -ge $weeklyObserved -and $null -ne $fiveHour) { $planType = [string]$fiveHour.PlanType }
    elseif ($null -ne $weekly) { $planType = [string]$weekly.PlanType }
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

function Resolve-TokenRaderLongContextPricing {
    param(
        [Parameter(Mandatory = $true)]$Price,
        [Parameter(Mandatory = $true)]$Usage,
        [ValidateSet('task', 'call')][string]$Scope = 'task',
        [Int64]$ModelContextWindow = 0,
        [Int64]$LongContextThreshold = 0,
        [Nullable[bool]]$LongContextApplied = $null
    )
    $threshold = if ($LongContextThreshold -gt 0) { $LongContextThreshold } elseif ($null -ne $Price.PSObject.Properties['longContextThreshold']) { [Int64]$Price.longContextThreshold } else { 0L }
    $applied = if ($null -ne $LongContextApplied) { [bool]$LongContextApplied } else {
        $Scope -eq 'call' -and $threshold -gt 0L -and [Int64]$Usage.Input -gt $threshold
    }
    [pscustomobject]@{
        Applied = $applied
        Threshold = if ($threshold -gt 0L) { $threshold } else { $null }
        ContextWindow = if ($ModelContextWindow -gt 0L) { $ModelContextWindow } else { $null }
        Source = if ($threshold -gt 0L) { 'pricing_threshold' } else { 'no_threshold' }
        InputMultiplier = if ($applied) { if ($null -ne $Price.PSObject.Properties['longContextInputMultiplier']) { [double]$Price.longContextInputMultiplier } else { 2.0 } } else { 1.0 }
        OutputMultiplier = if ($applied) { if ($null -ne $Price.PSObject.Properties['longContextOutputMultiplier']) { [double]$Price.longContextOutputMultiplier } else { 1.5 } } else { 1.0 }
    }
}

function Get-TokenRaderCost {
    param(
        [Parameter(Mandatory = $true)]$Usage,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [ValidateSet('task', 'call')][string]$Scope = 'task',
        [Int64]$ModelContextWindow = 0,
        [Int64]$LongContextThreshold = 0,
        [Nullable[bool]]$LongContextApplied = $null,
        [Int64]$CacheCreationTokens = 0,
        [Nullable[bool]]$CacheWriteObservable = $null
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
            CacheCreationCost = [double]0
            CacheWriteObservable = $false
            CostCoverage = 'observable_tokens_only'
            LongContextApplied = $false
            InputMultiplier = 1.0
            OutputMultiplier = 1.0
            ModelContextWindow = if ($ModelContextWindow -gt 0) { $ModelContextWindow } else { $null }
            LongContextThreshold = if ($LongContextThreshold -gt 0) { $LongContextThreshold } else { $null }
            LongContextSource = 'unknown_model'
        }
    }

    $longContext = Resolve-TokenRaderLongContextPricing -Price $price -Usage $Usage -Scope $Scope -ModelContextWindow $ModelContextWindow -LongContextThreshold $LongContextThreshold -LongContextApplied $LongContextApplied
    $inputMultiplier = [double]$longContext.InputMultiplier
    $outputMultiplier = [double]$longContext.OutputMultiplier

    $unitTokens = if ($null -ne $PricingDocument.PSObject.Properties['unitTokens'] -and [double]$PricingDocument.unitTokens -gt 0) {
        [double]$PricingDocument.unitTokens
    } else { 1000000.0 }
    # Cache creation/write tokens are a subset of uncached input. Price them
    # once at the official 1.25x write rate, then price only the remainder at
    # the normal input rate. This keeps task, call, interval, project and
    # history paths on the same formula.
    [Int64]$cacheCreation = [Math]::Min([Math]::Max([Int64]0, $CacheCreationTokens), [Math]::Max([Int64]0, [Int64]$Usage.Uncached))
    [Int64]$ordinaryUncached = [Math]::Max([Int64]0, [Int64]$Usage.Uncached - $cacheCreation)
    $cacheCreationCost = ([double]$cacheCreation / $unitTokens) * [double]$price.input * 1.25 * $inputMultiplier
    $inputCost = ([double]$ordinaryUncached / $unitTokens) * [double]$price.input * $inputMultiplier + $cacheCreationCost
    $cachedCost = ([double]$Usage.Cached / $unitTokens) * [double]$price.cachedInput * $inputMultiplier
    $outputCost = ([double]$Usage.Output / $unitTokens) * [double]$price.output * $outputMultiplier

    [pscustomobject]@{
        Known = $true
        Model = $Model
        Price = $price
        InputCost = $inputCost
        CachedCost = $cachedCost
        OutputCost = $outputCost
        TotalCost = $inputCost + $cachedCost + $outputCost
        CacheCreationCost = $cacheCreationCost
        CacheWriteObservable = if ($null -ne $CacheWriteObservable) { [bool]$CacheWriteObservable } else { $false }
        CostCoverage = if ($null -ne $CacheWriteObservable -and [bool]$CacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
        LongContextApplied = [bool]$longContext.Applied
        InputMultiplier = $inputMultiplier
        OutputMultiplier = $outputMultiplier
        ModelContextWindow = $longContext.ContextWindow
        LongContextThreshold = $longContext.Threshold
        LongContextSource = $longContext.Source
    }
}

function New-TokenRaderMeasurementBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [hashtable]$RateLimitSnapshotCache = $null,
        [string]$AccountIdentity = ''
    )

    $startedAt = [DateTimeOffset]::Now
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
    $startOffsets = @{}
    foreach ($entry in $files) { $startOffsets[[string]$entry.FilePath] = [Int64]$entry.Length }
    $rateLimits = Get-TokenRaderLatestRateLimits -SessionsRoot $SessionsRoot -EndOffsets $startOffsets -SnapshotCache $RateLimitSnapshotCache

    [pscustomobject]@{
        StartedAt = $startedAt
        SessionsRoot = $SessionsRoot
        Files = $files
        StartOffsets = $startOffsets
        RateLimits = $rateLimits
        StartRateLimits = $rateLimits
        AccountIdentity = $AccountIdentity
    }
}

function ConvertTo-TokenRaderSignature {
    param([string[]]$Parts)

    # Deterministic content hash over "path|length|lastWriteTicks" lines. The
    # newline separator cannot appear inside Windows file names, so the joined
    # string is unambiguous.
    $joined = @($Parts) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($joined))
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-TokenRaderSessionTreeSignature {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)

    $parts = @()
    if (Test-Path -LiteralPath $SessionsRoot) {
        $parts = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
            '{0}|{1}|{2}' -f $_.FullName, [Int64]$_.Length, $_.LastWriteTimeUtc.Ticks
        })
    }
    return ConvertTo-TokenRaderSignature -Parts $parts
}

function ConvertTo-TokenRaderCanonicalPath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    # Expands 8.3 short names (e.g. RUNNER~1 -> runneradmin) and normalizes
    # separators so path keys match regardless of which form the string came
    # from ($env:TEMP can resolve to a short form on CI runners while
    # Get-ChildItem returns the long form).
    try { return [IO.Path]::GetFullPath($Path) } catch { return $Path }
}

function Get-TokenRaderIntervalResult {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [string[]]$IncludedFiles = @(),
        [hashtable]$BaselineSnapshots = $null,
        [hashtable]$EndOffsets = $null
    )

    # Windows file paths are case-insensitive and may be expressed as 8.3 short
    # names, so every path-keyed lookup below uses canonical full paths in an
    # OrdinalIgnoreCase comparer.
    $baselineMap = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Baseline.Files)) { $baselineMap[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$entry.FilePath))] = $entry }

    $currentFiles = @()
    if (@($IncludedFiles).Count -gt 0) {
        $currentFiles = @($IncludedFiles | ForEach-Object {
            if (Test-Path -LiteralPath $_) { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue }
        })
    } elseif (Test-Path -LiteralPath ([string]$Baseline.SessionsRoot)) {
        $currentFiles = @(Get-ChildItem -LiteralPath ([string]$Baseline.SessionsRoot) -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
    }
    $fileBySessionId = @{}
    foreach ($file in $currentFiles) { $fileBySessionId[(Get-TokenRaderSessionIdFromPath -FilePath $file.FullName)] = (ConvertTo-TokenRaderCanonicalPath -Path ([string]$file.FullName)) }

    $endOffsetMap = $null
    if ($null -ne $EndOffsets) {
        $endOffsetMap = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($EndOffsets.Keys)) { $endOffsetMap[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$key))] = $EndOffsets[$key] }
    }
    if ($null -ne $BaselineSnapshots) {
        $normalizedSnapshots = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($BaselineSnapshots.Keys)) { $normalizedSnapshots[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$key))] = $BaselineSnapshots[$key] }
        $BaselineSnapshots = $normalizedSnapshots
    }

    $metadataByPath = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    $metadataBySessionId = @{}
    $loadMetadata = {
        param([string]$FilePath)
        $canonicalPath = ConvertTo-TokenRaderCanonicalPath -Path $FilePath
        if ($metadataByPath.ContainsKey($canonicalPath)) { return $metadataByPath[$canonicalPath] }
        $metadata = Get-TokenRaderSessionMetadata -FilePath $FilePath
        $metadataByPath[$canonicalPath] = $metadata
        $metadataBySessionId[[string]$metadata.SessionId] = $metadata
        if (-not $fileBySessionId.ContainsKey([string]$metadata.SessionId)) { $fileBySessionId[[string]$metadata.SessionId] = $canonicalPath }
        return $metadata
    }
    $loadBaselineSnapshot = {
        param($Entry)
        if ($null -eq $Entry) { return $null }
        $snapshotPath = ConvertTo-TokenRaderCanonicalPath -Path ([string]$Entry.FilePath)
        if ($null -ne $BaselineSnapshots -and $BaselineSnapshots.ContainsKey($snapshotPath)) {
            return $BaselineSnapshots[$snapshotPath].Task
        }
        if (-not [bool]$Entry.BaselineLoaded) {
            $snapshot = Get-TokenRaderUsageSnapshot -FilePath $snapshotPath -EndOffset ([Int64]$Entry.Length)
            $Entry.BaselineTask = if ($null -ne $snapshot) { $snapshot.Task } else { $null }
            $Entry.BaselineModel = if ($null -ne $snapshot) { [string]$snapshot.Model } else { '' }
            $Entry.BaselineLoaded = $true
            if ($null -ne $BaselineSnapshots) {
                $BaselineSnapshots[$snapshotPath] = [pscustomobject]@{
                    Task = $Entry.BaselineTask
                    Model = $Entry.BaselineModel
                }
            }
        }
        return $Entry.BaselineTask
    }
    $baselineEventFingerprintsByPath = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    $loadBaselineEventFingerprints = {
        param($Entry)
        $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        if ($null -eq $Entry) { return ,$keys }
        $ancestorPath = ConvertTo-TokenRaderCanonicalPath -Path ([string]$Entry.FilePath)
        if ($baselineEventFingerprintsByPath.ContainsKey($ancestorPath)) {
            return ,$baselineEventFingerprintsByPath[$ancestorPath]
        }
        $ancestorEvents = Get-TokenRaderUsageEvents -FilePath $ancestorPath -StartOffset 0 -EndOffset ([Int64]$Entry.Length)
        foreach ($ancestorEvent in @($ancestorEvents.Events)) {
            [void]$keys.Add([string]$ancestorEvent.UsageFingerprint)
        }
        $baselineEventFingerprintsByPath[$ancestorPath] = $keys
        return ,$keys
    }

    $changed = New-Object System.Collections.ArrayList
    foreach ($file in $currentFiles) {
        $fullPath = ConvertTo-TokenRaderCanonicalPath -Path ([string]$file.FullName)
        if ($null -ne $endOffsetMap -and -not $endOffsetMap.ContainsKey($fullPath)) { continue }
        $baselineEntry = if ($baselineMap.ContainsKey($fullPath)) { $baselineMap[$fullPath] } else { $null }
        $visibleLength = [Int64]$file.Length
        if ($null -ne $endOffsetMap -and $endOffsetMap.ContainsKey($fullPath)) {
            $visibleLength = [Math]::Min($visibleLength, [Int64]$endOffsetMap[$fullPath])
        }
        if ($null -ne $baselineEntry -and $visibleLength -eq [Int64]$baselineEntry.Length) { continue }
        $metadata = & $loadMetadata $fullPath
        [void]$changed.Add([pscustomobject]@{
            File = $file
            FullPath = $fullPath
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
    [double]$cacheCreationCost = 0
    [Int64]$standardContextEvents = 0
    [Int64]$longContextEvents = 0
    [Int64]$standardContextInput = 0
    [Int64]$longContextInput = 0
    [Int64]$longContextOutput = 0
    [double]$longContextExtraCost = 0
    $cacheWriteObservable = $true
    [Int64]$rawEventCount = 0
    [Int64]$countedEventCount = 0
    [Int64]$duplicateEventCount = 0
    [Int64]$inheritedEventCount = 0
    $firstCountedAt = $null
    $lastCountedAt = $null
    [Int64]$bytesRead = 0
    $seenEvents = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $rootHistoryEvents = @{}
    $activeFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $models = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $unknownModels = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $costBuckets = @{}
    # Price resolution is deterministic per model string; Resolve-TokenRaderPrice
    # sorts the pricing table on every call, so memoize per call.
    $priceCache = @{}
    $latestRateLimits = $null
    $latestRateObserved = [DateTimeOffset]::MinValue

    foreach ($change in @($changed | Sort-Object Depth, @{ Expression = { $_.File.CreationTimeUtc } })) {
        $changePath = [string]$change.FullPath
        $rootHistoryKey = ([string]$change.RootId).ToLowerInvariant()
        if (-not $rootHistoryEvents.ContainsKey($rootHistoryKey)) {
            $rootHistoryEvents[$rootHistoryKey] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        }
        $rootHistory = $rootHistoryEvents[$rootHistoryKey]
        $baselineTask = $null
        $initialModel = ''
        $startOffset = 0
        if ($null -ne $change.BaselineEntry) {
            $baselineTask = & $loadBaselineSnapshot $change.BaselineEntry
            $initialModel = [string]$change.BaselineEntry.BaselineModel
            $startOffset = [Int64]$change.BaselineEntry.Length
        }
        $ancestorEventFingerprints = if ($change.IsNew -and $null -ne $change.BaselineAncestor) {
            & $loadBaselineEventFingerprints $change.BaselineAncestor
        } else { $null }

        $effectiveEnd = [Int64]$change.File.Length
        if ($null -ne $endOffsetMap -and $endOffsetMap.ContainsKey($changePath)) {
            $effectiveEnd = [Math]::Min($effectiveEnd, [Int64]$endOffsetMap[$changePath])
        }

        # Every recompute re-parses the bytes written since the baseline so no
        # per-event state is retained between calls (memory stays flat during a
        # measurement). The desktop UI keeps the UI responsive by running this
        # in a background runspace and skips recomputes entirely when the
        # session-tree signature is unchanged.
        $parsed = Get-TokenRaderUsageEvents -FilePath $changePath -StartOffset $startOffset -EndOffset $effectiveEnd -InitialModel $initialModel
        $bytesRead += [Int64]$parsed.BytesRead
        if (@($parsed.Events).Count -gt 0) { [void]$activeFiles.Add($changePath) }
        $fallbackModel = [string]$parsed.LastModel
        $seenCumulativeSnapshots = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        if ($null -ne $baselineTask) {
            [void]$seenCumulativeSnapshots.Add((New-TokenRaderCumulativeFingerprint -TotalUsage $baselineTask))
        }

        foreach ($event in @($parsed.Events)) {
            $rawEventCount++
            if ($null -ne $event.RateLimits -and $event.RateLimits.ObservedAt -gt $latestRateObserved -and
                ($null -ne $event.RateLimits.FiveHour -or $null -ne $event.RateLimits.Weekly)) {
                $latestRateLimits = $event.RateLimits
                $latestRateObserved = $event.RateLimits.ObservedAt
            }
            $usageFingerprint = [string]$event.UsageFingerprint
            $cumulativeFingerprint = New-TokenRaderCumulativeFingerprint -TotalUsage $event.Total
            # Codex may emit a later token_count record only to refresh status
            # or rate limits. If total_token_usage did not change, the attached
            # last_token_usage still describes the previous call and must not
            # be charged again. Seeding from the baseline also protects the
            # first record immediately after the measurement boundary.
            if (-not $seenCumulativeSnapshots.Add($cumulativeFingerprint)) {
                $duplicateEventCount++
                continue
            }
            if ($change.IsNew -and $null -ne $ancestorEventFingerprints -and $ancestorEventFingerprints.Contains($usageFingerprint)) {
                $inheritedEventCount++
                continue
            }
            if ($change.Depth -gt 0 -and $rootHistory.Contains($usageFingerprint)) {
                $duplicateEventCount++
                continue
            }
            [void]$rootHistory.Add($usageFingerprint)
            # Fingerprints produced by the parser include timestamp/model for
            # display/debugging. Lineage identity must use token usage only so
            # a copied parent/child call remains deduplicated across model
            # attribution and serialization-time differences.
            $eventKey = ([string]$change.RootId) + '|' + $usageFingerprint
            if (-not $seenEvents.Add($eventKey)) {
                $duplicateEventCount++
                continue
            }
            $call = $event.Call
            if ([Int64]$call.Input -le 0 -and [Int64]$call.Output -le 0) { continue }
            $countedEventCount++
            if ($null -eq $firstCountedAt -or $event.Timestamp -lt $firstCountedAt) { $firstCountedAt = $event.Timestamp }
            if ($null -eq $lastCountedAt -or $event.Timestamp -gt $lastCountedAt) { $lastCountedAt = $event.Timestamp }
            $aggregateInput += [Int64]$call.Input
            $cached += [Int64]$call.Cached
            $output += [Int64]$call.Output
            $reasoning += [Int64]$call.ReasoningOutput

            $model = if (-not [string]::IsNullOrWhiteSpace([string]$event.Model)) { [string]$event.Model } else { $fallbackModel }
            if (-not [string]::IsNullOrWhiteSpace($model)) { [void]$models.Add($model) }
            if (-not $priceCache.ContainsKey($model)) {
                $priceCache[$model] = Resolve-TokenRaderPrice -Model $model -PricingDocument $PricingDocument
            }
            $price = $priceCache[$model]
            $longContext = $false
            if ($null -ne $price -and $null -ne $price.PSObject.Properties['longContextThreshold']) {
                $longContext = ([Int64]$price.longContextThreshold -gt 0 -and [Int64]$call.Input -gt [Int64]$price.longContextThreshold)
            }
            if ($null -ne $event.PSObject.Properties['CacheWriteObservable'] -and -not [bool]$event.CacheWriteObservable) { $cacheWriteObservable = $false }
            if ($longContext) {
                $longContextEvents++
                $longContextInput += [Int64]$call.Input
                $longContextOutput += [Int64]$call.Output
            } else {
                $standardContextEvents++
                $standardContextInput += [Int64]$call.Input
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
                    CacheCreationTokens = [Int64]0
                    CacheWriteObservable = $true
                    Events = [Int64]0
                }
            }
            $bucket = $costBuckets[$bucketKey]
            $bucket.Input += [Int64]$call.Input
            $bucket.Cached += [Int64]$call.Cached
            $bucket.Output += [Int64]$call.Output
            $bucket.Reasoning += [Int64]$call.ReasoningOutput
            if ($null -ne $event.PSObject.Properties['CacheCreationTokens']) {
                $bucket.CacheCreationTokens += [Int64]$event.CacheCreationTokens
            }
            if ($null -eq $event.PSObject.Properties['CacheWriteObservable'] -or
                -not [bool]$event.CacheWriteObservable) {
                $bucket.CacheWriteObservable = $false
            }
            $bucket.Events++
        }
    }

    $items = New-Object System.Collections.ArrayList
    foreach ($bucket in @($costBuckets.Values)) {
        $bucketUsage = New-TokenRaderUsage -InputTokens $bucket.Input -CachedTokens $bucket.Cached -OutputTokens $bucket.Output -ReasoningOutputTokens $bucket.Reasoning
        $cost = Get-TokenRaderCost -Usage $bucketUsage -Model ([string]$bucket.Model) -PricingDocument $PricingDocument `
            -Scope call -LongContextApplied ([bool]$bucket.LongContext) `
            -CacheCreationTokens ([Int64]$bucket.CacheCreationTokens) `
            -CacheWriteObservable ([bool]$bucket.CacheWriteObservable)
        if ($cost.Known) {
            $bucketInputCost = [double]$cost.InputCost
            $bucketCachedCost = [double]$cost.CachedCost
            $bucketOutputCost = [double]$cost.OutputCost
            $cacheCreationCost += [double]$cost.CacheCreationCost
            $inputCost += $bucketInputCost
            $cachedCost += $bucketCachedCost
            $outputCost += $bucketOutputCost
            if ([bool]$bucket.LongContext) {
                [double]$standardInputCost = if ([double]$cost.InputMultiplier -gt 0) { $bucketInputCost / [double]$cost.InputMultiplier } else { $bucketInputCost }
                [double]$standardCachedCost = if ([double]$cost.InputMultiplier -gt 0) { $bucketCachedCost / [double]$cost.InputMultiplier } else { $bucketCachedCost }
                [double]$standardOutputCost = if ([double]$cost.OutputMultiplier -gt 0) { $bucketOutputCost / [double]$cost.OutputMultiplier } else { $bucketOutputCost }
                $longContextExtraCost += ($bucketInputCost + $bucketCachedCost + $bucketOutputCost) -
                    ($standardInputCost + $standardCachedCost + $standardOutputCost)
            }
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

    $startRateLimits = if ($null -ne $Baseline.PSObject.Properties['StartRateLimits']) {
        $Baseline.StartRateLimits
    } elseif ($null -ne $Baseline.PSObject.Properties['RateLimits']) {
        $Baseline.RateLimits
    } else { $null }
    $endRateLimits = $latestRateLimits
    if ($null -ne $Baseline.PSObject.Properties['StartOffsets']) {
        $endRateLimits = Get-TokenRaderLatestRateLimits -SessionsRoot ([string]$Baseline.SessionsRoot) -EndOffsets $EndOffsets
    }
    $pricingComplete = ($unknownModels.Count -eq 0)

    $signatureParts = foreach ($file in $currentFiles) {
        '{0}|{1}|{2}' -f $file.FullName, [Int64]$file.Length, $file.LastWriteTimeUtc.Ticks
    }

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
        CacheCreationCost = $cacheCreationCost
        PricingComplete = $pricingComplete
        CostComplete = $pricingComplete
        UnknownModels = @($unknownModels | Sort-Object)
        StartRateLimits = $startRateLimits
        EndRateLimits = $endRateLimits
        RateLimits = $endRateLimits
        RawEvents = $rawEventCount
        CountedEvents = $countedEventCount
        DuplicateEventsDropped = $duplicateEventCount
        InheritedEventsDropped = $inheritedEventCount
        BytesRead = $bytesRead
        Signature = ConvertTo-TokenRaderSignature -Parts $signatureParts
        BaselineSnapshots = if ($null -ne $BaselineSnapshots) { $BaselineSnapshots } else { @{} }
        FirstCountedAt = $firstCountedAt
        LastCountedAt = $lastCountedAt
        StandardContextEvents = $standardContextEvents
        LongContextEvents = $longContextEvents
        StandardContextInput = $standardContextInput
        LongContextInput = $longContextInput
        LongContextOutput = $longContextOutput
        LongContextExtraCost = $longContextExtraCost
        CacheWriteObservable = $cacheWriteObservable
        CostCoverage = if ($cacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
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
    $index = $script:TokenRaderIndex
    if ($null -ne $index -and $null -ne $index.Connection -and
        [string]::Equals([string]$index.SessionsRoot, [string]$SessionsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $allEnds = Get-TokenRaderCursorOffsets -Connection $index.Connection
        $starts = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        $ends = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $filePaths) {
            $canonical = ConvertTo-TokenRaderCanonicalPath -Path ([string]$path)
            if (-not $allEnds.ContainsKey($canonical)) { continue }
            $starts[$canonical] = 0L
            $ends[$canonical] = [Int64]$allEnds[$canonical]
        }
        if ($ends.Count -gt 0) {
            $thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in @($PricingDocument.models)) {
                $threshold = if ($null -ne $entry.PSObject.Properties['longContextThreshold']) { [Int64]$entry.longContextThreshold } else { 0L }
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.id)) { $thresholds[[string]$entry.id] = $threshold }
                foreach ($alias in @($entry.aliases)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$alias)) { $thresholds[[string]$alias] = $threshold }
                }
            }
            $aggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
                $index.Connection, $starts, $ends, [DateTimeOffset]::MinValue,
                $thresholds, [Threading.CancellationToken]::None, $null)
            $priced = ConvertFrom-TokenRaderPricedAggregate -Aggregate $aggregate -PricingDocument $PricingDocument
            $indexedResult = [pscustomobject]@{
                StartedAt = [DateTimeOffset]::MinValue
                EndedAt = [DateTimeOffset]::Now
                Usage = $priced.Usage
                Models = @($priced.Models)
                ModelDisplay = [string]$priced.ModelDisplay
                ChangedSessions = [int]$aggregate.ChangedSessions
                Items = @($priced.Items)
                InputCost = [double]$priced.InputCost
                CachedCost = [double]$priced.CachedCost
                OutputCost = [double]$priced.OutputCost
                TotalCost = [double]$priced.TotalCost
                CacheCreationCost = [double]$priced.CacheCreationCost
                StandardContextEvents = [Int64]$priced.StandardContextEvents
                LongContextEvents = [Int64]$priced.LongContextEvents
                StandardContextInput = [Int64]$priced.StandardContextInput
                LongContextInput = [Int64]$priced.LongContextInput
                LongContextOutput = [Int64]$priced.LongContextOutput
                LongContextExtraCost = [double]$priced.LongContextExtraCost
                CacheWriteObservable = [bool]$priced.CacheWriteObservable
                CostCoverage = [string]$priced.CostCoverage
                PricingComplete = [bool]$priced.PricingComplete
                CostComplete = [bool]$priced.CostComplete
                UnknownModels = @($priced.UnknownModels)
                StartRateLimits = $null
                EndRateLimits = $null
                RateLimits = $null
                RawEvents = [Int64]$aggregate.RawEvents
                CountedEvents = [Int64]$aggregate.CountedEvents
                DuplicateEventsDropped = [Int64]$aggregate.DuplicateEventsDropped
                InheritedEventsDropped = [Int64]$aggregate.InheritedEventsDropped
                BytesRead = [Int64]$aggregate.BytesRead
                ProcessedRows = [Int64]$aggregate.ProcessedRows
                ProcessingMilliseconds = [double]$aggregate.ProcessingMilliseconds
                FirstCountedAt = $aggregate.FirstCountedAt
                LastCountedAt = $aggregate.LastCountedAt
                IdentityComplete = [bool]$aggregate.IdentityComplete
                IdentitySources = @($aggregate.IdentitySources)
                UnidentifiedEvents = [Int64]$aggregate.UnidentifiedEvents
            }
            $indexedResult | Add-Member -NotePropertyName ProjectPath -NotePropertyValue ([string]$Project.ProjectPath)
            $indexedResult | Add-Member -NotePropertyName ProjectName -NotePropertyValue ([string]$Project.ProjectName)
            $indexedResult | Add-Member -NotePropertyName ProjectSessionCount -NotePropertyValue $filePaths.Count
            return $indexedResult
        }
    }
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

function Get-TokenRaderSessionResult {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [Parameter(Mandatory = $true)]$PricingDocument
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
    $baseline = [pscustomobject]@{
        StartedAt = [DateTimeOffset]::MinValue
        SessionsRoot = $SessionsRoot
        Files = @()
        RateLimits = $null
    }
    return Get-TokenRaderIntervalResult -Baseline $baseline -PricingDocument $PricingDocument -IncludedFiles @($FilePath)
}

function Get-TokenRaderQuotaEstimate {
    param(
        $StartRateLimits,
        $EndRateLimits,
        [double]$IntervalCost,
        [bool]$CostComplete = $true,
        $StartReferenceAt = $null,
        $EndReferenceAt = $null,
        $QuotaEvidence = $null
    )
    $useQuotaEvidence = $PSBoundParameters.ContainsKey('QuotaEvidence')

    function Get-WindowPercentResolution {
        param($Window)
        if ($null -ne $Window -and $null -ne $Window.PSObject.Properties['PercentResolution']) {
            $declared = [double]$Window.PercentResolution
            if ($declared -gt 0 -and $declared -le 100) { return $declared }
        }
        if ($null -eq $Window) { return 1.0 }
        $text = ([double]$Window.UsedPercent).ToString('0.################', [Globalization.CultureInfo]::InvariantCulture)
        $separator = $text.IndexOf('.')
        if ($separator -lt 0) { return 1.0 }
        $digits = $text.Length - $separator - 1
        if ($digits -le 0) { return 1.0 }
        return [Math]::Pow(10.0, -$digits)
    }

    function Get-WindowEstimate {
        param($StartWindow, $EndWindow, [string]$StartPlanType, [string]$EndPlanType, $Evidence)
        if ($null -eq $EndWindow) { return $null }
        if ($useQuotaEvidence) {
            if ($null -eq $Evidence -or $null -eq $Evidence.PSObject.Properties['BoundaryValid'] -or
                -not [bool]$Evidence.BoundaryValid -or $null -eq $Evidence.PSObject.Properties['TotalTokens'] -or
                [Int64]$Evidence.TotalTokens -le 0 -or $null -eq $Evidence.PSObject.Properties['EstimateSource'] -or
                [string]::IsNullOrWhiteSpace([string]$Evidence.EstimateSource) -or
                $null -eq $Evidence.PSObject.Properties['PricingComplete'] -or -not [bool]$Evidence.PricingComplete -or
                $null -eq $Evidence.PSObject.Properties['EstimatedTotalUsd'] -or [double]$Evidence.EstimatedTotalUsd -le 0) { return $null }
            if ($null -eq $Evidence.PSObject.Properties['EndObservedAt'] -or
                [DateTimeOffset]$Evidence.EndObservedAt -ne [DateTimeOffset]$EndWindow.ObservedAt) { return $null }
            if ($null -ne $Evidence.LastCountedAt -and
                [DateTimeOffset]$Evidence.LastCountedAt -gt [DateTimeOffset]$EndWindow.ObservedAt) { return $null }
            return [pscustomobject]@{
                StartUsedPercent = if ($null -ne $StartWindow) { [double]$StartWindow.UsedPercent } else { [double]$EndWindow.UsedPercent }
                EndUsedPercent = [double]$EndWindow.UsedPercent
                DeltaPercent = if ($null -ne $StartWindow) { [double]$EndWindow.UsedPercent - [double]$StartWindow.UsedPercent } else { 0.0 }
                EffectiveDeltaPercent = 0.0
                PercentResolution = [double](Get-WindowPercentResolution $EndWindow)
                ResolutionAssumptionApplied = $false
                TotalTokens = [Int64]$Evidence.TotalTokens
                UsedTokens = [Int64]$Evidence.UsedTokens
                RemainingTokens = [Int64]$Evidence.RemainingTokens
                ObservedTokens = [Int64]$Evidence.ObservedTokens
                EstimateSource = [string]$Evidence.EstimateSource
                CapacitySource = [string]$Evidence.CapacitySource
                IdentityComplete = [bool]$Evidence.IdentityComplete
                IdentitySources = @($Evidence.IdentitySources)
                UnidentifiedEvents = [Int64]$Evidence.UnidentifiedEvents
                EvidenceCost = [double]$Evidence.TotalCost
                EvidenceFirstCountedAt = $Evidence.FirstCountedAt
                EvidenceLastCountedAt = $Evidence.LastCountedAt
                AverageUsdPerToken = [double]$Evidence.AverageUsdPerToken
                TotalUsd = [double]$Evidence.EstimatedTotalUsd
                UsedUsd = [double]$Evidence.ObservedCostUsd
                RemainingUsd = [double]$Evidence.EstimatedRemainingUsd
                WindowMinutes = [int]$EndWindow.WindowMinutes
                ResetsAt = $EndWindow.ResetsAt
                PlanType = $EndPlanType
            }
        }
        if ($null -eq $StartWindow) { return $null }
        [double]$effectiveCost = $IntervalCost
        [bool]$effectiveCostComplete = $CostComplete
        if (-not $effectiveCostComplete -or $effectiveCost -le 0) { return $null }
        if (-not $StartPlanType.Equals($EndPlanType, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        if ([int]$StartWindow.WindowMinutes -ne [int]$EndWindow.WindowMinutes) { return $null }
        if ($null -eq $StartWindow.ResetsAt -or $null -eq $EndWindow.ResetsAt) { return $null }
        if ($null -ne $StartReferenceAt -and [DateTimeOffset]$StartWindow.ResetsAt -le [DateTimeOffset]$StartReferenceAt) { return $null }
        if ($null -ne $EndReferenceAt -and [DateTimeOffset]$EndWindow.ResetsAt -le [DateTimeOffset]$EndReferenceAt) { return $null }
        $startResetIdentity = if ($null -ne $StartWindow.PSObject.Properties['ResetIdentity']) { [string]$StartWindow.ResetIdentity } else {
            Get-TokenRaderResetIdentity -WindowMinutes ([int]$StartWindow.WindowMinutes) -ResetsAt $StartWindow.ResetsAt
        }
        $endResetIdentity = if ($null -ne $EndWindow.PSObject.Properties['ResetIdentity']) { [string]$EndWindow.ResetIdentity } else {
            Get-TokenRaderResetIdentity -WindowMinutes ([int]$EndWindow.WindowMinutes) -ResetsAt $EndWindow.ResetsAt
        }
        if ([string]::IsNullOrWhiteSpace($startResetIdentity) -or $startResetIdentity -ne $endResetIdentity) { return $null }
        if ($null -ne $StartWindow.PSObject.Properties['ObservedAt'] -and $null -ne $EndWindow.PSObject.Properties['ObservedAt'] -and
            [DateTimeOffset]$EndWindow.ObservedAt -lt [DateTimeOffset]$StartWindow.ObservedAt) { return $null }
        $deltaPercent = [double]$EndWindow.UsedPercent - [double]$StartWindow.UsedPercent
        if ($deltaPercent -lt -0.000000001) { return $null }
        if ([Math]::Abs($deltaPercent) -lt 0.000000001) { $deltaPercent = 0.0 }
        $percentResolution = [Math]::Min(
            [double](Get-WindowPercentResolution $StartWindow),
            [double](Get-WindowPercentResolution $EndWindow))
        $effectiveDeltaPercent = if ($deltaPercent -gt 0) { $deltaPercent } else { $percentResolution }
        if ($effectiveDeltaPercent -le 0) { return $null }
        $totalUsd = $effectiveCost / ($effectiveDeltaPercent / 100.0)
        [pscustomobject]@{
            StartUsedPercent = [double]$StartWindow.UsedPercent
            EndUsedPercent = [double]$EndWindow.UsedPercent
            DeltaPercent = $deltaPercent
            EffectiveDeltaPercent = $effectiveDeltaPercent
            PercentResolution = $percentResolution
            ResolutionAssumptionApplied = $deltaPercent -eq 0.0
            EvidenceCost = $effectiveCost
            EvidenceFirstCountedAt = if ($useQuotaEvidence -and $null -ne $Evidence) { $Evidence.FirstCountedAt } else { $null }
            EvidenceLastCountedAt = if ($useQuotaEvidence -and $null -ne $Evidence) { $Evidence.LastCountedAt } else { $null }
            TotalUsd = $totalUsd
            UsedUsd = $totalUsd * ([double]$EndWindow.UsedPercent / 100.0)
            RemainingUsd = $totalUsd * ([double]$EndWindow.RemainingPercent / 100.0)
            WindowMinutes = [int]$EndWindow.WindowMinutes
            ResetsAt = $EndWindow.ResetsAt
            PlanType = $EndPlanType
        }
    }

    function Get-WindowPlanType {
        param($RateLimits, $Window)
        if ($null -ne $Window -and $null -ne $Window.PSObject.Properties['PlanType'] -and
            -not [string]::IsNullOrWhiteSpace([string]$Window.PlanType)) { return [string]$Window.PlanType }
        if ($null -ne $RateLimits -and $null -ne $RateLimits.PSObject.Properties['PlanType']) { return [string]$RateLimits.PlanType }
        return ''
    }
    [pscustomobject]@{
        FiveHour = if ($null -ne $EndRateLimits -and ($useQuotaEvidence -or $null -ne $StartRateLimits)) {
            Get-WindowEstimate $(if ($null -ne $StartRateLimits) { $StartRateLimits.FiveHour } else { $null }) $EndRateLimits.FiveHour $(if ($null -ne $StartRateLimits) { Get-WindowPlanType $StartRateLimits $StartRateLimits.FiveHour } else { '' }) (Get-WindowPlanType $EndRateLimits $EndRateLimits.FiveHour) $(if ($useQuotaEvidence -and $null -ne $QuotaEvidence) { $QuotaEvidence.FiveHour } else { $null })
        } else { $null }
        Weekly = if ($null -ne $EndRateLimits -and ($useQuotaEvidence -or $null -ne $StartRateLimits)) {
            Get-WindowEstimate $(if ($null -ne $StartRateLimits) { $StartRateLimits.Weekly } else { $null }) $EndRateLimits.Weekly $(if ($null -ne $StartRateLimits) { Get-WindowPlanType $StartRateLimits $StartRateLimits.Weekly } else { '' }) (Get-WindowPlanType $EndRateLimits $EndRateLimits.Weekly) $(if ($useQuotaEvidence -and $null -ne $QuotaEvidence) { $QuotaEvidence.Weekly } else { $null })
        } else { $null }
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

# ── SQLite 索引引擎（磁盘数据库，sub2api 式，内存恒定） ─────────────────

$script:TokenRaderIndex = $null

function Get-TokenRaderIndexerPath {
    return Join-Path $PSScriptRoot 'indexer\TokenRader.Indexer.dll'
}

function Get-TokenRaderIndexerDataDir {
    $dir = Join-Path $PSScriptRoot 'data\private\index'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-TokenRaderIndexerDbPath {
    # Tests may select another ignored data/private subdirectory so they never
    # overwrite a user's persistent index. Production always uses index.db.
    if (-not [string]::IsNullOrWhiteSpace($env:TOKEN_RADER_INDEX_DB)) {
        $candidate = [IO.Path]::GetFullPath($env:TOKEN_RADER_INDEX_DB)
        $normalizedCandidate = $candidate.Replace([IO.Path]::AltDirectorySeparatorChar, [IO.Path]::DirectorySeparatorChar)
        $privateSegment = [IO.Path]::DirectorySeparatorChar + 'data' + [IO.Path]::DirectorySeparatorChar + 'private' + [IO.Path]::DirectorySeparatorChar
        if ($normalizedCandidate.IndexOf($privateSegment, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw 'TOKEN_RADER_INDEX_DB 必须位于某个项目的 data/private 目录内。'
        }
        $candidateDir = Split-Path -Parent $candidate
        if (-not (Test-Path -LiteralPath $candidateDir)) { New-Item -ItemType Directory -Path $candidateDir -Force | Out-Null }
        return $candidate
    }
    return Join-Path (Get-TokenRaderIndexerDataDir) 'index.db'
}

<#
.SYNOPSIS
    加载 C# 和 SQLite DLL，返回是否成功。
#>
function Initialize-TokenRaderIndexer {
    $dllPath = Get-TokenRaderIndexerPath
    $sqlitePath = Join-Path $PSScriptRoot 'indexer\System.Data.SQLite.dll'
    if (-not (Test-Path -LiteralPath $dllPath) -or -not (Test-Path -LiteralPath $sqlitePath)) { return $false }
    try {
        Add-Type -Path $sqlitePath -ErrorAction Stop
        Add-Type -Path $dllPath -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Close-TokenRaderIndex {
    param([switch]$KeepWatcher)
    $index = $script:TokenRaderIndex
    if (-not $KeepWatcher -and $null -ne $index -and -not [string]::IsNullOrWhiteSpace([string]$index.SessionsRoot) -and
        $null -ne ('TokenRaderIndexer' -as [type])) {
        try { [TokenRaderIndexer]::StopWatcher([string]$index.SessionsRoot) } catch { }
    }
    if ($null -ne $index -and $null -ne $index.Connection) {
        try { $index.Connection.Close(); $index.Connection.Dispose() } catch { }
    }
    $script:TokenRaderIndex = $null
}

function Open-TokenRaderIndex {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)

    if (-not (Initialize-TokenRaderIndexer)) {
        throw 'C# Indexer DLL 不可用，请先运行 Build.ps1'
    }
    $canonicalRoot = [IO.Path]::GetFullPath($SessionsRoot).TrimEnd([char]'\', [char]'/')
    $existing = $script:TokenRaderIndex
    if ($null -ne $existing -and $null -ne $existing.Connection -and
        [string]$existing.SessionsRoot -eq $canonicalRoot) {
        return $existing
    }
    Close-TokenRaderIndex

    $dbPath = Get-TokenRaderIndexerDbPath
    $wasPresent = Test-Path -LiteralPath $dbPath
    $schemaLock = [TokenRaderIndexer]::AcquireFileLock(($dbPath + '.lock'), 10000)
    $conn = $null
    try {
        $conn = New-Object System.Data.SQLite.SQLiteConnection ('Data Source=' + $dbPath + ';Version=3;Default Timeout=30;')
        $conn.Open()
        $pragma = $conn.CreateCommand()
        try {
            # WAL lets readers retain a stable snapshot while another Radar
            # process commits an index batch; busy_timeout handles brief SQLite
            # lock hand-offs that occur before the explicit writer lock is held.
            $pragma.CommandText = 'PRAGMA busy_timeout=30000; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;'
            [void]$pragma.ExecuteNonQuery()
        } finally { $pragma.Dispose() }
        [TokenRaderIndexer]::CreateSchema($conn)
    } catch {
        if ($null -ne $conn) {
            try { $conn.Close(); $conn.Dispose() } catch { }
            $conn = $null
        }
        throw
    } finally {
        if ($null -ne $schemaLock) { $schemaLock.Dispose() }
    }
    try { [TokenRaderIndexer]::StartWatcher($canonicalRoot) } catch { }
    $metadata = [TokenRaderIndexer]::GetFileMetadata($conn)
    $catalogInitialized = [string][TokenRaderIndexer]::GetSetting($conn, 'catalog_initialized') -eq '1'
    $indexedRoot = [string][TokenRaderIndexer]::GetSetting($conn, 'sessions_root')
    $rootMatches = -not [string]::IsNullOrWhiteSpace($indexedRoot) -and
        $indexedRoot.Equals($canonicalRoot, [StringComparison]::OrdinalIgnoreCase)
    $script:TokenRaderIndex = [pscustomobject]@{
        DbPath = $dbPath
        Connection = $conn
        SessionsRoot = $canonicalRoot
        LastSync = $null
        LastFullReconcile = $null
        IsNew = (-not $wasPresent -or -not $catalogInitialized -or -not $rootMatches)
        CatalogInitialized = ($catalogInitialized -and $rootMatches)
        IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($conn)
        ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision($canonicalRoot)
        IndexedFileCount = [int]$metadata.Rows.Count
        LastImportedFiles = 0
        LastImportedRecords = 0
        LastFailedFiles = @()
        LastFailureMessages = @()
        SyncComplete = $true
        RootBackfilledRows = 0
    }
    return $script:TokenRaderIndex
}

function ConvertTo-TokenRaderMetadataMap {
    param([Parameter(Mandatory = $true)]$Table)
    $map = @{}
    foreach ($row in @($Table.Rows)) {
        $path = [string]$row['path']
        if (-not [string]::IsNullOrWhiteSpace($path)) { $map[$path.ToLowerInvariant()] = $row }
    }
    return $map
}

function Get-TokenRaderIndexRetentionCutoff {
    param([Parameter(Mandatory = $true)]$Connection)

    $raw = [TokenRaderIndexer]::GetSetting($Connection, 'retention_cutoff_ticks')
    if ([string]::IsNullOrWhiteSpace([string]$raw)) { return 0L }
    $cutoff = [Int64]0
    if ([Int64]::TryParse([string]$raw, [ref]$cutoff) -and $cutoff -gt 0) { return $cutoff }
    return 0L
}

function Get-TokenRaderCompleteJsonlOffset {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $FilePath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        $length = [Int64]$stream.Length
        if ($length -le 0) { return 0L }
        $bufferSize = 65536
        $end = $length
        while ($end -gt 0) {
            $start = [Math]::Max([Int64]0, $end - $bufferSize)
            $count = [int]($end - $start)
            $buffer = New-Object byte[] $count
            [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
            $read = $stream.Read($buffer, 0, $count)
            for ($i = $read - 1; $i -ge 0; $i--) {
                if ($buffer[$i] -eq 10) { return [Int64]($start + $i + 1) }
            }
            $end = $start
        }
        return 0L
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Sync-TokenRaderIndexFiles {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [AllowNull()][string[]]$CandidateFiles,
        [switch]$FullReconcile,
        [hashtable]$ProgressState
    )

    $crossProcessLock = $null
    try {
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(([string]$Index.DbPath + '.lock'), 10000)
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '读取索引游标'
        $ProgressState.ProcessedFiles = 0
        $ProgressState.TotalFiles = 0
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $conn = $Index.Connection
    $candidateMetadataOnly = -not $FullReconcile -and $null -ne $CandidateFiles
    $metadataTable = $null
    if ($candidateMetadataOnly) {
        $metadataTable = [TokenRaderIndexer]::CaptureFileCursorTableForPaths($conn, [System.Collections.IEnumerable]@($CandidateFiles))
    } else { $metadataTable = [TokenRaderIndexer]::CaptureFileCursorTable($conn) }
    $known = ConvertTo-TokenRaderMetadataMap -Table $metadataTable
    $retentionCutoff = Get-TokenRaderIndexRetentionCutoff -Connection $conn
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '枚举日志'
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $files = if ($null -eq $CandidateFiles) {
        if (Test-Path -LiteralPath $SessionsRoot) {
            @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
        } else { @() }
    } else {
        @($CandidateFiles | Select-Object -Unique | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace([string]$_) -and (Test-Path -LiteralPath $_ -PathType Leaf)) {
                $item = Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue
                if ($null -ne $item -and $item.Extension -eq '.jsonl') { $item }
            }
        })
    }

    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '比较日志游标'
        $ProgressState.ProcessedFiles = 0
        $ProgressState.TotalFiles = @($files).Count
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $seen = @{}
    $relationshipBySession = @{}
    $storedRootBySession = @{}
    $hasRelationshipChanges = $false

    $workItems = New-Object System.Collections.ArrayList
    $catalogProcessed = 0
    foreach ($file in $files) {
        $catalogProcessed++
        if ($null -ne $ProgressState -and ($catalogProcessed -eq 1 -or $catalogProcessed % 25 -eq 0)) {
            $ProgressState.ProcessedFiles = $catalogProcessed
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }
        $canonical = [IO.Path]::GetFullPath($file.FullName)
        $key = $canonical.ToLowerInvariant()
        $seen[$key] = $true
        $knownRow = if ($known.ContainsKey($key)) { $known[$key] } else { $null }
        $unchanged = $null -ne $knownRow -and
            [Int64]$knownRow['length'] -eq [Int64]$file.Length -and
            [Int64]$knownRow['last_write_ticks'] -eq [Int64]$file.LastWriteTimeUtc.Ticks
        $hasRelationship = $null -ne $knownRow -and -not [string]::IsNullOrWhiteSpace([string]$knownRow['session_id'])
        if ($unchanged -and $hasRelationship) { continue }

        $sessionMetadata = Get-TokenRaderSessionMetadata -FilePath $canonical
        if (-not [string]::IsNullOrWhiteSpace([string]$sessionMetadata.SessionId)) {
            $relationshipBySession[([string]$sessionMetadata.SessionId).ToLowerInvariant()] = $sessionMetadata
        }
        $relationshipChanged = $null -eq $knownRow -or
            -not [string]::Equals([string]$knownRow['session_id'], [string]$sessionMetadata.SessionId, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$knownRow['parent_thread_id'], [string]$sessionMetadata.ParentThreadId, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$knownRow['forked_from_id'], [string]$sessionMetadata.ForkedFromId, [StringComparison]::OrdinalIgnoreCase)
        if ($relationshipChanged) { $hasRelationshipChanges = $true }
        [void]$workItems.Add([pscustomobject]@{
            File = $file
            Canonical = $canonical
            Key = $key
            KnownRow = $knownRow
            Metadata = $sessionMetadata
            Unchanged = $unchanged
            RelationshipChanged = $relationshipChanged
        })
    }
    if ($hasRelationshipChanges) {
        # A newly discovered parent/root can resolve rows that were genuinely
        # orphaned during the previous backfill pass.
        [TokenRaderIndexer]::SetSetting($conn, 'missing_model_backfill_version', '0')
        # Relationship traversal/backfill is only needed when a candidate adds
        # or changes task ancestry. Ordinary token appends reuse the already
        # resolved root from their cursor row and avoid walking the whole
        # catalog on every refresh.
        $relationshipTable = $metadataTable
        if ($candidateMetadataOnly) { $relationshipTable = [TokenRaderIndexer]::CaptureFileCursorTable($conn) }
        foreach ($row in @($relationshipTable.Rows)) {
            $sessionId = [string]$row['session_id']
            if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
            $sessionKey = $sessionId.ToLowerInvariant()
            if (-not $relationshipBySession.ContainsKey($sessionKey)) {
                $relationshipBySession[$sessionKey] = [pscustomobject]@{
                    SessionId = $sessionId
                    ParentThreadId = [string]$row['parent_thread_id']
                    ForkedFromId = [string]$row['forked_from_id']
                }
            }
            $storedRootBySession[$sessionKey] = [string]$row['root_session_id']
        }
    }
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '处理变化日志'
        $ProgressState.ProcessedFiles = 0
        $ProgressState.TotalFiles = $workItems.Count
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }

    $resolveRoot = {
        param($Metadata)
        $root = [string]$Metadata.SessionId
        $current = $Metadata
        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        for ($depth = 0; $null -ne $current -and $depth -lt 64; $depth++) {
            $currentId = [string]$current.SessionId
            if (-not [string]::IsNullOrWhiteSpace($currentId) -and -not $visited.Add($currentId)) { break }
            $parent = if (-not [string]::IsNullOrWhiteSpace([string]$current.ParentThreadId)) {
                [string]$current.ParentThreadId
            } else { [string]$current.ForkedFromId }
            if ([string]::IsNullOrWhiteSpace($parent)) { break }
            $root = $parent
            $parentKey = $parent.ToLowerInvariant()
            if (-not $relationshipBySession.ContainsKey($parentKey)) { break }
            $current = $relationshipBySession[$parentKey]
            if (-not [string]::IsNullOrWhiteSpace([string]$current.SessionId)) { $root = [string]$current.SessionId }
        }
        if ([string]::IsNullOrWhiteSpace($root)) { $root = [string]$Metadata.SessionId }
        return $root
    }

    $importedFiles = 0
    $importedRecords = 0
    $changed = $false
    $nextRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($conn) + 1L
    $failedFiles = New-Object System.Collections.ArrayList
    $failureMessages = New-Object System.Collections.ArrayList
    $canonicalRoots = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    if ($hasRelationshipChanges) {
        foreach ($relationship in @($relationshipBySession.Values)) {
            $sessionId = [string]$relationship.SessionId
            if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
            $canonicalRoot = [string](& $resolveRoot $relationship)
            $sessionKey = $sessionId.ToLowerInvariant()
            if ($storedRootBySession.ContainsKey($sessionKey) -and
                -not [string]::IsNullOrWhiteSpace($canonicalRoot) -and
                -not [string]::Equals([string]$storedRootBySession[$sessionKey], $canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $canonicalRoots[$sessionId] = $canonicalRoot
            }
        }
    }
    $rootBackfilledRows = if ($canonicalRoots.Count -gt 0) {
        [int][TokenRaderIndexer]::BackfillSessionRoots($conn, $canonicalRoots, $nextRevision)
    } else { 0 }
    if ($rootBackfilledRows -gt 0) { $changed = $true }
    $workProcessed = 0
    foreach ($work in @($workItems)) {
        $workProcessed++
        if ($null -ne $ProgressState) {
            $ProgressState.ProcessedFiles = $workProcessed
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }
        $file = $work.File
        $canonical = [string]$work.Canonical
        $knownRow = $work.KnownRow
        $metadata = $work.Metadata
        $storedRoot = if ($null -ne $knownRow) { [string]$knownRow['root_session_id'] } else { '' }
        $rootSessionId = if (-not [bool]$work.RelationshipChanged -and -not [string]::IsNullOrWhiteSpace($storedRoot)) {
            $storedRoot
        } else { & $resolveRoot $metadata }
        $length = [Int64]$file.Length
        $lastWrite = [Int64]$file.LastWriteTimeUtc.Ticks
        $startOffset = if ($null -ne $knownRow) { [Int64]$knownRow['parsed_offset'] } else { 0L }
        $knownRetained = $null -ne $knownRow -and [int]$knownRow['content_retained'] -ne 0
        $catalogOnly = $retentionCutoff -gt 0 -and $lastWrite -lt $retentionCutoff -and -not $knownRetained
        if ($null -eq $knownRow -and $retentionCutoff -gt 0 -and $lastWrite -lt $retentionCutoff) { $catalogOnly = $true }

        try {
            $completeOffset = Get-TokenRaderCompleteJsonlOffset -FilePath $canonical
            if ($catalogOnly) {
                # Preserve only enough information to detect a later append.
                # This direct parameterized update intentionally keeps
                # content_retained=0; no token rows are reconstructed here.
                $cmd = $conn.CreateCommand()
                try {
                    $cmd.CommandText = 'INSERT OR REPLACE INTO file_metadata (path,length,last_write_ticks,parsed_offset,session_id,cwd,parent_thread_id,forked_from_id,content_retained,root_session_id) VALUES (@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,0,@p9)'
                    [void]$cmd.Parameters.AddWithValue('@p1', $canonical)
                    [void]$cmd.Parameters.AddWithValue('@p2', $length)
                    [void]$cmd.Parameters.AddWithValue('@p3', $lastWrite)
                    [void]$cmd.Parameters.AddWithValue('@p4', [Int64]$completeOffset)
                    [void]$cmd.Parameters.AddWithValue('@p5', [string]$metadata.SessionId)
                    [void]$cmd.Parameters.AddWithValue('@p6', [string]$metadata.Cwd)
                    [void]$cmd.Parameters.AddWithValue('@p7', [string]$metadata.ParentThreadId)
                    [void]$cmd.Parameters.AddWithValue('@p8', [string]$metadata.ForkedFromId)
                    [void]$cmd.Parameters.AddWithValue('@p9', [string]$rootSessionId)
                    [void]$cmd.ExecuteNonQuery()
                } finally { $cmd.Dispose() }
                $changed = $true
                continue
            }

            $knownSessionId = if ($null -ne $knownRow) { [string]$knownRow['session_id'] } else { '' }
            $requiresReplacement = $null -ne $knownRow -and (
                $length -lt $startOffset -or
                ($lastWrite -ne [Int64]$knownRow['last_write_ticks'] -and $length -le [Int64]$knownRow['length'])
            )
            if ($requiresReplacement) {
                if ([string]::IsNullOrWhiteSpace($knownSessionId)) { $knownSessionId = [string]$metadata.SessionId }
                [void][TokenRaderIndexer]::DeleteTokenRecordsBySessionId($conn, $knownSessionId)
                [void][TokenRaderIndexer]::DeleteToolRecordsBySourcePath($conn, $canonical)
                $startOffset = 0L
            }

            $count = if ($completeOffset -gt $startOffset) {
                $directParentId = if (-not [string]::IsNullOrWhiteSpace([string]$metadata.ParentThreadId)) {
                    [string]$metadata.ParentThreadId
                } else { [string]$metadata.ForkedFromId }
                [TokenRaderIndexer]::ImportFile($conn, $canonical, $startOffset, $completeOffset,
                    [string]$rootSessionId, $directParentId, $nextRevision)
            } else { 0 }
            $fresh = Get-Item -LiteralPath $canonical -ErrorAction Stop
            [TokenRaderIndexer]::UpdateFileMetadata(
                $conn, $canonical, [Int64]$fresh.Length, [Int64]$fresh.LastWriteTimeUtc.Ticks,
                [Int64]$completeOffset, [string]$metadata.SessionId, [string]$metadata.Cwd,
                [string]$metadata.ParentThreadId, [string]$metadata.ForkedFromId, [string]$rootSessionId)
            $importedFiles++
            $importedRecords += [int]$count
            $changed = $true
        } catch {
            # The watcher notification was already drained before this import.
            # Put the path back so a transient lock or replacement can never
            # silently disappear from the next synchronization attempt.
            [void]$failedFiles.Add($canonical)
            [void]$failureMessages.Add([string]$_.Exception.Message)
            [TokenRaderIndexer]::RequeueChangedPath($SessionsRoot, $canonical)
            continue
        }
    }

    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '完成索引同步'
        $ProgressState.ProcessedFiles = $ProgressState.TotalFiles
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $candidatePaths = @{}
    if ($null -ne $CandidateFiles) {
        foreach ($candidate in @($CandidateFiles | Select-Object -Unique)) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
            $canonical = [IO.Path]::GetFullPath([string]$candidate)
            $candidatePaths[$canonical.ToLowerInvariant()] = $canonical
        }
    }
    if ($FullReconcile) {
        foreach ($row in @($metadataTable.Rows)) {
            $path = [string]$row['path']
            $key = $path.ToLowerInvariant()
            if ($seen.ContainsKey($key) -or (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $sessionId = [string]$row['session_id']
            if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = Get-TokenRaderSessionIdFromPath -FilePath $path }
            [void][TokenRaderIndexer]::DeleteTokenRecordsBySessionId($conn, $sessionId)
            [void][TokenRaderIndexer]::DeleteToolRecordsBySourcePath($conn, $path)
            [TokenRaderIndexer]::RemoveFileMetadata($conn, $path)
            $changed = $true
        }
    } elseif ($null -ne $CandidateFiles) {
        foreach ($key in @($candidatePaths.Keys)) {
            $path = [string]$candidatePaths[$key]
            if ((Test-Path -LiteralPath $path -PathType Leaf) -or -not $known.ContainsKey($key)) { continue }
            $row = $known[$key]
            $sessionId = [string]$row['session_id']
            if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = Get-TokenRaderSessionIdFromPath -FilePath $path }
            [void][TokenRaderIndexer]::DeleteTokenRecordsBySessionId($conn, $sessionId)
            [void][TokenRaderIndexer]::DeleteToolRecordsBySourcePath($conn, $path)
            [TokenRaderIndexer]::RemoveFileMetadata($conn, $path)
            $changed = $true
        }
    }
    if ($FullReconcile) {
        $Index.LastFullReconcile = [DateTimeOffset]::Now
        [TokenRaderIndexer]::SetSetting($conn, 'catalog_initialized', '1')
        [TokenRaderIndexer]::SetSetting($conn, 'sessions_root', ([string]$Index.SessionsRoot))
        $Index.CatalogInitialized = $true
    }
    if ($changed) { $Index.IndexRevision = [Int64][TokenRaderIndexer]::IncrementIndexRevision($conn) }
    else { $Index.IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($conn) }
    $Index.ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision([string]$Index.SessionsRoot)
    $Index.LastSync = [DateTimeOffset]::Now
    $Index.IsNew = $false
    $Index.LastImportedFiles = $importedFiles
    $Index.LastImportedRecords = $importedRecords
    $Index.LastFailedFiles = @($failedFiles)
    $Index.LastFailureMessages = @($failureMessages)
    $Index.SyncComplete = $failedFiles.Count -eq 0
    $Index.RootBackfilledRows = $rootBackfilledRows
    $Index.IndexedFileCount = [int][TokenRaderIndexer]::GetFileCursorCount($conn)
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '同步完成'
        $ProgressState.ProcessedFiles = $ProgressState.TotalFiles
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    return $Index
    } catch {
        # Candidate watcher events may already have been drained before the
        # cross-process lock or SQLite operation failed. Requeue the complete
        # batch so a later refresh can retry it.
        if ($null -ne $CandidateFiles) {
            foreach ($candidate in @($CandidateFiles)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                    [TokenRaderIndexer]::RequeueChangedPath($SessionsRoot, [string]$candidate)
                }
            }
        }
        throw
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

<#
.SYNOPSIS
    构建索引：扫描所有 JSONL 文件，导入 SQLite 磁盘数据库。
.PARAMETER SessionsRoot
    Codex 会话日志根目录。
.PARAMETER Force
    强制重建（删除已有数据库）。
#>
function New-TokenRaderIndex {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [switch]$Force
    )

    $dbPath = Get-TokenRaderIndexerDbPath
    if ($Force) {
        $rebuildLock = [TokenRaderIndexer]::AcquireFileLock(($dbPath + '.lock'), 10000)
        try {
            Close-TokenRaderIndex
            foreach ($suffix in @('', '-wal', '-shm')) {
                $target = $dbPath + $suffix
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
            }
        } finally {
            if ($null -ne $rebuildLock) { $rebuildLock.Dispose() }
        }
    }
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $result = Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -FullReconcile
    $modelBackfill = [TokenRaderIndexer]::BackfillMissingTokenModels($result.Connection)
    $result.IndexRevision = [Int64]$modelBackfill.IndexRevision
    if (-not [bool]$modelBackfill.Completed) {
        $result.SyncComplete = $false
        $result.LastFailedFiles = @($result.LastFailedFiles) + @($modelBackfill.FailedSourcePaths)
        throw ('空模型索引回填有 {0} 个日志暂时无法校验；未将不完整索引视为成功。' -f [int]$modelBackfill.FailedFiles)
    }
    if (-not [bool]$result.SyncComplete) {
        throw ('索引构建有 {0} 个日志暂时无法读取；已保留待重试路径，未将不完整索引视为成功。' -f @($result.LastFailedFiles).Count)
    }
    return $result
}

<#
.SYNOPSIS
    增量同步：检查文件变化，只解析新增/变更部分。
#>
function Update-TokenRaderIndex {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [AllowNull()][string[]]$CandidateFiles,
        [switch]$FullReconcile,
        [switch]$AllowIncomplete,
        [hashtable]$ProgressState
    )

    $index = $script:TokenRaderIndex
    if ($null -eq $index -or $null -eq $index.Connection) {
        $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    }
    $watcherWasActive = [TokenRaderIndexer]::IsWatcherActive($SessionsRoot)
    if (-not $watcherWasActive) { [TokenRaderIndexer]::StartWatcher($SessionsRoot) }
    $result = if ($PSBoundParameters.ContainsKey('CandidateFiles')) {
        Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -CandidateFiles $CandidateFiles -ProgressState $ProgressState
    } elseif ($FullReconcile -or [bool]$index.IsNew -or (-not $watcherWasActive -and (Test-Path -LiteralPath $SessionsRoot)) -or
        [TokenRaderIndexer]::ConsumeWatcherOverflow($SessionsRoot)) {
        Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -FullReconcile -ProgressState $ProgressState
    } else {
        $changedPaths = @([TokenRaderIndexer]::DrainChangedPaths($SessionsRoot))
        if ($changedPaths.Count -gt 0) {
            Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -CandidateFiles $changedPaths -ProgressState $ProgressState
        } else {
            $index.IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
            $index.ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision($SessionsRoot)
            $index.LastImportedFiles = 0
            $index.LastImportedRecords = 0
            $index.LastFailedFiles = @()
            $index.LastFailureMessages = @()
            $index.SyncComplete = $true
            $index.RootBackfilledRows = 0
            if ($null -ne $ProgressState) {
                $ProgressState.Stage = '同步完成'
                $ProgressState.ProcessedFiles = 0
                $ProgressState.TotalFiles = 0
                $ProgressState.LastProgressAt = [DateTimeOffset]::Now
            }
            $index
        }
    }
    $modelBackfill = [TokenRaderIndexer]::BackfillMissingTokenModels($result.Connection)
    $result.IndexRevision = [Int64]$modelBackfill.IndexRevision
    if (-not [bool]$modelBackfill.Completed) {
        $result.SyncComplete = $false
        $result.LastFailedFiles = @($result.LastFailedFiles) + @($modelBackfill.FailedSourcePaths)
        if (-not $AllowIncomplete) {
            throw ('空模型索引回填有 {0} 个日志暂时无法校验；未将不完整计价视为成功。' -f [int]$modelBackfill.FailedFiles)
        }
    }
    if (-not $AllowIncomplete -and -not [bool]$result.SyncComplete) {
        throw ('索引同步有 {0} 个日志暂时无法读取；路径已重新排队，请稍后重试。' -f @($result.LastFailedFiles).Count)
    }
    return $result
}

<#
.SYNOPSIS
    删除可重建的本地索引；不会修改 Codex 原始日志。
#>
function Clear-TokenRaderIndex {
    $dbPath = Get-TokenRaderIndexerDbPath
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(($dbPath + '.lock'), 10000)
    try {
        Close-TokenRaderIndex
        foreach ($suffix in @('', '-wal', '-shm')) {
            $target = $dbPath + $suffix
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
        }
        [GC]::Collect()
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

function Remove-TokenRaderIndexHistory {
    param([ValidateRange(1, 36500)][int]$Days = 30)

    $index = $script:TokenRaderIndex
    if ($null -eq $index -or $null -eq $index.Connection) {
        throw '本地索引尚未打开。'
    }
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(([string]$index.DbPath + '.lock'), 10000)
    try {
        $requestedCutoff = [DateTime]::UtcNow.AddDays(-$Days).Ticks
        $existingCutoff = Get-TokenRaderIndexRetentionCutoff -Connection $index.Connection
        $effectiveCutoff = [Math]::Max([Int64]$requestedCutoff, [Int64]$existingCutoff)
        $removed = [TokenRaderIndexer]::PurgeIndexBefore($index.Connection, $effectiveCutoff)
        [TokenRaderIndexer]::SetSetting($index.Connection, 'retention_cutoff_ticks', ([Int64]$effectiveCutoff).ToString([Globalization.CultureInfo]::InvariantCulture))
        if ([int]$removed -gt 0) { $index.IndexRevision = [Int64][TokenRaderIndexer]::IncrementIndexRevision($index.Connection) }
        else { $index.IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection) }
        $index.LastSync = [DateTimeOffset]::Now
        $index.IndexedFileCount = [int]([TokenRaderIndexer]::GetFileMetadata($index.Connection).Rows.Count)
        [pscustomobject]@{
            Days = $Days
            CutoffUtc = [DateTime]::new([Int64]$effectiveCutoff, [DateTimeKind]::Utc)
            RemovedFiles = [int]$removed
            DbPath = [string]$index.DbPath
        }
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

function Get-TokenRaderIndex {
    return $script:TokenRaderIndex
}

function Get-TokenRaderIndexedFileMetadata {
    param(
        [int]$Days = 30,
        [int]$MaximumFiles = 0
    )
    $index = $script:TokenRaderIndex
    if ($null -eq $index -or $null -eq $index.Connection) { return $null }
    $cutoffTicks = if ($Days -gt 0) { [DateTime]::UtcNow.AddDays(-$Days).Ticks } else { 0L }
    $table = [TokenRaderIndexer]::QueryFileMetadata($index.Connection, [Int64]$cutoffTicks, [int][Math]::Max(0, $MaximumFiles))
    return ,$table
}

function ConvertFrom-TokenRaderIndexedFileRow {
    param([Parameter(Mandatory = $true)]$Row)
    $path = [string]$Row['path']
    $sessionId = if ($Row.Table.Columns.Contains('session_id')) { [string]$Row['session_id'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = Get-TokenRaderSessionIdFromPath -FilePath $path }
    $shortId = if ($sessionId.Length -gt 8) { $sessionId.Substring(0, 8) } else { $sessionId }
    $utc = [DateTime]::new([Int64]$Row['last_write_ticks'], [DateTimeKind]::Utc)
    $local = $utc.ToLocalTime()
    $length = [Int64]$Row['length']
    [pscustomobject]@{
        FilePath = $path
        SessionId = $sessionId
        ShortId = $shortId
        LastWriteTime = $local
        LastWriteTimeUtc = $utc
        Length = $length
        Cwd = if ($Row.Table.Columns.Contains('cwd')) { [string]$Row['cwd'] } else { '' }
        ParentThreadId = if ($Row.Table.Columns.Contains('parent_thread_id')) { [string]$Row['parent_thread_id'] } else { '' }
        ForkedFromId = if ($Row.Table.Columns.Contains('forked_from_id')) { [string]$Row['forked_from_id'] } else { '' }
        DisplayName = ('{0:MM-dd HH:mm}   {1}   {2}' -f $local, $shortId, (Format-TokenRaderFileSize $length))
    }
}

function Get-TokenRaderIndexedSessionFiles {
    param(
        [int]$Days = 30,
        [int]$MaximumFiles = 200
    )
    $table = Get-TokenRaderIndexedFileMetadata -Days $Days -MaximumFiles ([Math]::Max(1, $MaximumFiles))
    if ($null -eq $table) { return @() }
    $rows = foreach ($row in @($table.Rows)) { ConvertFrom-TokenRaderIndexedFileRow -Row $row }
    return @($rows)
}

function Get-TokenRaderIndexedProjects {
    param([int]$Days = 30)

    $table = Get-TokenRaderIndexedFileMetadata -Days $Days -MaximumFiles 0
    if ($null -eq $table) { return @() }
    $groups = @{}
    foreach ($row in @($table.Rows)) {
        $item = ConvertFrom-TokenRaderIndexedFileRow -Row $row
        $cwd = [string]$item.Cwd
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
                LastWriteTime = $item.LastWriteTime
                LastWriteTimeUtc = $item.LastWriteTimeUtc
                TotalBytes = [Int64]0
                Entries = New-Object System.Collections.ArrayList
            }
        }
        $group = $groups[$key]
        [void]$group.Entries.Add($item)
        $group.TotalBytes += [Int64]$item.Length
        if ($item.LastWriteTimeUtc -gt $group.LastWriteTimeUtc) {
            $group.LastWriteTime = $item.LastWriteTime
            $group.LastWriteTimeUtc = $item.LastWriteTimeUtc
        }
    }

    $projects = foreach ($group in $groups.Values) {
        $entries = @($group.Entries | Sort-Object FilePath)
        $paths = @($entries | ForEach-Object { [string]$_.FilePath })
        $signature = @($entries | ForEach-Object { '{0}|{1}|{2}' -f $_.FilePath, [Int64]$_.Length, $_.LastWriteTimeUtc.Ticks }) -join ';'
        [pscustomobject]@{
            ProjectPath = [string]$group.ProjectPath
            ProjectName = [string]$group.ProjectName
            SessionCount = $paths.Count
            LastWriteTime = $group.LastWriteTime
            LastWriteTimeUtc = $group.LastWriteTimeUtc
            TotalBytes = [Int64]$group.TotalBytes
            FilePaths = $paths
            Signature = $signature
            DisplayName = ('{0}  ·  {1} 个日志' -f [string]$group.ProjectName, $paths.Count)
        }
    }
    return @($projects | Sort-Object LastWriteTimeUtc -Descending)
}

<#
.SYNOPSIS
    从 SQLite 索引中查询 token 记录，返回 DataTable。
#>
function Get-TokenRaderIndexRecords {
    param(
        [string]$SessionId = '',
        [string]$StartTimestamp = '',
        [string]$EndTimestamp = ''
    )

    $index = $script:TokenRaderIndex
    if ($null -eq $index -or $null -eq $index.Connection) { return $null }

    $conn = $index.Connection
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return [TokenRaderIndexer]::QuerySessionSnapshot($conn, $SessionId)
    }
    if (-not [string]::IsNullOrWhiteSpace($StartTimestamp) -or -not [string]::IsNullOrWhiteSpace($EndTimestamp)) {
        $start = if ([string]::IsNullOrWhiteSpace($StartTimestamp)) { '0000-01-01' } else { $StartTimestamp }
        $end = if ([string]::IsNullOrWhiteSpace($EndTimestamp)) { '9999-12-31' } else { $EndTimestamp }
        return [TokenRaderIndexer]::QueryTimeRange($conn, $start, $end)
    }
    return $null
}

<#
.SYNOPSIS
    将 SQLite 查询结果行（DataRow）转换为 UI 可用的 pscustomobject 格式。
.PARAMETER Row
    DataRow，来自 Get-TokenRaderIndexRecords 返回的 DataTable。
#>
function ConvertFrom-TokenRaderIndexRecord {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [string]$FilePath = ''
    )

    $totalInput = [Int64]$Row['total_input']
    $totalCached = [Int64]$Row['total_cached']
    $totalOutput = [Int64]$Row['total_output']
    $totalUncached = $totalInput - $totalCached
    $totalTotal = $totalInput + $totalOutput
    $totalHitRate = if ($totalInput -gt 0) { ($totalCached * 100.0) / $totalInput } else { 0.0 }

    $callInput = [Int64]$Row['call_input']
    $callCached = [Int64]$Row['call_cached']
    $callOutput = [Int64]$Row['call_output']
    $callUncached = $callInput - $callCached
    $callTotal = $callInput + $callOutput
    $callHitRate = if ($callInput -gt 0) { ($callCached * 100.0) / $callInput } else { 0.0 }

    $timestamp = [DateTimeOffset]::MinValue
    try { $timestamp = [DateTimeOffset]::Parse([string]$Row['timestamp']).ToLocalTime() } catch { }
    $sourceFile = if ($Row.Table.Columns.Contains('source_path')) { [string]$Row['source_path'] } else { $FilePath }
    if ([string]::IsNullOrWhiteSpace($FilePath)) { $FilePath = $sourceFile }
    $planType = [string]$Row['plan_type']
    $readNullableInt64 = {
        param([string]$Name)
        if (-not $Row.Table.Columns.Contains($Name)) { return $null }
        $value = $Row[$Name]
        if ($null -eq $value -or [DBNull]::Value.Equals($value)) { return $null }
        return [Int64]$value
    }

    $fiveHour = $null
    $weekly = $null
    $fhUsed = $Row['five_hour_used']
    if ($null -ne $fhUsed -and -not [DBNull]::Value.Equals($fhUsed)) {
        $fiveHour = [pscustomobject]@{
            UsedPercent = [double]$fhUsed
            RemainingPercent = 100.0 - [double]$fhUsed
            WindowMinutes = [int]$Row['five_hour_window']
            ResetsAt = if ($null -ne $Row['five_hour_resets'] -and -not [DBNull]::Value.Equals($Row['five_hour_resets'])) { [DateTimeOffset]::FromUnixTimeSeconds([Int64]$Row['five_hour_resets']).ToLocalTime() } else { $null }
            ObservedAt = $timestamp
            SourceFile = $sourceFile
            PlanType = $planType
            UsedTokens = & $readNullableInt64 'five_hour_used_tokens'
            RemainingTokens = & $readNullableInt64 'five_hour_remaining_tokens'
            LimitTokens = & $readNullableInt64 'five_hour_limit_tokens'
            ResetIdentity = if ($null -ne $Row['five_hour_resets'] -and -not [DBNull]::Value.Equals($Row['five_hour_resets'])) { '300:' + [string][Int64]$Row['five_hour_resets'] } else { '' }
        }
        $fiveHour.ResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes ([int]$fiveHour.WindowMinutes) -ResetsAt $fiveHour.ResetsAt
    }
    $wkUsed = $Row['weekly_used']
    if ($null -ne $wkUsed -and -not [DBNull]::Value.Equals($wkUsed)) {
        $weekly = [pscustomobject]@{
            UsedPercent = [double]$wkUsed
            RemainingPercent = 100.0 - [double]$wkUsed
            WindowMinutes = [int]$Row['weekly_window']
            ResetsAt = if ($null -ne $Row['weekly_resets'] -and -not [DBNull]::Value.Equals($Row['weekly_resets'])) { [DateTimeOffset]::FromUnixTimeSeconds([Int64]$Row['weekly_resets']).ToLocalTime() } else { $null }
            ObservedAt = $timestamp
            SourceFile = $sourceFile
            PlanType = $planType
            UsedTokens = & $readNullableInt64 'weekly_used_tokens'
            RemainingTokens = & $readNullableInt64 'weekly_remaining_tokens'
            LimitTokens = & $readNullableInt64 'weekly_limit_tokens'
            ResetIdentity = ''
        }
        $weekly.ResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes ([int]$weekly.WindowMinutes) -ResetsAt $weekly.ResetsAt
    }

    $rateLimits = [pscustomobject]@{
        ObservedAt = $timestamp
        PlanType = $planType
        LimitId = if ($Row.Table.Columns.Contains('rate_limit_id')) { [string]$Row['rate_limit_id'] } else { '' }
        LimitName = if ($Row.Table.Columns.Contains('rate_limit_name')) { [string]$Row['rate_limit_name'] } else { '' }
        IndividualLimit = if ($Row.Table.Columns.Contains('rate_limit_individual') -and -not [DBNull]::Value.Equals($Row['rate_limit_individual'])) { [bool]([int]$Row['rate_limit_individual']) } else { $null }
        RateLimitReachedType = if ($Row.Table.Columns.Contains('rate_limit_reached_type')) { [string]$Row['rate_limit_reached_type'] } else { '' }
        SpendControlReached = if ($Row.Table.Columns.Contains('spend_control_reached') -and -not [DBNull]::Value.Equals($Row['spend_control_reached'])) { [bool]([int]$Row['spend_control_reached']) } else { $null }
        CreditsBalance = if ($Row.Table.Columns.Contains('credits_balance') -and -not [DBNull]::Value.Equals($Row['credits_balance'])) { [double]$Row['credits_balance'] } else { $null }
        CreditsHas = if ($Row.Table.Columns.Contains('credits_has') -and -not [DBNull]::Value.Equals($Row['credits_has'])) { [bool]([int]$Row['credits_has']) } else { $null }
        CreditsUnlimited = if ($Row.Table.Columns.Contains('credits_unlimited') -and -not [DBNull]::Value.Equals($Row['credits_unlimited'])) { [bool]([int]$Row['credits_unlimited']) } else { $null }
        FiveHour = $fiveHour
        Weekly = $weekly
    }

    $recordModel = [string]$Row['model']
    [Int64]$recordLongThreshold = if ($Row.Table.Columns.Contains('long_context_threshold') -and -not [DBNull]::Value.Equals($Row['long_context_threshold'])) { [Int64]$Row['long_context_threshold'] } else { 0L }
    $recordLongSource = if ($Row.Table.Columns.Contains('long_context_source')) { [string]$Row['long_context_source'] } else { '' }
    if (@('pricing_threshold', 'no_threshold', 'unknown_model', 'missing_input') -notcontains $recordLongSource) {
        $recordLongSource = if ($callInput -le 0L) { 'missing_input' }
                            elseif ([string]::IsNullOrWhiteSpace($recordModel)) { 'unknown_model' }
                            elseif ($recordLongThreshold -gt 0L) { 'pricing_threshold' }
                            else { 'no_threshold' }
    }

    [pscustomobject]@{
        FilePath = $FilePath
        Timestamp = $timestamp
        Model = $recordModel
        ModelSource = if ($Row.Table.Columns.Contains('model_source')) { [string]$Row['model_source'] } else { '' }
        TurnId = if ($Row.Table.Columns.Contains('turn_id')) { [string]$Row['turn_id'] } else { '' }
        RequestId = if ($Row.Table.Columns.Contains('request_id')) { [string]$Row['request_id'] } else { '' }
        ResponseId = if ($Row.Table.Columns.Contains('response_id')) { [string]$Row['response_id'] } else { '' }
        IdentitySource = if ($Row.Table.Columns.Contains('identity_source')) { [string]$Row['identity_source'] } else { '' }
        ServiceTier = if ($Row.Table.Columns.Contains('service_tier')) { [string]$Row['service_tier'] } else { '' }
        ReasoningEffort = if ($Row.Table.Columns.Contains('reasoning_effort')) { [string]$Row['reasoning_effort'] } else { '' }
        ModelContextWindow = if ($Row.Table.Columns.Contains('model_context_window') -and -not [DBNull]::Value.Equals($Row['model_context_window'])) { [Int64]$Row['model_context_window'] } else { $null }
        LongContextThreshold = if ($recordLongThreshold -gt 0L) { $recordLongThreshold } else { $null }
        LongContextApplied = if ($Row.Table.Columns.Contains('long_context_applied')) { [bool]([int]$Row['long_context_applied']) } else { $false }
        LongContextSource = $recordLongSource
        CacheCreationTokens = if ($Row.Table.Columns.Contains('cache_creation_tokens')) { [Int64]$Row['cache_creation_tokens'] } else { 0L }
        CacheWriteObservable = if ($Row.Table.Columns.Contains('cache_write_observable')) { [bool]([int]$Row['cache_write_observable']) } else { $false }
        PlanType = [string]$Row['plan_type']
        RateLimits = $rateLimits
        Task = [pscustomobject]@{
            Input = $totalInput
            Cached = $totalCached
            Uncached = $totalUncached
            Output = $totalOutput
            ReasoningOutput = [Int64]$Row['total_reasoning']
            Total = $totalTotal
            CacheHitRate = $totalHitRate
        }
        Call = [pscustomobject]@{
            Input = $callInput
            Cached = $callCached
            Uncached = $callUncached
            Output = $callOutput
            ReasoningOutput = [Int64]$Row['call_reasoning']
            Total = $callTotal
            CacheHitRate = $callHitRate
        }
        ContextWindow = if ($Row.Table.Columns.Contains('model_context_window') -and -not [DBNull]::Value.Equals($Row['model_context_window'])) { [Int64]$Row['model_context_window'] } else { [Int64]0 }
        TailLinesRead = 0
        TokenRecordIndex = 0
        RecordId = if ($Row.Table.Columns.Contains('id')) { [Int64]$Row['id'] } else { 0L }
        SessionId = if ($Row.Table.Columns.Contains('session_id')) { [string]$Row['session_id'] } else { '' }
        RootSessionId = if ($Row.Table.Columns.Contains('root_session_id')) { [string]$Row['root_session_id'] } else { '' }
        SourceOffsetEnd = if ($Row.Table.Columns.Contains('source_offset_end')) { [Int64]$Row['source_offset_end'] } else { 0L }
        UsageFingerprint = if ($Row.Table.Columns.Contains('fingerprint')) { [string]$Row['fingerprint'] } else { '' }
        IndexRevision = if ($Row.Table.Columns.Contains('index_revision')) { [Int64]$Row['index_revision'] } else { 0L }
    }
}

function ConvertTo-TokenRaderOffsetMap {
    param($Value)
    $map = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $Value) { return $map }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            try { $map[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$key))] = [Int64]$Value[$key] } catch { }
        }
    } elseif ($null -ne $Value.PSObject) {
        foreach ($property in @($Value.PSObject.Properties)) {
            try { $map[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$property.Name))] = [Int64]$property.Value } catch { }
        }
    }
    return $map
}

function Get-TokenRaderCursorOffsets {
    param([Parameter(Mandatory = $true)]$Connection)
    return ,([TokenRaderIndexer]::CaptureFileCursorOffsets($Connection))
}

function ConvertFrom-TokenRaderRateLimitRows {
    param($Table)
    if ($null -eq $Table -or $Table.Rows.Count -eq 0) { return $null }
    $fiveHour = $null
    $weekly = $null
    $fiveObserved = [DateTimeOffset]::MinValue
    $weeklyObserved = [DateTimeOffset]::MinValue
    $latestMetadata = $null
    $latestMetadataObserved = [DateTimeOffset]::MinValue
    foreach ($row in @($Table.Rows)) {
        $record = ConvertFrom-TokenRaderIndexRecord -Row $row
        if ([DateTimeOffset]$record.RateLimits.ObservedAt -ge $latestMetadataObserved) {
            $latestMetadata = $record.RateLimits
            $latestMetadataObserved = [DateTimeOffset]$record.RateLimits.ObservedAt
        }
        if ($null -ne $record.RateLimits.FiveHour -and [DateTimeOffset]$record.RateLimits.FiveHour.ObservedAt -ge $fiveObserved) {
            $fiveHour = $record.RateLimits.FiveHour
            $fiveObserved = [DateTimeOffset]$fiveHour.ObservedAt
        }
        if ($null -ne $record.RateLimits.Weekly -and [DateTimeOffset]$record.RateLimits.Weekly.ObservedAt -ge $weeklyObserved) {
            $weekly = $record.RateLimits.Weekly
            $weeklyObserved = [DateTimeOffset]$weekly.ObservedAt
        }
    }
    if ($null -eq $fiveHour -and $null -eq $weekly) { return $null }
    $planType = if ($fiveObserved -ge $weeklyObserved -and $null -ne $fiveHour) { [string]$fiveHour.PlanType }
                elseif ($null -ne $weekly) { [string]$weekly.PlanType }
                else { '' }
    [pscustomobject]@{
        ObservedAt = if ($fiveObserved -ge $weeklyObserved) { $fiveObserved } else { $weeklyObserved }
        PlanType = $planType
        LimitId = if ($null -ne $latestMetadata) { [string]$latestMetadata.LimitId } else { '' }
        LimitName = if ($null -ne $latestMetadata) { [string]$latestMetadata.LimitName } else { '' }
        IndividualLimit = if ($null -ne $latestMetadata) { $latestMetadata.IndividualLimit } else { $null }
        RateLimitReachedType = if ($null -ne $latestMetadata) { [string]$latestMetadata.RateLimitReachedType } else { '' }
        SpendControlReached = if ($null -ne $latestMetadata) { $latestMetadata.SpendControlReached } else { $null }
        CreditsBalance = if ($null -ne $latestMetadata) { $latestMetadata.CreditsBalance } else { $null }
        CreditsHas = if ($null -ne $latestMetadata) { $latestMetadata.CreditsHas } else { $null }
        CreditsUnlimited = if ($null -ne $latestMetadata) { $latestMetadata.CreditsUnlimited } else { $null }
        FiveHour = $fiveHour
        Weekly = $weekly
    }
}

function Get-TokenRaderIndexedRateLimitsAtOffsets {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)]$EndOffsets
    )
    $ends = ConvertTo-TokenRaderOffsetMap -Value $EndOffsets
    $starts = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($ends.Keys)) { $starts[$path] = 0L }
    if ($ends.Count -eq 0) { return $null }
    $table = [TokenRaderIndexer]::QueryLatestRateLimitsByOffsets($Connection, $starts, $ends)
    return ConvertFrom-TokenRaderRateLimitRows -Table $table
}

function Get-TokenRaderIndexedLatestRateLimits {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $offsets = Get-TokenRaderCursorOffsets -Connection $index.Connection
    return Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $index.Connection -EndOffsets $offsets
}

function GetIndexRevision {
    param([string]$SessionsRoot = '')
    $index = $script:TokenRaderIndex
    if (($null -eq $index -or $null -eq $index.Connection) -and -not [string]::IsNullOrWhiteSpace($SessionsRoot)) {
        $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    }
    if ($null -eq $index -or $null -eq $index.Connection) { return 0L }
    $index.IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
    return [Int64]$index.IndexRevision
}

function Get-TokenRaderChangeRevision {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)
    if ($null -eq ('TokenRaderIndexer' -as [type])) { return 0L }
    return [Int64][TokenRaderIndexer]::GetChangeRevision($SessionsRoot)
}

function Sync-TokenRaderMeasurementBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [hashtable]$ProgressState = $null,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 25
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $stableCatalogPasses = 0
    $attempt = 0
    $totalImportedFiles = 0
    $totalImportedRecords = 0
    $totalRootBackfills = 0
    $lastSyncError = ''
    do {
        $attempt++
        if ($null -ne $ProgressState) {
            $ProgressState.Stage = '核对全部日志边界'
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }

        # Compare every lightweight cursor in compiled code on every pass and
        # merge the watcher queue before import. A subsequent catalog with no
        # changed path defines the frozen boundary without depending on watcher
        # delivery latency or processing the same notification twice.
        $openIndex = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
        $changedFiles = @()
        $catalogChangedFiles = @()
        $indexWasNew = [bool]$openIndex.IsNew
        $revisionBeforePass = [Int64][TokenRaderIndexer]::GetIndexRevision($openIndex.Connection)
        if (-not $indexWasNew) {
            $catalogChangedFiles = @([TokenRaderIndexer]::FindChangedFiles($openIndex.Connection, $SessionsRoot))
            $changedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($path in @($catalogChangedFiles)) { [void]$changedSet.Add([string]$path) }
            foreach ($path in @([TokenRaderIndexer]::DrainChangedPaths($SessionsRoot))) { [void]$changedSet.Add([string]$path) }
            $changedFiles = @($changedSet)
        }
        if ($null -ne $ProgressState) {
            $ProgressState.Stage = '同步边界变化日志'
            $ProgressState.TotalFiles = $changedFiles.Count
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }
        try {
            $index = if ($indexWasNew) {
                Update-TokenRaderIndex -SessionsRoot $SessionsRoot -FullReconcile -AllowIncomplete -ProgressState $ProgressState
            } elseif ($changedFiles.Count -gt 0) {
                Update-TokenRaderIndex -SessionsRoot $SessionsRoot -CandidateFiles $changedFiles -AllowIncomplete -ProgressState $ProgressState
            } else {
                Update-TokenRaderIndex -SessionsRoot $SessionsRoot -AllowIncomplete -ProgressState $ProgressState
            }
        } catch {
            # A competing Radar process, file replacement, or brief SQLite
            # hand-off can fail before a per-file incomplete result exists.
            # Sync-TokenRaderIndexFiles has already requeued the candidates;
            # keep retrying within the same bounded boundary capture.
            $lastSyncError = [string]$_.Exception.Message
            $stableCatalogPasses = 0
            if ($null -ne $ProgressState) {
                $ProgressState.Stage = '等待并发索引写入完成后重试'
                $ProgressState.LastProgressAt = [DateTimeOffset]::Now
            }
            if ([DateTimeOffset]::Now -ge $deadline) { break }
            Start-Sleep -Milliseconds ([Math]::Min(500, 50 + ($attempt * 25)))
            continue
        }
        $totalImportedFiles += [int]$index.LastImportedFiles
        $totalImportedRecords += [int]$index.LastImportedRecords
        $totalRootBackfills += [int]$index.RootBackfilledRows
        $failedCount = @($index.LastFailedFiles).Count
        if ($failedCount -gt 0) {
            $stableCatalogPasses = 0
            if ($null -ne $ProgressState) {
                $ProgressState.Stage = ('重试 {0} 个暂时不可读日志' -f $failedCount)
                $ProgressState.LastProgressAt = [DateTimeOffset]::Now
            }
            if ([DateTimeOffset]::Now -ge $deadline) { break }
            Start-Sleep -Milliseconds ([Math]::Min(500, 50 + ($attempt * 25)))
            continue
        }

        # A late duplicate watcher notification can name a file that the
        # previous pass already imported. It is still verified above, but it
        # must not force an unnecessary third catalog scan. Only a real catalog
        # difference or an actual index revision advance counts as new work.
        $didWork = $indexWasNew -or $catalogChangedFiles.Count -gt 0 -or
            [Int64]$index.IndexRevision -gt $revisionBeforePass -or
            [int]$index.LastImportedFiles -gt 0 -or [int]$index.RootBackfilledRows -gt 0
        if ($didWork) {
            $stableCatalogPasses = 0
        } else {
            $stableCatalogPasses++
        }
        if ($stableCatalogPasses -ge 1) {
            $index.LastImportedFiles = $totalImportedFiles
            $index.LastImportedRecords = $totalImportedRecords
            $index.RootBackfilledRows = $totalRootBackfills
            if ($null -ne $ProgressState) {
                $ProgressState.Stage = '日志边界已稳定'
                $ProgressState.LastProgressAt = [DateTimeOffset]::Now
            }
            return $index
        }
    } while ([DateTimeOffset]::Now -lt $deadline)

    $remaining = if ($null -ne $index) { @($index.LastFailedFiles).Count } else { 0 }
    $detail = if ([string]::IsNullOrWhiteSpace($lastSyncError)) { '' } else { ' 最近错误：' + $lastSyncError }
    throw ('无法在 {0} 秒内获得完整且稳定的日志边界（仍有 {1} 个日志待同步）；未冻结不完整结果。{2}' -f $TimeoutSeconds, $remaining, $detail)
}

function CaptureMeasurementBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        $PricingDocument = $null,
        [string]$AccountIdentity = ''
    )
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $gate = [TokenRaderIndexer]::AcquireIndexGate($SessionsRoot)
    try {
        $index = Sync-TokenRaderMeasurementBoundary -SessionsRoot $SessionsRoot
        $startOffsets = Get-TokenRaderCursorOffsets -Connection $index.Connection
        $startRateLimits = Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $index.Connection -EndOffsets $startOffsets
        $files = foreach ($path in @($startOffsets.Keys)) {
            [pscustomobject]@{
                FilePath = [string]$path
                Length = [Int64]$startOffsets[$path]
                LastWriteTimeUtc = [DateTime]::MinValue
                BaselineLoaded = $false
                BaselineTask = $null
                BaselineModel = ''
            }
        }
        # The real timer starts only after synchronization and both snapshots
        # are frozen. Calls generated during Starting are filtered by time.
        $startedAt = [DateTimeOffset]::Now
        [pscustomobject]@{
            StartedAt = $startedAt
            SessionsRoot = [string]$index.SessionsRoot
            Files = @($files)
            StartOffsets = $startOffsets
            RateLimits = $startRateLimits
            StartRateLimits = $startRateLimits
            AccountIdentity = $AccountIdentity
            PlanType = if ($null -ne $startRateLimits) { [string]$startRateLimits.PlanType } else { '' }
            IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
            ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision($SessionsRoot)
        }
    } finally {
        $gate.Dispose()
    }
}

function CaptureMeasurementEnd {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [switch]$IncludeRateLimits,
        [hashtable]$ProgressState
    )
    $sessionsRoot = [string]$Baseline.SessionsRoot
    $index = Open-TokenRaderIndex -SessionsRoot $sessionsRoot
    $gate = [TokenRaderIndexer]::AcquireIndexGate($sessionsRoot)
    try {
        $index = Sync-TokenRaderMeasurementBoundary -SessionsRoot $sessionsRoot -ProgressState $ProgressState
        $endOffsets = Get-TokenRaderCursorOffsets -Connection $index.Connection
        # The UI only needs immutable offsets/revision to finish Stopping.
        # Quota lookup is intentionally deferred to interval settlement, where
        # it queries these same frozen offsets and cannot see later appends.
        $endRateLimits = if ($IncludeRateLimits) {
            Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $index.Connection -EndOffsets $endOffsets
        } else { $null }
        [pscustomobject]@{
            EndedAt = [DateTimeOffset]::Now
            EndOffsets = $endOffsets
            EndRateLimits = $endRateLimits
            EndRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
            ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision($sessionsRoot)
        }
    } finally {
        $gate.Dispose()
    }
}

function QueryIntervalRecords {
    param(
        [Parameter(Mandatory = $true)]$StartOffsets,
        [Parameter(Mandatory = $true)]$EndOffsets,
        [string]$SessionsRoot = ''
    )
    $index = $script:TokenRaderIndex
    if (($null -eq $index -or $null -eq $index.Connection) -and -not [string]::IsNullOrWhiteSpace($SessionsRoot)) {
        $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    }
    if ($null -eq $index -or $null -eq $index.Connection) { return $null }
    $startsInput = ConvertTo-TokenRaderOffsetMap -Value $StartOffsets
    $ends = ConvertTo-TokenRaderOffsetMap -Value $EndOffsets
    $starts = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($ends.Keys)) {
        $starts[$path] = if ($startsInput.ContainsKey($path)) { [Int64]$startsInput[$path] } else { 0L }
    }
    return ,([TokenRaderIndexer]::QueryIntervalRecords($index.Connection, $starts, $ends))
}

function ConvertFrom-TokenRaderPricedAggregate {
    param(
        [Parameter(Mandatory = $true)]$Aggregate,
        [Parameter(Mandatory = $true)]$PricingDocument
    )
    $unknownModels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [double]$inputCost = 0
    [double]$cachedCost = 0
    [double]$outputCost = 0
    [double]$cacheCreationCost = 0
    [double]$longContextExtraCost = 0
    [Int64]$standardContextEvents = 0
    [Int64]$longContextEvents = 0
    [Int64]$standardContextInput = 0
    [Int64]$longContextInput = 0
    [Int64]$longContextOutput = 0
    $cacheWriteObservable = $true
    $priceCache = @{}
    $unitTokens = if ($null -ne $PricingDocument.PSObject.Properties['unitTokens'] -and [double]$PricingDocument.unitTokens -gt 0) {
        [double]$PricingDocument.unitTokens
    } else { 1000000.0 }
    $items = foreach ($bucket in @($Aggregate.Buckets)) {
        if ($null -eq $bucket.PSObject.Properties['CacheWriteObservable'] -or -not [bool]$bucket.CacheWriteObservable) { $cacheWriteObservable = $false }
        $bucketUsage = New-TokenRaderUsage -InputTokens $bucket.Input -CachedTokens $bucket.Cached -OutputTokens $bucket.Output -ReasoningOutputTokens $bucket.Reasoning
        $model = [string]$bucket.Model
        if (-not $priceCache.ContainsKey($model)) { $priceCache[$model] = Resolve-TokenRaderPrice -Model $model -PricingDocument $PricingDocument }
        $price = $priceCache[$model]
        $known = $null -ne $price
        [double]$bucketInputCost = 0
        [double]$bucketCachedCost = 0
        [double]$bucketOutputCost = 0
        [double]$bucketCacheCreationCost = 0
        [double]$inputMultiplier = 1.0
        [double]$outputMultiplier = 1.0
        if ($known) {
            if ([bool]$bucket.LongContext) {
                $inputMultiplier = if ($null -ne $price.PSObject.Properties['longContextInputMultiplier']) { [double]$price.longContextInputMultiplier } else { 2.0 }
                $outputMultiplier = if ($null -ne $price.PSObject.Properties['longContextOutputMultiplier']) { [double]$price.longContextOutputMultiplier } else { 1.5 }
            }
            [Int64]$bucketCacheCreationTokens = if ($null -ne $bucket.PSObject.Properties['CacheCreationTokens']) { [Math]::Min([Int64]$bucket.CacheCreationTokens, [Int64]$bucketUsage.Uncached) } else { 0L }
            [Int64]$ordinaryUncached = [Math]::Max([Int64]0, [Int64]$bucketUsage.Uncached - $bucketCacheCreationTokens)
            $bucketInputCost = ([double]$ordinaryUncached / $unitTokens) * [double]$price.input * $inputMultiplier
            $bucketCacheCreationCost = ([double]$bucketCacheCreationTokens / $unitTokens) * [double]$price.input * 1.25 * $inputMultiplier
            $bucketInputCost += $bucketCacheCreationCost
            $bucketCachedCost = ([double]$bucketUsage.Cached / $unitTokens) * [double]$price.cachedInput * $inputMultiplier
            $bucketOutputCost = ([double]$bucketUsage.Output / $unitTokens) * [double]$price.output * $outputMultiplier
            $inputCost += $bucketInputCost
            $cacheCreationCost += $bucketCacheCreationCost
            $cachedCost += $bucketCachedCost
            $outputCost += $bucketOutputCost
            if ([bool]$bucket.LongContext) {
                $longContextEvents += [Int64]$bucket.Events
                $longContextInput += [Int64]$bucketUsage.Input
                $longContextOutput += [Int64]$bucketUsage.Output
                $standardInputCost = ([double]$ordinaryUncached / $unitTokens) * [double]$price.input + ([double]$bucketCacheCreationTokens / $unitTokens) * [double]$price.input * 1.25
                $standardCachedCost = ([double]$bucketUsage.Cached / $unitTokens) * [double]$price.cachedInput
                $standardOutputCost = ([double]$bucketUsage.Output / $unitTokens) * [double]$price.output
                $longContextExtraCost += ([double]$bucketInputCost + [double]$bucketCachedCost + [double]$bucketOutputCost) - ($standardInputCost + $standardCachedCost + $standardOutputCost)
            } else {
                $standardContextEvents += [Int64]$bucket.Events
                $standardContextInput += [Int64]$bucketUsage.Input
            }
        } else {
            [void]$unknownModels.Add($(if ([string]::IsNullOrWhiteSpace($model)) { '未知模型' } else { $model }))
        }
        [pscustomobject]@{
            Model = $model
            LongContext = [bool]$bucket.LongContext
            Usage = $bucketUsage
            Events = [Int64]$bucket.Events
            ModelContextWindow = if ($null -ne $bucket.PSObject.Properties['ModelContextWindow']) { [Int64]$bucket.ModelContextWindow } else { 0L }
            LongContextThreshold = if ($null -ne $bucket.PSObject.Properties['LongContextThreshold']) { [Int64]$bucket.LongContextThreshold } else { 0L }
            LongContextSource = if ($null -ne $bucket.PSObject.Properties['LongContextSource']) { [string]$bucket.LongContextSource } else { '' }
            CacheWriteObservable = if ($null -ne $bucket.PSObject.Properties['CacheWriteObservable']) { [bool]$bucket.CacheWriteObservable } else { $false }
            Cost = [pscustomobject]@{
                Known = $known; Model = $model; Price = $price
                InputCost = $bucketInputCost; CachedCost = $bucketCachedCost; OutputCost = $bucketOutputCost
                TotalCost = $bucketInputCost + $bucketCachedCost + $bucketOutputCost
                CacheCreationCost = $bucketCacheCreationCost
                LongContextApplied = [bool]$bucket.LongContext
                InputMultiplier = $inputMultiplier
                OutputMultiplier = $outputMultiplier
                ModelContextWindow = if ($null -ne $bucket.PSObject.Properties['ModelContextWindow']) { [Int64]$bucket.ModelContextWindow } else { $null }
                LongContextThreshold = if ($null -ne $bucket.PSObject.Properties['LongContextThreshold']) { [Int64]$bucket.LongContextThreshold } else { $null }
                LongContextSource = if ($null -ne $bucket.PSObject.Properties['LongContextSource']) { [string]$bucket.LongContextSource } else { '' }
                CacheWriteObservable = if ($null -ne $bucket.PSObject.Properties['CacheWriteObservable']) { [bool]$bucket.CacheWriteObservable } else { $false }
                CostCoverage = if ($null -ne $bucket.PSObject.Properties['CacheWriteObservable'] -and [bool]$bucket.CacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
            }
        }
    }
    $models = @($Aggregate.Models)
    $usage = New-TokenRaderUsage -InputTokens $Aggregate.TotalInput -CachedTokens $Aggregate.TotalCached -OutputTokens $Aggregate.TotalOutput -ReasoningOutputTokens $Aggregate.TotalReasoning
    [pscustomobject]@{
        Usage = $usage
        Models = $models
        ModelDisplay = if ($models.Count -eq 0) { '等待模型调用' } elseif ($models.Count -eq 1) { $models[0] } else { '{0} 个模型' -f $models.Count }
        Items = @($items)
        InputCost = $inputCost
        CachedCost = $cachedCost
        OutputCost = $outputCost
        CacheCreationCost = $cacheCreationCost
        TotalCost = $inputCost + $cachedCost + $outputCost
        PricingComplete = $unknownModels.Count -eq 0
        CostComplete = $unknownModels.Count -eq 0
        UnknownModels = @($unknownModels | Sort-Object)
        StandardContextEvents = $standardContextEvents
        LongContextEvents = $longContextEvents
        StandardContextInput = $standardContextInput
        LongContextInput = $longContextInput
        LongContextOutput = $longContextOutput
        LongContextExtraCost = $longContextExtraCost
        CacheWriteObservable = $cacheWriteObservable
        CostCoverage = if ($cacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
    }
}

function Get-TokenRaderQuotaWindowEvidence {
    param(
        $StartWindow,
        $EndWindow,
        $MainLastCountedAt,
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)]$EndOffsets,
        [Parameter(Mandatory = $true)]$Thresholds,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [Parameter(Mandatory = $true)][Threading.CancellationToken]$CancellationToken,
        [hashtable]$ProgressState,
        [hashtable]$Cache
    )
    # Quota evidence is bounded by the two observed snapshots, not by the
    # beginning of the provider's rolling window.  Using
    # reset_at-window_minutes here would include every call since the quota
    # window opened and is the primary way an estimate can be inflated by an
    # order of magnitude.  Both endpoints must carry reliable identity data so
    # a reset or account/plan switch cannot be mistaken for usage in one span.
    if ($null -eq $StartWindow -or $null -eq $EndWindow -or
        $null -eq $StartWindow.PSObject.Properties['ObservedAt'] -or
        $null -eq $EndWindow.PSObject.Properties['ObservedAt'] -or
        $null -eq $StartWindow.ResetsAt -or $null -eq $EndWindow.ResetsAt -or
        [int]$StartWindow.WindowMinutes -le 0 -or [int]$EndWindow.WindowMinutes -le 0) { return $null }
    $startObservedAt = [DateTimeOffset]$StartWindow.ObservedAt
    $endObservedAt = [DateTimeOffset]$EndWindow.ObservedAt
    $windowStartAt = $startObservedAt
    $sameWindow = [int]$StartWindow.WindowMinutes -eq [int]$EndWindow.WindowMinutes
    $samePlan = [string]::Equals([string]$StartWindow.PlanType, [string]$EndWindow.PlanType, [StringComparison]::OrdinalIgnoreCase)
    $startReset = Get-TokenRaderResetIdentity -WindowMinutes ([int]$StartWindow.WindowMinutes) -ResetsAt $StartWindow.ResetsAt
    $endReset = Get-TokenRaderResetIdentity -WindowMinutes ([int]$EndWindow.WindowMinutes) -ResetsAt $EndWindow.ResetsAt
    $sameReset = -not [string]::IsNullOrWhiteSpace($startReset) -and [string]::Equals($startReset, $endReset, [StringComparison]::Ordinal)
    # BoundaryValid describes the quota evidence's own immutable interval.
    # A token-only child/descendant record can legitimately be written after
    # the latest record that carries rate_limits.  That means the evidence no
    # longer covers the newest main-interval call, but it is still a strictly
    # aligned (StartObservedAt, EndObservedAt] calibration and must remain
    # usable.  Mixing the newer main-interval cost into it is still forbidden.
    $boundaryValid = $sameWindow -and $samePlan -and $sameReset -and $endObservedAt -gt $startObservedAt
    $coverageComplete = $boundaryValid -and ($null -eq $MainLastCountedAt -or
        $endObservedAt -ge [DateTimeOffset]$MainLastCountedAt)
    if (-not $boundaryValid) {
        return [pscustomobject]@{
            BoundaryValid = $false
            CoverageComplete = $false
            StartObservedAt = $startObservedAt
            EndObservedAt = $endObservedAt
            Usage = New-TokenRaderUsage
            InputCost = [double]0
            CachedCost = [double]0
            OutputCost = [double]0
            TotalCost = [double]0
            PricingComplete = $false
            CostComplete = $false
            UnknownModels = @()
            CountedEvents = [Int64]0
            FirstCountedAt = $null
            LastCountedAt = $null
            ProcessingMilliseconds = [double]0
            ObservedTokens = [Int64]0
            TotalTokens = [Int64]0
            UsedTokens = [Int64]0
            RemainingTokens = [Int64]0
            EstimateSource = ''
            CapacitySource = ''
            UsdEstimateSource = ''
            AverageUsdPerToken = [double]0
            EstimatedTotalUsd = [double]0
            ObservedCostUsd = [double]0
            EstimatedRemainingUsd = [double]0
            IdentityComplete = $false
            IdentitySources = @()
        }
    }

    $cacheKey = '{0}|{1}' -f $windowStartAt.UtcDateTime.Ticks, $endObservedAt.UtcDateTime.Ticks
    $aggregate = if ($null -ne $Cache -and $Cache.ContainsKey($cacheKey)) {
        $Cache[$cacheKey]
    } else {
        $value = [TokenRaderIndexer]::AggregateTimeRangeRecordsAtOffsets(
            $Connection, $EndOffsets, $startObservedAt, $endObservedAt,
            $Thresholds, $CancellationToken, $ProgressState)
        if ($null -ne $Cache) { $Cache[$cacheKey] = $value }
        $value
    }
    $priced = ConvertFrom-TokenRaderPricedAggregate -Aggregate $aggregate -PricingDocument $PricingDocument
    [Int64]$observedTokens = [Int64]$priced.Usage.Total
    $directUsed = if ($null -ne $EndWindow.PSObject.Properties['UsedTokens']) { $EndWindow.UsedTokens } else { $null }
    $directRemaining = if ($null -ne $EndWindow.PSObject.Properties['RemainingTokens']) { $EndWindow.RemainingTokens } else { $null }
    $directLimit = if ($null -ne $EndWindow.PSObject.Properties['LimitTokens']) { $EndWindow.LimitTokens } else { $null }
    if ($null -eq $directLimit -and $null -ne $directUsed -and $null -ne $directRemaining) {
        $directLimit = [Int64]$directUsed + [Int64]$directRemaining
    }
    [Int64]$totalTokens = 0
    [Int64]$usedTokens = 0
    [Int64]$remainingTokens = 0
    $estimateSource = ''
    if ($null -ne $directLimit -and [Int64]$directLimit -gt 0) {
        $totalTokens = [Int64]$directLimit
        $usedTokens = if ($null -ne $directUsed) { [Int64]$directUsed } else { [Int64][Math]::Round($totalTokens * ([double]$EndWindow.UsedPercent / 100.0)) }
        $remainingTokens = if ($null -ne $directRemaining) { [Int64]$directRemaining } else { [Math]::Max([Int64]0, $totalTokens - $usedTokens) }
        $estimateSource = 'direct_limit_tokens'
    } elseif ($observedTokens -gt 0 -and [double]$EndWindow.UsedPercent -gt 0) {
        $totalTokens = [Int64][Math]::Round($observedTokens * 100.0 / [double]$EndWindow.UsedPercent)
        if ($totalTokens -lt $observedTokens) { $totalTokens = $observedTokens }
        $usedTokens = $observedTokens
        $remainingTokens = [Math]::Max([Int64]0, $totalTokens - $observedTokens)
        $estimateSource = 'snapshot_token_estimate'
    }
    [double]$averageUsdPerToken = 0
    [double]$estimatedTotalUsd = 0
    [double]$estimatedRemainingUsd = 0
    $usdEstimateSource = ''
    if ([bool]$priced.PricingComplete -and $observedTokens -gt 0 -and $totalTokens -gt 0 -and [double]$priced.TotalCost -gt 0) {
        $averageUsdPerToken = [double]$priced.TotalCost / [double]$observedTokens
        $estimatedTotalUsd = $averageUsdPerToken * [double]$totalTokens
        $estimatedRemainingUsd = [Math]::Max(0.0, $estimatedTotalUsd - [double]$priced.TotalCost)
        $usdEstimateSource = if ($estimateSource -eq 'direct_limit_tokens') {
            'direct_limit_tokens_usd_estimate'
        } else { 'snapshot_window_usd_estimate' }
    }
    [pscustomobject]@{
        BoundaryValid = $true
        CoverageComplete = [bool]$coverageComplete
        StartObservedAt = $startObservedAt
        EndObservedAt = $endObservedAt
        Usage = $priced.Usage
        InputCost = [double]$priced.InputCost
        CachedCost = [double]$priced.CachedCost
        OutputCost = [double]$priced.OutputCost
        TotalCost = [double]$priced.TotalCost
        CacheCreationCost = [double]$priced.CacheCreationCost
        PricingComplete = [bool]$priced.PricingComplete
        CostComplete = [bool]$priced.CostComplete
        UnknownModels = @($priced.UnknownModels)
        CountedEvents = [Int64]$aggregate.CountedEvents
        FirstCountedAt = $aggregate.FirstCountedAt
        LastCountedAt = $aggregate.LastCountedAt
        StandardContextEvents = [Int64]$priced.StandardContextEvents
        LongContextEvents = [Int64]$priced.LongContextEvents
        StandardContextInput = [Int64]$priced.StandardContextInput
        LongContextInput = [Int64]$priced.LongContextInput
        LongContextOutput = [Int64]$priced.LongContextOutput
        LongContextExtraCost = [double]$priced.LongContextExtraCost
        CacheWriteObservable = [bool]$priced.CacheWriteObservable
        CostCoverage = [string]$priced.CostCoverage
        ProcessingMilliseconds = [double]$aggregate.ProcessingMilliseconds
        ObservedTokens = $observedTokens
        TotalTokens = $totalTokens
        UsedTokens = $usedTokens
        RemainingTokens = $remainingTokens
        EstimateSource = $usdEstimateSource
        CapacitySource = $estimateSource
        UsdEstimateSource = $usdEstimateSource
        AverageUsdPerToken = $averageUsdPerToken
        EstimatedTotalUsd = $estimatedTotalUsd
        ObservedCostUsd = [double]$priced.TotalCost
        EstimatedRemainingUsd = $estimatedRemainingUsd
        IdentityComplete = [bool]$aggregate.IdentityComplete
        IdentitySources = @($aggregate.IdentitySources)
        UnidentifiedEvents = [Int64]$aggregate.UnidentifiedEvents
    }
}

function Get-TokenRaderIndexedIntervalResult {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [hashtable]$BaselineSnapshots = $null,
        $EndOffsets = $null,
        $EndRevision = $null,
        $EndedAt = $null,
        [bool]$ScanRateLimits = $true,
        [string]$SessionsRoot = '',
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [hashtable]$ProgressState = $null
    )
    if ([string]::IsNullOrWhiteSpace($SessionsRoot)) { $SessionsRoot = [string]$Baseline.SessionsRoot }
    $ending = $null
    if ($null -eq $EndOffsets) {
        $ending = CaptureMeasurementEnd -Baseline $Baseline -ProgressState $ProgressState
        $EndOffsets = $ending.EndOffsets
        $EndRevision = $ending.EndRevision
    }
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $starts = ConvertTo-TokenRaderOffsetMap -Value $Baseline.StartOffsets
    $ends = ConvertTo-TokenRaderOffsetMap -Value $EndOffsets
    $startedAt = [DateTimeOffset]$Baseline.StartedAt
    $thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($PricingDocument.models)) {
        $threshold = if ($null -ne $entry.PSObject.Properties['longContextThreshold']) { [Int64]$entry.longContextThreshold } else { 0L }
        $id = [string]$entry.id
        if (-not [string]::IsNullOrWhiteSpace($id)) { $thresholds[$id] = $threshold }
        foreach ($alias in @($entry.aliases)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$alias)) { $thresholds[[string]$alias] = $threshold }
        }
    }
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '流式聚合区间记录'
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $aggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
        $index.Connection, $starts, $ends, $startedAt, $thresholds, $CancellationToken, $ProgressState)
    $priced = ConvertFrom-TokenRaderPricedAggregate -Aggregate $aggregate -PricingDocument $PricingDocument

    $endRateLimits = if ($null -ne $ending -and $null -ne $ending.EndRateLimits) { $ending.EndRateLimits }
                     elseif ($ScanRateLimits) { Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $index.Connection -EndOffsets $ends }
                     else { $null }
    $startRateLimits = if ($null -ne $Baseline.PSObject.Properties['StartRateLimits']) { $Baseline.StartRateLimits }
                       elseif ($null -ne $Baseline.PSObject.Properties['RateLimits']) { $Baseline.RateLimits }
                       else { $null }
    $quotaEvidence = $null
    if ($ScanRateLimits -and $null -ne $endRateLimits) {
        $quotaAggregateCache = @{}
        $quotaEvidence = [pscustomobject]@{
            FiveHour = Get-TokenRaderQuotaWindowEvidence `
                -StartWindow $(if ($null -ne $startRateLimits) { $startRateLimits.FiveHour } else { $null }) `
                -EndWindow $endRateLimits.FiveHour `
                -MainLastCountedAt $aggregate.LastCountedAt `
                -Connection $index.Connection `
                -EndOffsets $ends `
                -Thresholds $thresholds `
                -PricingDocument $PricingDocument `
                -CancellationToken $CancellationToken `
                -ProgressState $ProgressState `
                -Cache $quotaAggregateCache
            Weekly = Get-TokenRaderQuotaWindowEvidence `
                -StartWindow $(if ($null -ne $startRateLimits) { $startRateLimits.Weekly } else { $null }) `
                -EndWindow $endRateLimits.Weekly `
                -MainLastCountedAt $aggregate.LastCountedAt `
                -Connection $index.Connection `
                -EndOffsets $ends `
                -Thresholds $thresholds `
                -PricingDocument $PricingDocument `
                -CancellationToken $CancellationToken `
                -ProgressState $ProgressState `
                -Cache $quotaAggregateCache
        }
    }
    $modelList = @($priced.Models)
    $usage = $priced.Usage
    [pscustomobject]@{
        StartedAt = $startedAt
        EndedAt = if ($null -ne $ending) { $ending.EndedAt } elseif ($null -ne $EndedAt) { [DateTimeOffset]$EndedAt } else { [DateTimeOffset]::Now }
        Usage = $usage
        Models = $modelList
        ModelDisplay = [string]$priced.ModelDisplay
        ChangedSessions = [int]$aggregate.ChangedSessions
        Items = @($priced.Items)
        InputCost = [double]$priced.InputCost
        CachedCost = [double]$priced.CachedCost
        OutputCost = [double]$priced.OutputCost
        TotalCost = [double]$priced.TotalCost
        PricingComplete = [bool]$priced.PricingComplete
        CostComplete = [bool]$priced.CostComplete
        UnknownModels = @($priced.UnknownModels)
        StartRateLimits = $startRateLimits
        EndRateLimits = $endRateLimits
        RateLimits = $endRateLimits
        QuotaEvidence = $quotaEvidence
        RawEvents = [Int64]$aggregate.RawEvents
        CountedEvents = [Int64]$aggregate.CountedEvents
        DuplicateEventsDropped = [Int64]$aggregate.DuplicateEventsDropped
        InheritedEventsDropped = [Int64]$aggregate.InheritedEventsDropped
        BytesRead = [Int64]$aggregate.BytesRead
        ProcessedRows = [Int64]$aggregate.ProcessedRows
        ProcessingMilliseconds = [double]$aggregate.ProcessingMilliseconds
        FirstCountedAt = $aggregate.FirstCountedAt
        LastCountedAt = $aggregate.LastCountedAt
        StandardContextEvents = [Int64]$priced.StandardContextEvents
        LongContextEvents = [Int64]$priced.LongContextEvents
        StandardContextInput = [Int64]$priced.StandardContextInput
        LongContextInput = [Int64]$priced.LongContextInput
        LongContextOutput = [Int64]$priced.LongContextOutput
        LongContextExtraCost = [double]$priced.LongContextExtraCost
        CacheWriteObservable = [bool]$priced.CacheWriteObservable
        CostCoverage = [string]$priced.CostCoverage
        IndexRevision = if ($null -ne $EndRevision) { [Int64]$EndRevision } else { [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection) }
        ChangeRevision = if ($null -ne $ending) { [Int64]$ending.ChangeRevision } else { [Int64][TokenRaderIndexer]::GetChangeRevision($SessionsRoot) }
        Signature = 'index:' + $(if ($null -ne $EndRevision) { [string][Int64]$EndRevision } else { [string][Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection) })
        BaselineSnapshots = if ($null -ne $BaselineSnapshots) { $BaselineSnapshots } else { @{} }
        StartOffsets = $starts
        EndOffsets = $ends
    }
}

function Get-TokenRaderPricingCacheKey {
    param([Parameter(Mandatory = $true)]$PricingDocument)
    $modelParts = foreach ($entry in @($PricingDocument.models | Sort-Object id)) {
        $aliasValues = if ($null -ne $entry.PSObject.Properties['aliases']) { @($entry.aliases) } else { @() }
        $aliases = @($aliasValues | ForEach-Object {
            ([string]$_).Trim().ToLowerInvariant()
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ','
        @(
            [string]$entry.id,
            $aliases,
            [string]$entry.input,
            [string]$entry.cachedInput,
            [string]$entry.output,
            $(if ($null -ne $entry.PSObject.Properties['contextWindow']) { [string]$entry.contextWindow } else { '' }),
            $(if ($null -ne $entry.PSObject.Properties['longContextThreshold']) { [string]$entry.longContextThreshold } else { '' }),
            $(if ($null -ne $entry.PSObject.Properties['longContextInputMultiplier']) { [string]$entry.longContextInputMultiplier } else { '' }),
            $(if ($null -ne $entry.PSObject.Properties['longContextOutputMultiplier']) { [string]$entry.longContextOutputMultiplier } else { '' })
        ) -join ':'
    }
    return (@('usage-history-v5', [string]$PricingDocument.verifiedAt, [string]$PricingDocument.unitTokens, ($modelParts -join ';')) -join '|')
}

function ConvertFrom-TokenRaderUsageHistorySnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [bool]$FromCache = $true
    )
    $windowStart = [DateTimeOffset]::new([DateTime]::new([Int64]$Snapshot.WindowStartTicks, [DateTimeKind]::Utc))
    $windowEnd = [DateTimeOffset]::new([DateTime]::new([Int64]$Snapshot.WindowEndTicks, [DateTimeKind]::Utc))
    $computedAt = [DateTimeOffset]::new([DateTime]::new([Int64]$Snapshot.ComputedAtTicks, [DateTimeKind]::Utc))
    $models = if ([string]::IsNullOrWhiteSpace([string]$Snapshot.Models)) {
        @()
    } else {
        @(([string]$Snapshot.Models).Split([char]0x1F, [StringSplitOptions]::RemoveEmptyEntries))
    }
    $usage = New-TokenRaderUsage `
        -InputTokens ([Int64]$Snapshot.TotalInput) `
        -CachedTokens ([Int64]$Snapshot.TotalCached) `
        -OutputTokens ([Int64]$Snapshot.TotalOutput) `
        -ReasoningOutputTokens ([Int64]$Snapshot.TotalReasoning)
    $modelBreakdown = foreach ($modelSnapshot in @($Snapshot.ModelBreakdown)) {
        if ($null -eq $modelSnapshot) { continue }
        $modelUsage = New-TokenRaderUsage `
            -InputTokens ([Int64]$modelSnapshot.TotalInput) `
            -CachedTokens ([Int64]$modelSnapshot.TotalCached) `
            -OutputTokens ([Int64]$modelSnapshot.TotalOutput) `
            -ReasoningOutputTokens ([Int64]$modelSnapshot.TotalReasoning)
        [pscustomobject]@{
            Model = $(if ([string]::IsNullOrWhiteSpace([string]$modelSnapshot.Model)) { '未知模型' } else { [string]$modelSnapshot.Model })
            Usage = $modelUsage
            InputCost = [double]$modelSnapshot.InputCost
            CachedCost = [double]$modelSnapshot.CachedCost
            OutputCost = [double]$modelSnapshot.OutputCost
            TotalCost = [double]$modelSnapshot.InputCost + [double]$modelSnapshot.CachedCost + [double]$modelSnapshot.OutputCost
            PricingComplete = [bool]$modelSnapshot.PricingComplete
            CostComplete = [bool]$modelSnapshot.PricingComplete
            Events = [Int64]$modelSnapshot.Events
            CacheCreationTokens = [Int64]$modelSnapshot.CacheCreationTokens
            CacheWriteObservable = [bool]$modelSnapshot.CacheWriteObservable
            StandardContextEvents = [Int64]$modelSnapshot.StandardContextEvents
            LongContextEvents = [Int64]$modelSnapshot.LongContextEvents
            StandardContextInput = [Int64]$modelSnapshot.StandardContextInput
            LongContextInput = [Int64]$modelSnapshot.LongContextInput
            LongContextOutput = [Int64]$modelSnapshot.LongContextOutput
            CostCoverage = if ([bool]$modelSnapshot.CacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
        }
    }
    [pscustomobject]@{
        WindowStart = $windowStart
        WindowEnd = $windowEnd
        ComputedAt = $computedAt
        IndexRevision = [Int64]$Snapshot.IndexRevision
        Usage = $usage
        Models = $models
        ModelDisplay = [string]$Snapshot.ModelDisplay
        ModelBreakdown = @($modelBreakdown)
        InputCost = [double]$Snapshot.InputCost
        CachedCost = [double]$Snapshot.CachedCost
        OutputCost = [double]$Snapshot.OutputCost
        TotalCost = [double]$Snapshot.InputCost + [double]$Snapshot.CachedCost + [double]$Snapshot.OutputCost
        PricingComplete = [bool]$Snapshot.PricingComplete
        CostComplete = [bool]$Snapshot.PricingComplete
        RawEvents = [Int64]$Snapshot.RawEvents
        CountedEvents = [Int64]$Snapshot.CountedEvents
        DuplicateEventsDropped = [Int64]$Snapshot.DuplicateEventsDropped
        InheritedEventsDropped = [Int64]$Snapshot.InheritedEventsDropped
        ProcessedRows = [Int64]$Snapshot.ProcessedRows
        CacheCreationTokens = [Int64]$Snapshot.CacheCreationTokens
        CacheWriteObservable = [bool]$Snapshot.CacheWriteObservable
        CostCoverage = if ([bool]$Snapshot.CacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
        StandardContextEvents = [Int64]$Snapshot.StandardContextEvents
        LongContextEvents = [Int64]$Snapshot.LongContextEvents
        StandardContextInput = [Int64]$Snapshot.StandardContextInput
        LongContextInput = [Int64]$Snapshot.LongContextInput
        LongContextOutput = [Int64]$Snapshot.LongContextOutput
        LongContextExtraCost = [double]$Snapshot.LongContextExtraCost
        FromCache = $FromCache
    }
}

function Add-TokenRaderToolUsageToHistoryResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$Connection
    )
    $toolUsage = [TokenRaderIndexer]::AggregateToolUsage(
        $Connection, [DateTimeOffset]$Result.WindowStart, [DateTimeOffset]$Result.WindowEnd)
    if ($null -ne $Result.PSObject.Properties['ToolUsage']) {
        $Result.ToolUsage = $toolUsage
    } else {
        Add-Member -InputObject $Result -NotePropertyName ToolUsage -NotePropertyValue $toolUsage
    }
    return $Result
}

function Get-TokenRaderUsageHistoryWindow {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [ValidateRange(0, 6)][int]$DayOffset = 0,
        $AnchorAt = $null,
        [switch]$ForceRefresh,
        [switch]$PurgeExpired,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [hashtable]$ProgressState = $null
    )

    $anchor = if ($null -eq $AnchorAt) { [DateTimeOffset]::Now } else { [DateTimeOffset]$AnchorAt }
    # Second-aligned boundaries preserve an exact rolling-24-hour view while
    # avoiding one cache row per sub-second UI request. These are not
    # calendar-day buckets.
    $alignedAnchor = [DateTimeOffset]::new(
        $anchor.Year, $anchor.Month, $anchor.Day, $anchor.Hour, $anchor.Minute, $anchor.Second, $anchor.Offset)
    $windowEnd = $alignedAnchor.AddDays(-$DayOffset)
    $windowStart = $windowEnd.AddHours(-24)
    $startTicks = [Int64]$windowStart.UtcDateTime.Ticks
    $endTicks = [Int64]$windowEnd.UtcDateTime.Ticks
    $pricingKey = Get-TokenRaderPricingCacheKey -PricingDocument $PricingDocument
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '同步最新日志后冻结24小时边界'
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    # A history selection is itself a freshness boundary: do not rely on the
    # five-minute timer or a prior View Result having already consumed the file
    # watcher queue. The compiled catalog pass also catches delayed/lost file
    # notifications before the timestamp aggregate is evaluated.
    $index = Sync-TokenRaderMeasurementBoundary `
        -SessionsRoot $SessionsRoot `
        -ProgressState $ProgressState `
        -TimeoutSeconds 25
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(([string]$index.DbPath + '.lock'), 10000)
    try {
        $revision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
        if ($PurgeExpired) {
            $cutoffTicks = [Int64][DateTimeOffset]::Now.AddDays(-7).UtcDateTime.Ticks
            [void][TokenRaderIndexer]::PurgeUsageHistory($index.Connection, $cutoffTicks)
        }
        if (-not $ForceRefresh) {
            $cached = [TokenRaderIndexer]::GetUsageHistorySnapshot(
                $index.Connection, $startTicks, $endTicks, $revision, $pricingKey)
            if ($null -ne $cached) {
                $cachedResult = ConvertFrom-TokenRaderUsageHistorySnapshot -Snapshot $cached -FromCache $true
                return Add-TokenRaderToolUsageToHistoryResult -Result $cachedResult -Connection $index.Connection
            }
        }

        $thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($PricingDocument.models)) {
            $threshold = if ($null -ne $entry.PSObject.Properties['longContextThreshold']) { [Int64]$entry.longContextThreshold } else { 0L }
            $id = [string]$entry.id
            if (-not [string]::IsNullOrWhiteSpace($id)) { $thresholds[$id] = $threshold }
            foreach ($alias in @($entry.aliases)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$alias)) { $thresholds[[string]$alias] = $threshold }
            }
        }
        if ($null -ne $ProgressState) {
            $ProgressState.Stage = '读取24小时磁盘用量'
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }
        $aggregate = [TokenRaderIndexer]::AggregateTimeRangeRecords(
            $index.Connection, $windowStart, $windowEnd, $thresholds, $CancellationToken, $ProgressState)

        $unknownModels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [double]$inputCost = 0
        [double]$cachedCost = 0
        [double]$outputCost = 0
        [double]$cacheCreationCost = 0
        [double]$longContextExtraCost = 0
        $modelTotals = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($bucket in @($aggregate.Buckets)) {
            $bucketUsage = New-TokenRaderUsage -InputTokens $bucket.Input -CachedTokens $bucket.Cached -OutputTokens $bucket.Output -ReasoningOutputTokens $bucket.Reasoning
            $model = [string]$bucket.Model
            if (-not $modelTotals.ContainsKey($model)) {
                $modelTotals[$model] = [pscustomobject]@{
                    Model = $model
                    TotalInput = [Int64]0
                    TotalCached = [Int64]0
                    TotalOutput = [Int64]0
                    TotalReasoning = [Int64]0
                    InputCost = [double]0
                    CachedCost = [double]0
                    OutputCost = [double]0
                    PricingComplete = $true
                    Events = [Int64]0
                    CacheCreationTokens = [Int64]0
                    CacheWriteObservable = $true
                    StandardContextEvents = [Int64]0
                    LongContextEvents = [Int64]0
                    StandardContextInput = [Int64]0
                    LongContextInput = [Int64]0
                    LongContextOutput = [Int64]0
                }
            }
            $modelTotal = $modelTotals[$model]
            $modelTotal.TotalInput += [Int64]$bucket.Input
            $modelTotal.TotalCached += [Int64]$bucket.Cached
            $modelTotal.TotalOutput += [Int64]$bucket.Output
            $modelTotal.TotalReasoning += [Int64]$bucket.Reasoning
            $modelTotal.Events += [Int64]$bucket.Events
            $modelTotal.CacheCreationTokens += [Int64]$bucket.CacheCreationTokens
            if (-not [bool]$bucket.CacheWriteObservable) { $modelTotal.CacheWriteObservable = $false }
            if ([bool]$bucket.LongContext) {
                $modelTotal.LongContextEvents += [Int64]$bucket.Events
                $modelTotal.LongContextInput += [Int64]$bucket.Input
                $modelTotal.LongContextOutput += [Int64]$bucket.Output
            } else {
                $modelTotal.StandardContextEvents += [Int64]$bucket.Events
                $modelTotal.StandardContextInput += [Int64]$bucket.Input
            }
            # Keep history on the same per-call/bucket pricing path as the
            # interval and quota views.  In particular, cache creation tokens
            # are charged once at 1.25x and a >272K bucket receives the input
            # and output long-context multipliers exactly once.
            $cost = Get-TokenRaderCost -Usage $bucketUsage -Model $model -PricingDocument $PricingDocument `
                -Scope call -LongContextApplied ([bool]$bucket.LongContext) `
                -CacheCreationTokens ([Int64]$bucket.CacheCreationTokens) `
                -CacheWriteObservable ([bool]$bucket.CacheWriteObservable)
            if (-not [bool]$cost.Known) {
                [void]$unknownModels.Add($(if ([string]::IsNullOrWhiteSpace($model)) { '未知模型' } else { $model }))
                $modelTotal.PricingComplete = $false
                continue
            }
            $bucketInputCost = [double]$cost.InputCost
            $bucketCachedCost = [double]$cost.CachedCost
            $bucketOutputCost = [double]$cost.OutputCost
            $cacheCreationCost += [double]$cost.CacheCreationCost
            $inputCost += $bucketInputCost
            $cachedCost += $bucketCachedCost
            $outputCost += $bucketOutputCost
            if ([bool]$bucket.LongContext) {
                [double]$standardInputCost = if ([double]$cost.InputMultiplier -gt 0) { $bucketInputCost / [double]$cost.InputMultiplier } else { $bucketInputCost }
                [double]$standardCachedCost = if ([double]$cost.InputMultiplier -gt 0) { $bucketCachedCost / [double]$cost.InputMultiplier } else { $bucketCachedCost }
                [double]$standardOutputCost = if ([double]$cost.OutputMultiplier -gt 0) { $bucketOutputCost / [double]$cost.OutputMultiplier } else { $bucketOutputCost }
                $longContextExtraCost += ($bucketInputCost + $bucketCachedCost + $bucketOutputCost) -
                    ($standardInputCost + $standardCachedCost + $standardOutputCost)
            }
            $modelTotal.InputCost += $bucketInputCost
            $modelTotal.CachedCost += $bucketCachedCost
            $modelTotal.OutputCost += $bucketOutputCost
        }

        $models = @($aggregate.Models)
        $snapshot = New-Object TokenRaderUsageHistorySnapshot
        $snapshot.WindowStartTicks = $startTicks
        $snapshot.WindowEndTicks = $endTicks
        $snapshot.ComputedAtTicks = [Int64][DateTimeOffset]::UtcNow.UtcDateTime.Ticks
        $snapshot.IndexRevision = $revision
        $snapshot.PricingKey = $pricingKey
        $snapshot.TotalInput = [Int64]$aggregate.TotalInput
        $snapshot.TotalCached = [Int64]$aggregate.TotalCached
        $snapshot.TotalOutput = [Int64]$aggregate.TotalOutput
        $snapshot.TotalReasoning = [Int64]$aggregate.TotalReasoning
        $snapshot.InputCost = $inputCost
        $snapshot.CachedCost = $cachedCost
        $snapshot.OutputCost = $outputCost
        $snapshot.PricingComplete = ($unknownModels.Count -eq 0)
        $snapshot.ModelDisplay = if ($models.Count -eq 0) { '无调用' } elseif ($models.Count -eq 1) { [string]$models[0] } else { '{0} 个模型' -f $models.Count }
        $snapshot.Models = $models -join [char]0x1F
        $snapshot.RawEvents = [Int64]$aggregate.RawEvents
        $snapshot.CountedEvents = [Int64]$aggregate.CountedEvents
        $snapshot.DuplicateEventsDropped = [Int64]$aggregate.DuplicateEventsDropped
        $snapshot.InheritedEventsDropped = [Int64]$aggregate.InheritedEventsDropped
        $snapshot.ProcessedRows = [Int64]$aggregate.ProcessedRows
        $snapshot.CacheCreationTokens = [Int64]$aggregate.CacheCreationTokens
        $snapshot.CacheWriteObservable = [bool]$aggregate.CacheWriteObservable
        $snapshot.StandardContextEvents = [Int64]$aggregate.StandardContextEvents
        $snapshot.LongContextEvents = [Int64]$aggregate.LongContextEvents
        $snapshot.StandardContextInput = [Int64]$aggregate.StandardContextInput
        $snapshot.LongContextInput = [Int64]$aggregate.LongContextInput
        $snapshot.LongContextOutput = [Int64]$aggregate.LongContextOutput
        $snapshot.LongContextExtraCost = $longContextExtraCost
        $modelSnapshots = foreach ($modelTotal in @($modelTotals.Values | Sort-Object Model)) {
            $modelSnapshot = New-Object TokenRaderUsageHistoryModelSnapshot
            $modelSnapshot.Model = [string]$modelTotal.Model
            $modelSnapshot.TotalInput = [Int64]$modelTotal.TotalInput
            $modelSnapshot.TotalCached = [Int64]$modelTotal.TotalCached
            $modelSnapshot.TotalOutput = [Int64]$modelTotal.TotalOutput
            $modelSnapshot.TotalReasoning = [Int64]$modelTotal.TotalReasoning
            $modelSnapshot.InputCost = [double]$modelTotal.InputCost
            $modelSnapshot.CachedCost = [double]$modelTotal.CachedCost
            $modelSnapshot.OutputCost = [double]$modelTotal.OutputCost
            $modelSnapshot.PricingComplete = [bool]$modelTotal.PricingComplete
            $modelSnapshot.Events = [Int64]$modelTotal.Events
            $modelSnapshot.CacheCreationTokens = [Int64]$modelTotal.CacheCreationTokens
            $modelSnapshot.CacheWriteObservable = [bool]$modelTotal.CacheWriteObservable
            $modelSnapshot.StandardContextEvents = [Int64]$modelTotal.StandardContextEvents
            $modelSnapshot.LongContextEvents = [Int64]$modelTotal.LongContextEvents
            $modelSnapshot.StandardContextInput = [Int64]$modelTotal.StandardContextInput
            $modelSnapshot.LongContextInput = [Int64]$modelTotal.LongContextInput
            $modelSnapshot.LongContextOutput = [Int64]$modelTotal.LongContextOutput
            $modelSnapshot
        }
        $snapshot.ModelBreakdown = [TokenRaderUsageHistoryModelSnapshot[]]@($modelSnapshots)
        [TokenRaderIndexer]::SaveUsageHistorySnapshot($index.Connection, $snapshot)
        $freshResult = ConvertFrom-TokenRaderUsageHistorySnapshot -Snapshot $snapshot -FromCache $false
        return Add-TokenRaderToolUsageToHistoryResult -Result $freshResult -Connection $index.Connection
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

function Get-TokenRaderToolBackfillStatus {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $version = [string][TokenRaderIndexer]::GetSetting($index.Connection, 'tool_metadata_backfill_version')
    $completedAt = [string][TokenRaderIndexer]::GetSetting($index.Connection, 'tool_metadata_backfill_completed_at')
    [pscustomobject]@{
        Completed = $version -eq '1'
        Version = $version
        CompletedAt = $completedAt
    }
}

function Invoke-TokenRaderToolBackfill {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [ValidateRange(1, 7)][int]$Days = 7,
        [switch]$Force,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [hashtable]$ProgressState = $null
    )
    $index = Sync-TokenRaderMeasurementBoundary -SessionsRoot $SessionsRoot -ProgressState $ProgressState -TimeoutSeconds 25
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(([string]$index.DbPath + '.lock'), 10000)
    try {
        $currentVersion = [string][TokenRaderIndexer]::GetSetting($index.Connection, 'tool_metadata_backfill_version')
        if (-not $Force -and $currentVersion -eq '1') {
            return [pscustomobject]@{
                AlreadyCompleted = $true
                ProcessedFiles = 0
                CandidateFiles = 0
                DetectedRecords = 0L
                ScannedBytes = 0L
            }
        }
        $cutoffTicks = [Int64][DateTimeOffset]::Now.AddDays(-$Days).UtcDateTime.Ticks
        $nextRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection) + 1L
        $backfill = [TokenRaderIndexer]::BackfillRecentToolRecords(
            $index.Connection, $cutoffTicks, $nextRevision, $CancellationToken, $ProgressState)
        if ([Int64]$backfill.DetectedRecords -gt 0) {
            $index.IndexRevision = [Int64][TokenRaderIndexer]::IncrementIndexRevision($index.Connection)
        }
        $completedAt = [DateTimeOffset]::Now.ToString('o')
        [TokenRaderIndexer]::SetSetting($index.Connection, 'tool_metadata_backfill_version', '1')
        [TokenRaderIndexer]::SetSetting($index.Connection, 'tool_metadata_backfill_completed_at', $completedAt)
        [pscustomobject]@{
            AlreadyCompleted = $false
            ProcessedFiles = [int]$backfill.ProcessedFiles
            CandidateFiles = [int]$backfill.CandidateFiles
            DetectedRecords = [Int64]$backfill.DetectedRecords
            ScannedBytes = [Int64]$backfill.ScannedBytes
            CompletedAt = $completedAt
        }
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

function Remove-TokenRaderUsageHistory {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [ValidateRange(1, 30)][int]$RetentionDays = 7,
        $ReferenceAt = $null
    )
    $reference = if ($null -eq $ReferenceAt) { [DateTimeOffset]::Now } else { [DateTimeOffset]$ReferenceAt }
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(([string]$index.DbPath + '.lock'), 10000)
    try {
        $cutoff = [Int64]$reference.AddDays(-$RetentionDays).UtcDateTime.Ticks
        return [int][TokenRaderIndexer]::PurgeUsageHistory($index.Connection, $cutoff)
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

Export-ModuleMember -Function Get-TokenRaderPaths, Get-TokenRaderAccount, Get-TokenRaderSessionFiles, Get-TokenRaderSessionMetadata, Get-TokenRaderProjects, Get-TokenRaderUsageSnapshot, Get-TokenRaderLatestRateLimits, Get-TokenRaderPrices, Resolve-TokenRaderPrice, Get-TokenRaderCost, New-TokenRaderMeasurementBaseline, Get-TokenRaderIntervalResult, Get-TokenRaderProjectResult, Get-TokenRaderSessionResult, Get-TokenRaderQuotaEstimate, Get-TokenRaderSessionTreeSignature, Format-TokenRaderNumber, Format-TokenRaderUsd, Initialize-TokenRaderIndexer, Open-TokenRaderIndex, Close-TokenRaderIndex, New-TokenRaderIndex, Update-TokenRaderIndex, Clear-TokenRaderIndex, Remove-TokenRaderIndexHistory, Get-TokenRaderIndex, Get-TokenRaderIndexedSessionFiles, Get-TokenRaderIndexedProjects, Get-TokenRaderIndexRecords, ConvertFrom-TokenRaderIndexRecord, CaptureMeasurementBaseline, CaptureMeasurementEnd, QueryIntervalRecords, GetIndexRevision, Get-TokenRaderIndexedIntervalResult, Get-TokenRaderIndexedLatestRateLimits, Get-TokenRaderChangeRevision, Get-TokenRaderUsageHistoryWindow, Remove-TokenRaderUsageHistory, Get-TokenRaderToolBackfillStatus, Invoke-TokenRaderToolBackfill
