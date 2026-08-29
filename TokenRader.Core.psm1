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

function ConvertFrom-TokenRaderUsageTextFast {
    param([Parameter(Mandatory = $true)][string]$InnerText)

    # Builds the same usage object as New-TokenRaderUsage without the
    # function-call and [Math]::* overhead. Regex-extracted values are already
    # non-negative, so the original clamping rules reduce to a single check.
    $inputMatch = [regex]::Match($InnerText, '"input_tokens"\s*:\s*(\d+)')
    $cachedMatch = [regex]::Match($InnerText, '"cached_input_tokens"\s*:\s*(\d+)')
    $outputMatch = [regex]::Match($InnerText, '"output_tokens"\s*:\s*(\d+)')
    if (-not $inputMatch.Success -or -not $cachedMatch.Success -or -not $outputMatch.Success) { return $null }
    $reasoningMatch = [regex]::Match($InnerText, '"reasoning_output_tokens"\s*:\s*(\d+)')

    $inputTokens = [Int64]$inputMatch.Groups[1].Value
    $cachedTokens = [Int64]$cachedMatch.Groups[1].Value
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
    [pscustomobject]@{
        UsedPercent = $usedPercent
        RemainingPercent = 100.0 - $usedPercent
        WindowMinutes = $windowMinutes
        ResetsAt = $resetsAt
        ResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes $windowMinutes -ResetsAt $resetsAt
        ObservedAt = $ObservedAt
        SourceFile = $SourceFile
        PlanType = $PlanType
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

    [pscustomobject]@{
        FilePath = $FilePath
        Timestamp = $timestamp
        Model = $model
        PlanType = $planType
        RateLimits = $snapshotRateLimits
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

    $unitTokens = if ($null -ne $PricingDocument.PSObject.Properties['unitTokens'] -and [double]$PricingDocument.unitTokens -gt 0) {
        [double]$PricingDocument.unitTokens
    } else { 1000000.0 }
    $inputCost = ([double]$Usage.Uncached / $unitTokens) * [double]$price.input * $inputMultiplier
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
        LongContextApplied = $longContextApplied
        InputMultiplier = $inputMultiplier
        OutputMultiplier = $outputMultiplier
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
    [Int64]$rawEventCount = 0
    [Int64]$countedEventCount = 0
    [Int64]$duplicateEventCount = 0
    [Int64]$inheritedEventCount = 0
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
            if (-not $priceCache.ContainsKey($model)) {
                $priceCache[$model] = Resolve-TokenRaderPrice -Model $model -PricingDocument $PricingDocument
            }
            $price = $priceCache[$model]
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
        [bool]$CostComplete = $true
    )

    function Get-WindowEstimate {
        param($StartWindow, $EndWindow, [string]$StartPlanType, [string]$EndPlanType)
        if (-not $CostComplete -or $IntervalCost -le 0 -or $null -eq $StartWindow -or $null -eq $EndWindow) { return $null }
        if (-not $StartPlanType.Equals($EndPlanType, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        if ([int]$StartWindow.WindowMinutes -ne [int]$EndWindow.WindowMinutes) { return $null }
        if ($null -eq $StartWindow.ResetsAt -or $null -eq $EndWindow.ResetsAt) { return $null }
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
        if ($deltaPercent -le 0) { return $null }
        $totalUsd = $IntervalCost / ($deltaPercent / 100.0)
        [pscustomobject]@{
            DeltaPercent = $deltaPercent
            TotalUsd = $totalUsd
            UsedUsd = $totalUsd * ([double]$EndWindow.UsedPercent / 100.0)
            RemainingUsd = $totalUsd * ([double]$EndWindow.RemainingPercent / 100.0)
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
        FiveHour = if ($null -ne $StartRateLimits -and $null -ne $EndRateLimits) {
            Get-WindowEstimate $StartRateLimits.FiveHour $EndRateLimits.FiveHour (Get-WindowPlanType $StartRateLimits $StartRateLimits.FiveHour) (Get-WindowPlanType $EndRateLimits $EndRateLimits.FiveHour)
        } else { $null }
        Weekly = if ($null -ne $StartRateLimits -and $null -ne $EndRateLimits) {
            Get-WindowEstimate $StartRateLimits.Weekly $EndRateLimits.Weekly (Get-WindowPlanType $StartRateLimits $StartRateLimits.Weekly) (Get-WindowPlanType $EndRateLimits $EndRateLimits.Weekly)
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
    $conn = New-Object System.Data.SQLite.SQLiteConnection ('Data Source=' + $dbPath + ';Version=3;')
    $conn.Open()
    [TokenRaderIndexer]::CreateSchema($conn)
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

    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '读取索引游标'
        $ProgressState.ProcessedFiles = 0
        $ProgressState.TotalFiles = 0
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $conn = $Index.Connection
    $metadataTable = [TokenRaderIndexer]::CaptureFileCursorTable($conn)
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
    foreach ($row in @($metadataTable.Rows)) {
        $sessionId = [string]$row['session_id']
        if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
        $relationshipBySession[$sessionId.ToLowerInvariant()] = [pscustomobject]@{
            SessionId = $sessionId
            ParentThreadId = [string]$row['parent_thread_id']
            ForkedFromId = [string]$row['forked_from_id']
        }
    }

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
        [void]$workItems.Add([pscustomobject]@{
            File = $file
            Canonical = $canonical
            Key = $key
            KnownRow = $knownRow
            Metadata = $sessionMetadata
            Unchanged = $unchanged
        })
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
        $rootSessionId = & $resolveRoot $metadata
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
                $startOffset = 0L
            }

            $count = if ($completeOffset -gt $startOffset) {
                [TokenRaderIndexer]::ImportFile($conn, $canonical, $startOffset, $completeOffset, [string]$rootSessionId, $nextRevision)
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
            # parsed_offset is not advanced on failure; the changed path stays
            # eligible for a later reconciliation.
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
    if ($FullReconcile -or $null -ne $CandidateFiles) {
        foreach ($row in @($metadataTable.Rows)) {
            $path = [string]$row['path']
            $key = $path.ToLowerInvariant()
            $shouldCheck = if ($FullReconcile) { -not $seen.ContainsKey($key) } else { $candidatePaths.ContainsKey($key) }
            if (-not $shouldCheck -or (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $sessionId = [string]$row['session_id']
            if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = Get-TokenRaderSessionIdFromPath -FilePath $path }
            [void][TokenRaderIndexer]::DeleteTokenRecordsBySessionId($conn, $sessionId)
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
    $Index.IndexedFileCount = [int][TokenRaderIndexer]::GetFileCursorCount($conn)
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '同步完成'
        $ProgressState.ProcessedFiles = $ProgressState.TotalFiles
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    return $Index
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
        Close-TokenRaderIndex
        foreach ($suffix in @('', '-wal', '-shm')) {
            $target = $dbPath + $suffix
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
        }
    }
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    return Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -FullReconcile
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
        [hashtable]$ProgressState
    )

    $index = $script:TokenRaderIndex
    if ($null -eq $index -or $null -eq $index.Connection) {
        $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    }
    $watcherWasActive = [TokenRaderIndexer]::IsWatcherActive($SessionsRoot)
    if (-not $watcherWasActive) { [TokenRaderIndexer]::StartWatcher($SessionsRoot) }
    if ($PSBoundParameters.ContainsKey('CandidateFiles')) {
        return Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -CandidateFiles $CandidateFiles -ProgressState $ProgressState
    }
    if ($FullReconcile -or [bool]$index.IsNew -or (-not $watcherWasActive -and (Test-Path -LiteralPath $SessionsRoot)) -or
        [TokenRaderIndexer]::ConsumeWatcherOverflow($SessionsRoot)) {
        return Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -FullReconcile -ProgressState $ProgressState
    }
    $changedPaths = @([TokenRaderIndexer]::DrainChangedPaths($SessionsRoot))
    if ($changedPaths.Count -gt 0) {
        return Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -CandidateFiles $changedPaths -ProgressState $ProgressState
    }
    $index.IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
    $index.ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision($SessionsRoot)
    $index.LastImportedFiles = 0
    $index.LastImportedRecords = 0
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '同步完成'
        $ProgressState.ProcessedFiles = 0
        $ProgressState.TotalFiles = 0
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    return $index
}

<#
.SYNOPSIS
    删除可重建的本地索引；不会修改 Codex 原始日志。
#>
function Clear-TokenRaderIndex {
    Close-TokenRaderIndex
    $dbPath = Get-TokenRaderIndexerDbPath
    foreach ($suffix in @('', '-wal', '-shm')) {
        $target = $dbPath + $suffix
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
    }
    [GC]::Collect()
}

function Remove-TokenRaderIndexHistory {
    param([ValidateRange(1, 36500)][int]$Days = 30)

    $index = $script:TokenRaderIndex
    if ($null -eq $index -or $null -eq $index.Connection) {
        throw '本地索引尚未打开。'
    }
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
            ResetIdentity = ''
        }
        $weekly.ResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes ([int]$weekly.WindowMinutes) -ResetsAt $weekly.ResetsAt
    }

    $rateLimits = [pscustomobject]@{
        ObservedAt = $timestamp
        PlanType = $planType
        FiveHour = $fiveHour
        Weekly = $weekly
    }

    [pscustomobject]@{
        FilePath = $FilePath
        Timestamp = $timestamp
        Model = [string]$Row['model']
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
        ContextWindow = [Int64]0
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
    foreach ($row in @($Table.Rows)) {
        $record = ConvertFrom-TokenRaderIndexRecord -Row $row
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

function CaptureMeasurementBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        $PricingDocument = $null,
        [string]$AccountIdentity = ''
    )
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $gate = [TokenRaderIndexer]::AcquireIndexGate($SessionsRoot)
    try {
        $index = Update-TokenRaderIndex -SessionsRoot $SessionsRoot
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
        $index = Update-TokenRaderIndex -SessionsRoot $sessionsRoot -ProgressState $ProgressState
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

    $unknownModels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [double]$inputCost = 0
    [double]$cachedCost = 0
    [double]$outputCost = 0
    $priceCache = @{}
    $unitTokens = if ($null -ne $PricingDocument.PSObject.Properties['unitTokens'] -and [double]$PricingDocument.unitTokens -gt 0) {
        [double]$PricingDocument.unitTokens
    } else { 1000000.0 }
    $items = foreach ($bucket in @($aggregate.Buckets)) {
        $bucketUsage = New-TokenRaderUsage -InputTokens $bucket.Input -CachedTokens $bucket.Cached -OutputTokens $bucket.Output -ReasoningOutputTokens $bucket.Reasoning
        $model = [string]$bucket.Model
        if (-not $priceCache.ContainsKey($model)) { $priceCache[$model] = Resolve-TokenRaderPrice -Model $model -PricingDocument $PricingDocument }
        $price = $priceCache[$model]
        $known = $null -ne $price
        [double]$bucketInputCost = 0
        [double]$bucketCachedCost = 0
        [double]$bucketOutputCost = 0
        [double]$inputMultiplier = 1.0
        [double]$outputMultiplier = 1.0
        if ($known) {
            if ([bool]$bucket.LongContext) {
                $inputMultiplier = if ($null -ne $price.PSObject.Properties['longContextInputMultiplier']) { [double]$price.longContextInputMultiplier } else { 2.0 }
                $outputMultiplier = if ($null -ne $price.PSObject.Properties['longContextOutputMultiplier']) { [double]$price.longContextOutputMultiplier } else { 1.5 }
            }
            $bucketInputCost = ([double]$bucketUsage.Uncached / $unitTokens) * [double]$price.input * $inputMultiplier
            $bucketCachedCost = ([double]$bucketUsage.Cached / $unitTokens) * [double]$price.cachedInput * $inputMultiplier
            $bucketOutputCost = ([double]$bucketUsage.Output / $unitTokens) * [double]$price.output * $outputMultiplier
            $inputCost += $bucketInputCost
            $cachedCost += $bucketCachedCost
            $outputCost += $bucketOutputCost
        } else {
            [void]$unknownModels.Add($(if ([string]::IsNullOrWhiteSpace($model)) { '未知模型' } else { $model }))
        }
        [pscustomobject]@{
            Model = $model
            LongContext = [bool]$bucket.LongContext
            Usage = $bucketUsage
            Events = [Int64]$bucket.Events
            Cost = [pscustomobject]@{
                Known = $known; Model = $model; Price = $price
                InputCost = $bucketInputCost; CachedCost = $bucketCachedCost; OutputCost = $bucketOutputCost
                TotalCost = $bucketInputCost + $bucketCachedCost + $bucketOutputCost
                LongContextApplied = [bool]$bucket.LongContext
                InputMultiplier = $inputMultiplier
                OutputMultiplier = $outputMultiplier
            }
        }
    }

    $endRateLimits = if ($null -ne $ending -and $null -ne $ending.EndRateLimits) { $ending.EndRateLimits }
                     elseif ($ScanRateLimits) { Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $index.Connection -EndOffsets $ends }
                     else { $null }
    $startRateLimits = if ($null -ne $Baseline.PSObject.Properties['StartRateLimits']) { $Baseline.StartRateLimits }
                       elseif ($null -ne $Baseline.PSObject.Properties['RateLimits']) { $Baseline.RateLimits }
                       else { $null }
    $modelList = @($aggregate.Models)
    $usage = New-TokenRaderUsage -InputTokens $aggregate.TotalInput -CachedTokens $aggregate.TotalCached -OutputTokens $aggregate.TotalOutput -ReasoningOutputTokens $aggregate.TotalReasoning
    $pricingComplete = $unknownModels.Count -eq 0
    [pscustomobject]@{
        StartedAt = $startedAt
        EndedAt = if ($null -ne $ending) { $ending.EndedAt } elseif ($null -ne $EndedAt) { [DateTimeOffset]$EndedAt } else { [DateTimeOffset]::Now }
        Usage = $usage
        Models = $modelList
        ModelDisplay = if ($modelList.Count -eq 0) { '等待模型调用' } elseif ($modelList.Count -eq 1) { $modelList[0] } else { '{0} 个模型' -f $modelList.Count }
        ChangedSessions = [int]$aggregate.ChangedSessions
        Items = @($items)
        InputCost = $inputCost
        CachedCost = $cachedCost
        OutputCost = $outputCost
        TotalCost = $inputCost + $cachedCost + $outputCost
        PricingComplete = $pricingComplete
        CostComplete = $pricingComplete
        UnknownModels = @($unknownModels | Sort-Object)
        StartRateLimits = $startRateLimits
        EndRateLimits = $endRateLimits
        RateLimits = $endRateLimits
        RawEvents = [Int64]$aggregate.RawEvents
        CountedEvents = [Int64]$aggregate.CountedEvents
        DuplicateEventsDropped = [Int64]$aggregate.DuplicateEventsDropped
        InheritedEventsDropped = [Int64]$aggregate.InheritedEventsDropped
        BytesRead = [Int64]$aggregate.BytesRead
        ProcessedRows = [Int64]$aggregate.ProcessedRows
        ProcessingMilliseconds = [double]$aggregate.ProcessingMilliseconds
        IndexRevision = if ($null -ne $EndRevision) { [Int64]$EndRevision } else { [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection) }
        ChangeRevision = if ($null -ne $ending) { [Int64]$ending.ChangeRevision } else { [Int64][TokenRaderIndexer]::GetChangeRevision($SessionsRoot) }
        Signature = 'index:' + $(if ($null -ne $EndRevision) { [string][Int64]$EndRevision } else { [string][Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection) })
        BaselineSnapshots = if ($null -ne $BaselineSnapshots) { $BaselineSnapshots } else { @{} }
        StartOffsets = $starts
        EndOffsets = $ends
    }
}

Export-ModuleMember -Function Get-TokenRaderPaths, Get-TokenRaderAccount, Get-TokenRaderSessionFiles, Get-TokenRaderSessionMetadata, Get-TokenRaderProjects, Get-TokenRaderUsageSnapshot, Get-TokenRaderLatestRateLimits, Get-TokenRaderPrices, Resolve-TokenRaderPrice, Get-TokenRaderCost, New-TokenRaderMeasurementBaseline, Get-TokenRaderIntervalResult, Get-TokenRaderProjectResult, Get-TokenRaderSessionResult, Get-TokenRaderQuotaEstimate, Get-TokenRaderSessionTreeSignature, Format-TokenRaderNumber, Format-TokenRaderUsd, Initialize-TokenRaderIndexer, Open-TokenRaderIndex, Close-TokenRaderIndex, New-TokenRaderIndex, Update-TokenRaderIndex, Clear-TokenRaderIndex, Remove-TokenRaderIndexHistory, Get-TokenRaderIndex, Get-TokenRaderIndexedSessionFiles, Get-TokenRaderIndexedProjects, Get-TokenRaderIndexRecords, ConvertFrom-TokenRaderIndexRecord, CaptureMeasurementBaseline, CaptureMeasurementEnd, QueryIntervalRecords, GetIndexRevision, Get-TokenRaderIndexedIntervalResult, Get-TokenRaderIndexedLatestRateLimits, Get-TokenRaderChangeRevision
