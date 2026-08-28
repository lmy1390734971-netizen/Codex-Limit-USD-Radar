using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Data;
using System.Data.SQLite;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

/// <summary>
/// 磁盘 SQLite 索引引擎。将 Codex 会话日志（JSONL）中的 token 记录解析后
/// 写入项目 data/private/index/index.db，后续所有查询走 SQL，
/// 数据在磁盘而非内存，进程内存保持恒定。
///
/// 编译：csc /target:library /reference:System.Web.Extensions.dll /reference:System.Data.SQLite.dll /optimize+ ...
/// </summary>
public static class TokenRaderIndexer
{
    private sealed class WatchState : IDisposable
    {
        public readonly ConcurrentDictionary<string, byte> ChangedPaths =
            new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
        public readonly FileSystemWatcher Watcher;
        public long ChangeRevision;
        public int Overflowed;

        public WatchState(string root)
        {
            Watcher = new FileSystemWatcher(root, "*.jsonl");
            Watcher.IncludeSubdirectories = true;
            Watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size;
            Watcher.InternalBufferSize = 64 * 1024;
            Watcher.Changed += OnChanged;
            Watcher.Created += OnChanged;
            Watcher.Deleted += OnChanged;
            Watcher.Renamed += OnRenamed;
            Watcher.Error += OnError;
            Watcher.EnableRaisingEvents = true;
        }

        private void Enqueue(string path)
        {
            if (string.IsNullOrWhiteSpace(path) ||
                !string.Equals(Path.GetExtension(path), ".jsonl", StringComparison.OrdinalIgnoreCase)) return;
            ChangedPaths[GetCanonicalPath(path)] = 0;
            Interlocked.Increment(ref ChangeRevision);
        }

        private void OnChanged(object sender, FileSystemEventArgs args) { Enqueue(args.FullPath); }
        private void OnRenamed(object sender, RenamedEventArgs args)
        {
            Enqueue(args.OldFullPath);
            Enqueue(args.FullPath);
        }
        private void OnError(object sender, ErrorEventArgs args)
        {
            Interlocked.Exchange(ref Overflowed, 1);
            Interlocked.Increment(ref ChangeRevision);
        }

        public void Dispose()
        {
            Watcher.EnableRaisingEvents = false;
            Watcher.Changed -= OnChanged;
            Watcher.Created -= OnChanged;
            Watcher.Deleted -= OnChanged;
            Watcher.Renamed -= OnRenamed;
            Watcher.Error -= OnError;
            Watcher.Dispose();
        }
    }

    private static readonly object _watcherGate = new object();
    private static readonly Dictionary<string, WatchState> _watchers =
        new Dictionary<string, WatchState>(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, object> _indexGates =
        new ConcurrentDictionary<string, object>(StringComparer.OrdinalIgnoreCase);

    private sealed class MonitorReleaser : IDisposable
    {
        private object _gate;
        public MonitorReleaser(object gate) { _gate = gate; }
        public void Dispose()
        {
            object gate = Interlocked.Exchange(ref _gate, null);
            if (gate != null) Monitor.Exit(gate);
        }
    }

    /// <summary>
    /// Serializes drain/import/cursor capture sequences across PowerShell
    /// runspaces. Monitor is re-entrant, so a capture may safely call the
    /// normal update function while holding this gate.
    /// </summary>
    public static IDisposable AcquireIndexGate(string sessionsRoot)
    {
        string root = string.IsNullOrWhiteSpace(sessionsRoot)
            ? "__default__"
            : GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        object gate = _indexGates.GetOrAdd(root, delegate(string ignored) { return new object(); });
        Monitor.Enter(gate);
        return new MonitorReleaser(gate);
    }

    /// <summary>为会话目录建立一次性递归变化监视；重复调用会复用现有监视器。</summary>
    public static void StartWatcher(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot) || !Directory.Exists(sessionsRoot)) return;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        lock (_watcherGate)
        {
            if (_watchers.ContainsKey(root)) return;
            _watchers[root] = new WatchState(root);
        }
    }

    /// <summary>取出并清空本批次新增、修改、删除或重命名的 JSONL 路径。</summary>
    public static string[] DrainChangedPaths(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return new string[0];
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        WatchState state;
        lock (_watcherGate) { if (!_watchers.TryGetValue(root, out state)) return new string[0]; }
        var paths = new List<string>();
        foreach (string path in state.ChangedPaths.Keys)
        {
            byte ignored;
            if (state.ChangedPaths.TryRemove(path, out ignored)) paths.Add(path);
        }
        paths.Sort(StringComparer.OrdinalIgnoreCase);
        return paths.ToArray();
    }

    public static long GetChangeRevision(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return 0L;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        WatchState state;
        lock (_watcherGate) { if (!_watchers.TryGetValue(root, out state)) return 0L; }
        return Interlocked.Read(ref state.ChangeRevision);
    }

    public static bool IsWatcherActive(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return false;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        lock (_watcherGate) { return _watchers.ContainsKey(root); }
    }

    /// <summary>读取并清除监视器溢出标志；为 true 时调用方应完整核对目录元数据。</summary>
    public static bool ConsumeWatcherOverflow(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return false;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        WatchState state;
        lock (_watcherGate) { if (!_watchers.TryGetValue(root, out state)) return false; }
        return Interlocked.Exchange(ref state.Overflowed, 0) != 0;
    }

    public static void StopWatcher(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        WatchState state = null;
        lock (_watcherGate)
        {
            if (_watchers.TryGetValue(root, out state)) _watchers.Remove(root);
        }
        if (state != null) state.Dispose();
    }

    // ── Schema ──────────────────────────────────────────────────────────

    public static void CreateSchema(SQLiteConnection db)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "CREATE TABLE IF NOT EXISTS file_metadata (path TEXT PRIMARY KEY, length INTEGER NOT NULL, last_write_ticks INTEGER NOT NULL, parsed_offset INTEGER NOT NULL DEFAULT 0, session_id TEXT NOT NULL DEFAULT '', cwd TEXT NOT NULL DEFAULT '', parent_thread_id TEXT NOT NULL DEFAULT '', forked_from_id TEXT NOT NULL DEFAULT '', content_retained INTEGER NOT NULL DEFAULT 1, root_session_id TEXT NOT NULL DEFAULT '')";
            cmd.ExecuteNonQuery();

            // Existing installations may have a four-column file_metadata table.
            // ALTER TABLE is intentionally additive so the on-disk index remains
            // readable and existing rows retain their offsets and timestamps.
            EnsureFileMetadataColumn(db, "session_id", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "cwd", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "parent_thread_id", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "forked_from_id", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "content_retained", "INTEGER NOT NULL DEFAULT 1");
            EnsureFileMetadataColumn(db, "root_session_id", "TEXT NOT NULL DEFAULT ''");

            cmd.CommandText = "CREATE TABLE IF NOT EXISTS token_records (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, timestamp TEXT NOT NULL, model TEXT NOT NULL DEFAULT '', total_input INTEGER NOT NULL, total_cached INTEGER NOT NULL, total_output INTEGER NOT NULL, total_reasoning INTEGER NOT NULL DEFAULT 0, call_input INTEGER NOT NULL, call_cached INTEGER NOT NULL, call_output INTEGER NOT NULL, call_reasoning INTEGER NOT NULL DEFAULT 0, fingerprint TEXT NOT NULL DEFAULT '', five_hour_used REAL, five_hour_window INTEGER, five_hour_resets INTEGER, weekly_used REAL, weekly_window INTEGER, weekly_resets INTEGER, plan_type TEXT NOT NULL DEFAULT '', source_path TEXT NOT NULL DEFAULT '', source_offset_end INTEGER NOT NULL DEFAULT 0, root_session_id TEXT NOT NULL DEFAULT '', index_revision INTEGER NOT NULL DEFAULT 0)";
            cmd.ExecuteNonQuery();

            // New columns are additive so databases created by older builds
            // remain readable. SQLite applies the declared defaults to rows
            // already present when an ALTER TABLE is performed.
            EnsureTokenRecordColumn(db, "source_path", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "source_offset_end", "INTEGER NOT NULL DEFAULT 0");
            EnsureTokenRecordColumn(db, "root_session_id", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "index_revision", "INTEGER NOT NULL DEFAULT 0");

            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_session ON token_records(session_id)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_timestamp ON token_records(timestamp)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_model ON token_records(model)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_source_offset ON token_records(source_path, source_offset_end)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_root_session ON token_records(root_session_id, timestamp)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_file_metadata_last_write ON file_metadata(last_write_ticks)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_file_metadata_session ON file_metadata(session_id)";
            cmd.ExecuteNonQuery();

            cmd.CommandText = "CREATE TABLE IF NOT EXISTS index_settings (key TEXT PRIMARY KEY, value TEXT)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "INSERT OR IGNORE INTO index_settings (key, value) VALUES ('IndexRevision', '0')";
            cmd.ExecuteNonQuery();
        }
    }

    // ── Import ──────────────────────────────────────────────────────────

    private static readonly Regex _turnContextModel = new Regex(
        @"""type""\s*:\s*""turn_context"".*?""model""\s*:\s*""([^""]+)""",
        RegexOptions.Compiled);

    private static readonly Regex _sessionIdFromPath = new Regex(
        @"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$",
        RegexOptions.Compiled);

    private static readonly JavaScriptSerializer _json = new JavaScriptSerializer();

    /// <summary>增量解析一个 JSONL 文件，插入 SQLite，返回新记录数。</summary>
    public static int ImportFile(SQLiteConnection db, string filePath, long startOffset)
    {
        return ImportFile(db, filePath, startOffset, long.MaxValue, null, null);
    }

    /// <summary>解析指定字节边界内的 JSONL，避免并发追加越过冻结边界。</summary>
    public static int ImportFile(SQLiteConnection db, string filePath, long startOffset, long endOffset)
    {
        return ImportFile(db, filePath, startOffset, endOffset, null, null);
    }

    /// <summary>
    /// 解析指定范围，并允许调用方显式指定任务树根会话。该重载保留
    /// 与旧索引器相同的参数顺序，index_revision 仍使用当前索引 revision。
    /// </summary>
    public static int ImportFile(SQLiteConnection db, string filePath, long startOffset, long endOffset, string rootSessionId)
    {
        return ImportFile(db, filePath, startOffset, endOffset, rootSessionId, null);
    }

    /// <summary>
    /// 解析指定范围，并将记录标记为调用方捕获的 index revision。导入本身
    /// 不递增 revision；调用方应在导入事务成功后显式调用 IncrementIndexRevision。
    /// </summary>
    public static int ImportFile(SQLiteConnection db, string filePath, long startOffset, long endOffset, string rootSessionId, long indexRevision)
    {
        return ImportFile(db, filePath, startOffset, endOffset, rootSessionId, (long?)indexRevision);
    }

    private static int ImportFile(SQLiteConnection db, string filePath, long startOffset, long endOffset, string rootSessionId, long? explicitIndexRevision)
    {
        int count = 0;
        string sessionId = ExtractSessionId(filePath);
        string effectiveRootSessionId = string.IsNullOrWhiteSpace(rootSessionId) ? sessionId : rootSessionId;
        string sourcePath = GetCanonicalPath(filePath);
        long indexRevision = explicitIndexRevision.HasValue
            ? Math.Max(0L, explicitIndexRevision.Value)
            : GetIndexRevision(db);

        // Read this before opening the import transaction: the lookup command
        // intentionally uses the connection's normal transaction context.
        string inheritedModel = GetLatestSessionModel(db, sessionId);

        using (var tx = db.BeginTransaction())
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "INSERT INTO token_records (session_id, timestamp, model, total_input, total_cached, total_output, total_reasoning, call_input, call_cached, call_output, call_reasoning, fingerprint, five_hour_used, five_hour_window, five_hour_resets, weekly_used, weekly_window, weekly_resets, plan_type, source_path, source_offset_end, root_session_id, index_revision) VALUES (@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,@p9,@p10,@p11,@p12,@p13,@p14,@p15,@p16,@p17,@p18,@p19,@p20,@p21,@p22,@p23)";
            var p = new SQLiteParameter[23];
            for (int i = 0; i < p.Length; i++)
            {
                var prm = new SQLiteParameter("@p" + (i + 1));
                cmd.Parameters.Add(prm);
                p[i] = prm;
            }

            using (var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                long safeStart = Math.Max(0L, startOffset);
                long requestedEnd = endOffset < 0L ? 0L : endOffset;
                long effectiveEnd = Math.Min(fs.Length, requestedEnd);
                if (safeStart >= effectiveEnd) { tx.Commit(); return 0; }

                bool skipPartialLine = false;
                if (safeStart > 0L)
                {
                    fs.Seek(safeStart - 1L, SeekOrigin.Begin);
                    int previousByte = fs.ReadByte();
                    skipPartialLine = previousByte != '\n' && previousByte != '\r';
                }

                // StreamReader is convenient but buffers past the current line,
                // so its BaseStream.Position cannot identify a JSONL line end.
                // The byte reader below reports the exact UTF-8 end offset,
                // including the newline, for every inserted token record.
                using (var lineReader = new Utf8JsonlLineReader(fs, safeStart, effectiveEnd))
                {
                    if (skipPartialLine)
                    {
                        string discarded; long discardedEnd; bool discardedTerminated;
                        lineReader.ReadLine(out discarded, out discardedEnd, out discardedTerminated);
                    }

                    // An incremental import starts in the middle of a JSONL file,
                    // where the preceding turn_context is not available. Inherit
                    // the latest non-empty model already indexed for this session;
                    // a later turn_context in the appended segment still wins.
                    string currentModel = inheritedModel;
                    string line; long lineEndOffset; bool lineTerminated;
                    while (lineReader.ReadLine(out line, out lineEndOffset, out lineTerminated))
                    {
                        // Match the previous importer: an unterminated final line
                        // is a still-growing JSON record and must wait for the next
                        // refresh before it can enter the index.
                        if (!lineTerminated) break;
                        if (string.IsNullOrWhiteSpace(line)) continue;
                        line = line.TrimStart('\uFEFF');

                        if (line.Contains("turn_context"))
                        {
                            var m = _turnContextModel.Match(line);
                            if (m.Success) currentModel = m.Groups[1].Value;
                            continue;
                        }
                        if (!line.Contains("token_count")) continue;

                        try
                        {
                            var record = _json.DeserializeObject(line) as Dictionary<string, object>;
                            if (record == null) continue;
                            string type = record.ContainsKey("type") ? (record["type"] as string ?? "") : "";
                            var payload = GetDict(record, "payload");
                            if (payload == null) continue;
                            bool isTokenRecord = type == "token_count" ||
                                (type == "event_msg" && GetString(payload, "type") == "token_count");
                            if (!isTokenRecord) continue;
                            var info = GetDict(payload, "info");
                            if (info == null) continue;
                            var total = GetDict(info, "total_token_usage");
                            var last = GetDict(info, "last_token_usage");
                            if (total == null || last == null) continue;

                            long totalInput = GetInt64(total, "input_tokens");
                            long totalCached = GetInt64(total, "cached_input_tokens");
                            long totalOutput = GetInt64(total, "output_tokens");
                            long totalReasoning = GetInt64(total, "reasoning_output_tokens");
                            long callInput = GetInt64(last, "input_tokens");
                            long callCached = GetInt64(last, "cached_input_tokens");
                            long callOutput = GetInt64(last, "output_tokens");
                            long callReasoning = GetInt64(last, "reasoning_output_tokens");
                            if (totalCached > totalInput) totalCached = totalInput;
                            if (callCached > callInput) callCached = callInput;

                            string fingerprint = string.Format("{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}",
                                totalInput, totalCached, totalOutput, totalReasoning,
                                callInput, callCached, callOutput, callReasoning);

                            double? fiveHourUsed = null; int? fiveHourWindow = null; long? fiveHourResets = null;
                            double? weeklyUsed = null; int? weeklyWindow = null; long? weeklyResets = null;
                            string planType = "";
                            var rateLimits = GetDict(payload, "rate_limits");
                            if (rateLimits != null)
                            {
                                planType = GetString(rateLimits, "plan_type") ?? "";
                                DateTimeOffset observedAt;
                                bool hasObservedAt = TryGetObservedAt(record, out observedAt);
                                foreach (string key in new[] { "primary", "secondary" })
                                {
                                    var win = GetDict(rateLimits, key);
                                    if (win == null) continue;
                                    double used = GetDouble(win, "used_percent");
                                    int winMin = (int)GetInt64(win, "window_minutes");
                                    long resetSeconds;
                                    long? normalizedResets = TryGetResetUnixSeconds(win, hasObservedAt ? (DateTimeOffset?)observedAt : null, out resetSeconds)
                                        ? (long?)resetSeconds
                                        : null;
                                    if (winMin >= 240 && winMin <= 360)
                                    { fiveHourUsed = ClampPercent(used); fiveHourWindow = winMin; fiveHourResets = normalizedResets; }
                                    else if (winMin >= 9000 && winMin <= 11520)
                                    { weeklyUsed = ClampPercent(used); weeklyWindow = winMin; weeklyResets = normalizedResets; }
                                }
                            }

                            p[0].Value = sessionId; p[1].Value = GetString(record, "timestamp") ?? ""; p[2].Value = currentModel;
                            p[3].Value = totalInput; p[4].Value = totalCached; p[5].Value = totalOutput; p[6].Value = totalReasoning;
                            p[7].Value = callInput; p[8].Value = callCached; p[9].Value = callOutput; p[10].Value = callReasoning;
                            p[11].Value = fingerprint;
                            p[12].Value = (object)fiveHourUsed ?? DBNull.Value; p[13].Value = (object)fiveHourWindow ?? DBNull.Value;
                            p[14].Value = (object)fiveHourResets ?? DBNull.Value;
                            p[15].Value = (object)weeklyUsed ?? DBNull.Value; p[16].Value = (object)weeklyWindow ?? DBNull.Value;
                            p[17].Value = (object)weeklyResets ?? DBNull.Value;
                            p[18].Value = planType;
                            p[19].Value = sourcePath;
                            p[20].Value = lineEndOffset;
                            p[21].Value = effectiveRootSessionId;
                            p[22].Value = indexRevision;
                            cmd.ExecuteNonQuery();
                            count++;
                        }
                        catch { continue; }
                    }
                }
            }
            tx.Commit();
        }
        return count;
    }

    // ── Queries ─────────────────────────────────────────────────────────

    /// <summary>获取会话最新 token 快照。</summary>
    public static DataTable QuerySessionSnapshot(SQLiteConnection db, string sessionId)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT * FROM token_records WHERE session_id = @p ORDER BY timestamp DESC LIMIT 1";
            cmd.Parameters.AddWithValue("@p", sessionId);
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    /// <summary>获取时间段内全部记录。</summary>
    public static DataTable QueryTimeRange(SQLiteConnection db, string startTs, string endTs)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT * FROM token_records WHERE timestamp >= @p1 AND timestamp <= @p2 ORDER BY timestamp ASC";
            cmd.Parameters.AddWithValue("@p1", startTs); cmd.Parameters.AddWithValue("@p2", endTs);
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    /// <summary>获取指定会话列表的记录。</summary>
    public static DataTable QuerySessions(SQLiteConnection db, string[] sessionIds)
    {
        using (var cmd = db.CreateCommand())
        {
            var sb = new StringBuilder();
            for (int i = 0; i < sessionIds.Length; i++)
            {
                if (i > 0) sb.Append(',');
                string pn = "@p" + i;
                sb.Append(pn);
                cmd.Parameters.AddWithValue(pn, sessionIds[i]);
            }
            cmd.CommandText = "SELECT * FROM token_records WHERE session_id IN (" + sb + ") ORDER BY timestamp ASC";
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    // ── File metadata ───────────────────────────────────────────────────

    public static DataTable GetFileMetadata(SQLiteConnection db)
    {
        return QueryFileMetadata(db, 0L, 0);
    }

    /// <summary>
    /// 按文件最后写入时间起始截止点和最大行数查询元数据。
    /// cutoffLastWriteTicks 为 0 表示不限制时间，非零值表示只保留
    /// last_write_ticks >= cutoffLastWriteTicks 的最近文件；maximumCount
    /// 为 0 表示返回全部记录。结果按最近写入时间倒序，路径作为稳定的次序键。
    /// </summary>
    public static DataTable QueryFileMetadata(SQLiteConnection db, long cutoffLastWriteTicks, int maximumCount)
    {
        using (var cmd = db.CreateCommand())
        {
            var where = cutoffLastWriteTicks > 0L
                ? " WHERE content_retained <> 0 AND last_write_ticks >= @cutoff"
                : " WHERE content_retained <> 0";
            var limit = maximumCount > 0 ? " LIMIT @maximum" : "";
            cmd.CommandText = "SELECT * FROM file_metadata" + where + " ORDER BY last_write_ticks DESC, path ASC" + limit;
            if (cutoffLastWriteTicks > 0L) cmd.Parameters.AddWithValue("@cutoff", cutoffLastWriteTicks);
            if (maximumCount > 0) cmd.Parameters.AddWithValue("@maximum", maximumCount);
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    /// <summary>按 DateTimeOffset 截止时间查询文件元数据。</summary>
    public static DataTable QueryFileMetadata(SQLiteConnection db, DateTimeOffset cutoff, int maximumCount)
    {
        return QueryFileMetadata(db, cutoff.UtcDateTime.Ticks, maximumCount);
    }

    /// <summary>按 ISO 8601 截止时间查询文件元数据；空字符串表示不限制。</summary>
    public static DataTable QueryFileMetadata(SQLiteConnection db, string cutoff, int maximumCount)
    {
        if (string.IsNullOrWhiteSpace(cutoff)) return QueryFileMetadata(db, 0L, maximumCount);
        DateTimeOffset parsed;
        if (!DateTimeOffset.TryParse(cutoff, CultureInfo.InvariantCulture,
            DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out parsed)) return new DataTable();
        return QueryFileMetadata(db, parsed.UtcDateTime.Ticks, maximumCount);
    }

    /// <summary>
    /// GetFileMetadata 的带截止时间/数量兼容重载。
    /// </summary>
    public static DataTable GetFileMetadata(SQLiteConnection db, long cutoffLastWriteTicks, int maximumCount)
    {
        return QueryFileMetadata(db, cutoffLastWriteTicks, maximumCount);
    }

    public static DataTable GetFileMetadata(SQLiteConnection db, DateTimeOffset cutoff, int maximumCount)
    {
        return QueryFileMetadata(db, cutoff, maximumCount);
    }

    public static DataTable GetFileMetadata(SQLiteConnection db, string cutoff, int maximumCount)
    {
        return QueryFileMetadata(db, cutoff, maximumCount);
    }

    /// <summary>
    /// 捕获所有文件的轻量游标。即使 content_retained=0，游标也会返回，
    /// 这样调用方仍能判断源文件是否后来恢复、被截断或追加；本查询不读
    /// 源 JSONL 内容，也不删除任何历史元数据。
    /// </summary>
    public static DataTable CaptureFileCursorTable(SQLiteConnection db)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT path, length, last_write_ticks, parsed_offset, session_id, cwd, parent_thread_id, forked_from_id, content_retained, root_session_id FROM file_metadata ORDER BY path ASC";
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    /// <summary>
    /// 查询每个文件 [start_offset,end_offset) 范围内的 token 记录。
    /// fileRanges 至少需要 path、start_offset、end_offset 三列；列名比较
    /// 不区分大小写，并兼容 StartOffset/EndOffset 等 PowerShell 常见命名。
    /// </summary>
    public static DataTable QueryIntervalRecords(SQLiteConnection db, DataTable fileRanges)
    {
        return QueryRowsByOffsetRanges(db, ReadOffsetRanges(fileRanges), false);
    }

    /// <summary>
    /// 以两个非泛型 IDictionary（PowerShell Hashtable 可直接传入）表达
    /// 每个文件的起止偏移，查询范围内全部 token 记录。
    /// </summary>
    public static DataTable QueryIntervalRecords(SQLiteConnection db, IDictionary startOffsets, IDictionary endOffsets)
    {
        return QueryRowsByOffsetRanges(db, ReadOffsetRanges(startOffsets, endOffsets), false);
    }

    /// <summary>
    /// 按每文件结束边界分别返回最新的 5 小时和周额度记录。两个窗口
    /// 可以来自不同的日志记录；若同一记录同时携带两个窗口，只返回一次。
    /// </summary>
    public static DataTable QueryLatestRateLimitsByOffsets(SQLiteConnection db, DataTable fileRanges)
    {
        return QueryLatestRateLimitRowsByOffsetRanges(db, ReadOffsetRanges(fileRanges));
    }

    /// <summary>Hashtable 兼容重载，语义与 DataTable 版本相同。</summary>
    public static DataTable QueryLatestRateLimitsByOffsets(SQLiteConnection db, IDictionary startOffsets, IDictionary endOffsets)
    {
        return QueryLatestRateLimitRowsByOffsetRanges(db, ReadOffsetRanges(startOffsets, endOffsets));
    }

    public static void UpdateFileMetadata(SQLiteConnection db, string path, long length, long lastWriteTicks, long parsedOffset)
    {
        // Keep relationship metadata untouched for callers compiled against
        // the original five-argument API; touching a file restores retained
        // content after a previous retention purge.
        UpsertFileMetadata(db, path, length, lastWriteTicks, parsedOffset, null, null, null, null, null, false);
    }

    /// <summary>
    /// 更新文件元数据及其会话关系字段。
    /// 参数顺序保留原有四个文件状态字段，新增 session_id/cwd/
    /// parent_thread_id/forked_from_id；这样旧 PowerShell 调用仍可使用
    /// 五参数重载，新索引器调用可一次写入完整元数据。
    /// </summary>
    public static void UpdateFileMetadata(
        SQLiteConnection db,
        string path,
        long length,
        long lastWriteTicks,
        long parsedOffset,
        string sessionId,
        string cwd,
        string parentThreadId,
        string forkedFromId)
    {
        string rootSessionId = !string.IsNullOrWhiteSpace(parentThreadId)
            ? parentThreadId
            : (!string.IsNullOrWhiteSpace(forkedFromId) ? forkedFromId : (sessionId ?? ""));
        UpsertFileMetadata(db, path, length, lastWriteTicks, parsedOffset,
            sessionId, cwd, parentThreadId, forkedFromId, rootSessionId, true);
    }

    /// <summary>
    /// 更新文件元数据，并显式写入任务树根会话。旧的九参数重载仍然
    /// 可用；当调用方没有根提示时，它会使用 parent/fork/session 的首个
    /// 非空值作为兼容的 root_session_id。
    /// </summary>
    public static void UpdateFileMetadata(
        SQLiteConnection db,
        string path,
        long length,
        long lastWriteTicks,
        long parsedOffset,
        string sessionId,
        string cwd,
        string parentThreadId,
        string forkedFromId,
        string rootSessionId)
    {
        string effectiveRoot = string.IsNullOrWhiteSpace(rootSessionId)
            ? (!string.IsNullOrWhiteSpace(parentThreadId)
                ? parentThreadId
                : (!string.IsNullOrWhiteSpace(forkedFromId) ? forkedFromId : (sessionId ?? "")))
            : rootSessionId;
        UpsertFileMetadata(db, path, length, lastWriteTicks, parsedOffset,
            sessionId, cwd, parentThreadId, forkedFromId, effectiveRoot, true);
    }

    private static void UpsertFileMetadata(
        SQLiteConnection db,
        string path,
        long length,
        long lastWriteTicks,
        long parsedOffset,
        string sessionId,
        string cwd,
        string parentThreadId,
        string forkedFromId,
        string rootSessionId,
        bool writeRelationshipMetadata)
    {
        int affected;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = writeRelationshipMetadata
                ? "UPDATE file_metadata SET length=@p2, last_write_ticks=@p3, parsed_offset=@p4, session_id=@p5, cwd=@p6, parent_thread_id=@p7, forked_from_id=@p8, root_session_id=@p9, content_retained=1 WHERE path=@p1"
                : "UPDATE file_metadata SET length=@p2, last_write_ticks=@p3, parsed_offset=@p4, content_retained=1 WHERE path=@p1";
            cmd.Parameters.AddWithValue("@p1", path); cmd.Parameters.AddWithValue("@p2", length);
            cmd.Parameters.AddWithValue("@p3", lastWriteTicks); cmd.Parameters.AddWithValue("@p4", parsedOffset);
            if (writeRelationshipMetadata)
            {
                cmd.Parameters.AddWithValue("@p5", sessionId ?? "");
                cmd.Parameters.AddWithValue("@p6", cwd ?? "");
                cmd.Parameters.AddWithValue("@p7", parentThreadId ?? "");
                cmd.Parameters.AddWithValue("@p8", forkedFromId ?? "");
                cmd.Parameters.AddWithValue("@p9", rootSessionId ?? "");
            }
            affected = cmd.ExecuteNonQuery();
        }

        if (affected > 0) return;

        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = writeRelationshipMetadata
                ? "INSERT OR IGNORE INTO file_metadata (path, length, last_write_ticks, parsed_offset, session_id, cwd, parent_thread_id, forked_from_id, content_retained, root_session_id) VALUES (@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,1,@p9)"
                : "INSERT OR IGNORE INTO file_metadata (path, length, last_write_ticks, parsed_offset, content_retained) VALUES (@p1,@p2,@p3,@p4,1)";
            cmd.Parameters.AddWithValue("@p1", path); cmd.Parameters.AddWithValue("@p2", length);
            cmd.Parameters.AddWithValue("@p3", lastWriteTicks); cmd.Parameters.AddWithValue("@p4", parsedOffset);
            if (writeRelationshipMetadata)
            {
                cmd.Parameters.AddWithValue("@p5", sessionId ?? "");
                cmd.Parameters.AddWithValue("@p6", cwd ?? "");
                cmd.Parameters.AddWithValue("@p7", parentThreadId ?? "");
                cmd.Parameters.AddWithValue("@p8", forkedFromId ?? "");
                cmd.Parameters.AddWithValue("@p9", rootSessionId ?? "");
            }
            cmd.ExecuteNonQuery();
        }
    }

    public static void RemoveFileMetadata(SQLiteConnection db, string path)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM file_metadata WHERE path = @p";
            cmd.Parameters.AddWithValue("@p", path);
            cmd.ExecuteNonQuery();
        }
    }

    /// <summary>删除指定 session_id 的全部 token 记录，空 ID 不执行删除。</summary>
    public static int DeleteTokenRecordsBySessionId(SQLiteConnection db, string sessionId)
    {
        if (string.IsNullOrWhiteSpace(sessionId)) return 0;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM token_records WHERE session_id = @p";
            cmd.Parameters.AddWithValue("@p", sessionId);
            return cmd.ExecuteNonQuery();
        }
    }

    /// <summary>读取索引级设置；不存在或值为 NULL 时返回 null。</summary>
    public static string GetSetting(SQLiteConnection db, string key)
    {
        if (string.IsNullOrWhiteSpace(key)) return null;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT value FROM index_settings WHERE key = @key LIMIT 1";
            cmd.Parameters.AddWithValue("@key", key);
            object value = cmd.ExecuteScalar();
            if (value == null || value == DBNull.Value) return null;
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }
    }

    /// <summary>写入索引级设置，使用参数化 SQL 并保留已有键的原子更新语义。</summary>
    public static void SetSetting(SQLiteConnection db, string key, string value)
    {
        if (string.IsNullOrWhiteSpace(key)) return;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "INSERT OR REPLACE INTO index_settings (key, value) VALUES (@key, @value)";
            cmd.Parameters.AddWithValue("@key", key);
            cmd.Parameters.AddWithValue("@value", value ?? "");
            cmd.ExecuteNonQuery();
        }
    }

    /// <summary>读取单调索引 revision；旧库或非法值按 0 处理。</summary>
    public static long GetIndexRevision(SQLiteConnection db)
    {
        string raw = GetSetting(db, "IndexRevision");
        long revision;
        if (!long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out revision))
            return 0L;
        return Math.Max(0L, revision);
    }

    /// <summary>
    /// 在一个短事务中将 IndexRevision 单调递增一次并返回新值。
    /// ImportFile 不调用此方法，因此一个批次不会因每行插入而产生大量
    /// revision；调用方应在导入事务全部成功后显式调用本 API。
    /// </summary>
    public static long IncrementIndexRevision(SQLiteConnection db)
    {
        using (var tx = db.BeginTransaction())
        {
            long current = 0L;
            using (var read = db.CreateCommand())
            {
                read.Transaction = tx;
                read.CommandText = "SELECT value FROM index_settings WHERE key = @key LIMIT 1";
                read.Parameters.AddWithValue("@key", "IndexRevision");
                object raw = read.ExecuteScalar();
                if (raw != null && raw != DBNull.Value)
                {
                    long parsed;
                    if (long.TryParse(Convert.ToString(raw, CultureInfo.InvariantCulture),
                        NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed))
                        current = Math.Max(0L, parsed);
                }
            }

            long next = current == long.MaxValue ? long.MaxValue : current + 1L;
            using (var write = db.CreateCommand())
            {
                write.Transaction = tx;
                write.CommandText = "INSERT OR REPLACE INTO index_settings (key, value) VALUES (@key, @value)";
                write.Parameters.AddWithValue("@key", "IndexRevision");
                write.Parameters.AddWithValue("@value", next.ToString(CultureInfo.InvariantCulture));
                write.ExecuteNonQuery();
            }
            tx.Commit();
            return next;
        }
    }

    /// <summary>
    /// 清理截止时间之前的 SQLite 内容记录，不删除源 JSONL 文件或游标。
    /// 旧 file_metadata 行会保留并标记 content_retained=0；返回本次新标记
    /// 的文件元数据行数。cutoffLastWriteTicks 为 0 或负数时不执行清理。
    /// </summary>
    public static int PurgeIndexBefore(SQLiteConnection db, long cutoffLastWriteTicks)
    {
        if (cutoffLastWriteTicks <= 0L) return 0;

        using (var tx = db.BeginTransaction())
        {
            // Delete token rows first while the qualifying file_metadata rows
            // are still visible to the subquery. Prefer source_path for new
            // rows, and retain the session fallback for records imported by an
            // older schema that has no source path. If the same session still
            // has a recent file, keep its token rows because they may describe
            // the active continuation of that session.
            using (var tokenCmd = db.CreateCommand())
            {
                tokenCmd.Transaction = tx;
                tokenCmd.CommandText = "DELETE FROM token_records WHERE (source_path IN (SELECT path FROM file_metadata WHERE last_write_ticks < @cutoff) OR (session_id IN (SELECT session_id FROM file_metadata WHERE last_write_ticks < @cutoff AND session_id IS NOT NULL AND session_id <> '') AND (source_path IS NULL OR source_path = ''))) AND session_id NOT IN (SELECT session_id FROM file_metadata WHERE last_write_ticks >= @cutoff AND session_id IS NOT NULL AND session_id <> '')";
                tokenCmd.Parameters.AddWithValue("@cutoff", cutoffLastWriteTicks);
                tokenCmd.ExecuteNonQuery();
            }

            int markedFiles;
            using (var metadataCmd = db.CreateCommand())
            {
                metadataCmd.Transaction = tx;
                metadataCmd.CommandText = "UPDATE file_metadata SET content_retained=0 WHERE last_write_ticks < @cutoff AND content_retained <> 0";
                metadataCmd.Parameters.AddWithValue("@cutoff", cutoffLastWriteTicks);
                markedFiles = metadataCmd.ExecuteNonQuery();
            }

            tx.Commit();
            return markedFiles;
        }
    }

    private sealed class OffsetRange
    {
        public string Path;
        public long Start;
        public long End;
    }

    private static List<OffsetRange> ReadOffsetRanges(DataTable table)
    {
        var ranges = new List<OffsetRange>();
        if (table == null) return ranges;

        string pathColumn = FindColumn(table, "path", "source_path", "file_path", "filepath");
        string startColumn = FindColumn(table, "start_offset", "start", "StartOffset");
        string endColumn = FindColumn(table, "end_offset", "end", "EndOffset");
        if (pathColumn == null || startColumn == null || endColumn == null) return ranges;

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (DataRow row in table.Rows)
        {
            string path = row[pathColumn] == DBNull.Value ? "" : Convert.ToString(row[pathColumn], CultureInfo.InvariantCulture);
            long start; long end;
            if (string.IsNullOrWhiteSpace(path) || !TryConvertInt64(row[startColumn], out start) ||
                !TryConvertInt64(row[endColumn], out end)) continue;
            start = Math.Max(0L, start);
            if (end < 0L) end = long.MaxValue;
            if (end <= start) continue;
            string key = path + "\u001F" + start.ToString(CultureInfo.InvariantCulture) + "\u001F" + end.ToString(CultureInfo.InvariantCulture);
            if (!seen.Add(key)) continue;
            ranges.Add(new OffsetRange { Path = path, Start = start, End = end });
        }
        return ranges;
    }

    private static List<OffsetRange> ReadOffsetRanges(IDictionary startOffsets, IDictionary endOffsets)
    {
        var ranges = new List<OffsetRange>();
        if (startOffsets == null) return ranges;

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry entry in startOffsets)
        {
            string path = entry.Key == null ? "" : Convert.ToString(entry.Key, CultureInfo.InvariantCulture);
            long start;
            if (string.IsNullOrWhiteSpace(path) || !TryConvertInt64(entry.Value, out start)) continue;

            object rawEnd = null;
            if (endOffsets != null)
            {
                try
                {
                    if (endOffsets.Contains(entry.Key)) rawEnd = endOffsets[entry.Key];
                }
                catch (ArgumentException) { rawEnd = null; }
            }
            long end;
            if (rawEnd == null || !TryConvertInt64(rawEnd, out end)) end = long.MaxValue;
            start = Math.Max(0L, start);
            if (end < 0L) end = long.MaxValue;
            if (end <= start) continue;
            string key = path + "\u001F" + start.ToString(CultureInfo.InvariantCulture) + "\u001F" + end.ToString(CultureInfo.InvariantCulture);
            if (!seen.Add(key)) continue;
            ranges.Add(new OffsetRange { Path = path, Start = start, End = end });
        }
        return ranges;
    }

    private static DataTable QueryRowsByOffsetRanges(SQLiteConnection db, List<OffsetRange> ranges, bool onlyRateLimits)
    {
        DataTable result = CreateEmptyTokenRecordsTable(db);
        if (ranges == null || ranges.Count == 0) return result;

        // Three parameters per file keeps the generated statement well below
        // SQLite's default parameter limit while still reducing round trips.
        const int chunkSize = 100;
        for (int offset = 0; offset < ranges.Count; offset += chunkSize)
        {
            int count = Math.Min(chunkSize, ranges.Count - offset);
            using (var cmd = db.CreateCommand())
            {
                var predicates = new StringBuilder();
                for (int i = 0; i < count; i++)
                {
                    if (i > 0) predicates.Append(" OR ");
                    predicates.Append("(source_path=@path");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(" AND source_offset_end>@start");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(" AND source_offset_end<=@end");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(")");

                    OffsetRange range = ranges[offset + i];
                    cmd.Parameters.AddWithValue("@path" + i.ToString(CultureInfo.InvariantCulture), range.Path);
                    cmd.Parameters.AddWithValue("@start" + i.ToString(CultureInfo.InvariantCulture), range.Start);
                    cmd.Parameters.AddWithValue("@end" + i.ToString(CultureInfo.InvariantCulture), range.End);
                }

                cmd.CommandText = "SELECT * FROM token_records WHERE (" + predicates + ")" +
                    (onlyRateLimits ? " AND (five_hour_used IS NOT NULL OR weekly_used IS NOT NULL)" : "") +
                    " ORDER BY timestamp ASC, id ASC";
                var chunk = new DataTable();
                using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(chunk); }
                result.Merge(chunk, true, MissingSchemaAction.Add);
            }
        }
        return SortTokenRecordTable(result, false);
    }

    /// <summary>
    /// 额度快照最终只需要全局最新的 5 小时行和周额度行。旧实现先把
    /// 所有文件边界内的全部历史额度记录载入 DataTable，再在内存选两行；
    /// 大型索引会因此在“开始计算”阶段长期占用内存和磁盘。这里先在
    /// SQLite 中按文件及窗口选择 source_offset_end 最大的记录，使每个
    /// 文件最多返回两条候选，再执行原有的跨文件时间比较。
    /// </summary>
    private static DataTable QueryLatestRateLimitRowsByOffsetRanges(SQLiteConnection db, List<OffsetRange> ranges)
    {
        DataTable candidates = CreateEmptyTokenRecordsTable(db);
        if (ranges == null || ranges.Count == 0) return candidates;

        var seenIds = new HashSet<long>();
        const int chunkSize = 125;
        for (int offset = 0; offset < ranges.Count; offset += chunkSize)
        {
            int count = Math.Min(chunkSize, ranges.Count - offset);
            using (var cmd = db.CreateCommand())
            {
                var predicates = new StringBuilder();
                for (int i = 0; i < count; i++)
                {
                    if (i > 0) predicates.Append(" OR ");
                    predicates.Append("(source_path=@path");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(" AND source_offset_end>@start");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(" AND source_offset_end<=@end");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(")");

                    OffsetRange range = ranges[offset + i];
                    cmd.Parameters.AddWithValue("@path" + i.ToString(CultureInfo.InvariantCulture), range.Path);
                    cmd.Parameters.AddWithValue("@start" + i.ToString(CultureInfo.InvariantCulture), range.Start);
                    cmd.Parameters.AddWithValue("@end" + i.ToString(CultureInfo.InvariantCulture), range.End);
                }

                // One grouped scan computes both latest offsets. The outer join
                // returns one common row when it carries both windows, or two
                // rows when 5-hour and weekly snapshots were logged separately.
                cmd.CommandText =
                    "SELECT tr.* FROM token_records AS tr INNER JOIN (" +
                    "SELECT source_path, " +
                    "MAX(CASE WHEN five_hour_used IS NOT NULL THEN source_offset_end END) AS five_offset, " +
                    "MAX(CASE WHEN weekly_used IS NOT NULL THEN source_offset_end END) AS weekly_offset " +
                    "FROM token_records WHERE (" + predicates + ") " +
                    "AND (five_hour_used IS NOT NULL OR weekly_used IS NOT NULL) GROUP BY source_path" +
                    ") AS latest ON tr.source_path=latest.source_path AND " +
                    "(tr.source_offset_end=latest.five_offset OR tr.source_offset_end=latest.weekly_offset)";

                var chunk = new DataTable();
                using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(chunk); }
                foreach (DataRow row in chunk.Rows)
                {
                    long id;
                    if (!TryConvertInt64(row["id"], out id) || !seenIds.Add(id)) continue;
                    candidates.ImportRow(row);
                }
            }
        }
        return SelectLatestRateLimitRows(candidates);
    }

    private static DataTable CreateEmptyTokenRecordsTable(SQLiteConnection db)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT * FROM token_records WHERE 1=0";
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    private static DataTable SelectLatestRateLimitRows(DataTable candidates)
    {
        DataTable result = candidates == null ? new DataTable() : candidates.Clone();
        if (candidates == null || candidates.Rows.Count == 0) return result;

        DataRow latestFive = null;
        DataRow latestWeekly = null;
        foreach (DataRow row in candidates.Rows)
        {
            if (HasData(row, "five_hour_used") && IsLaterTokenRow(row, latestFive)) latestFive = row;
            if (HasData(row, "weekly_used") && IsLaterTokenRow(row, latestWeekly)) latestWeekly = row;
        }
        if (latestFive != null) result.ImportRow(latestFive);
        if (latestWeekly != null && !object.ReferenceEquals(latestFive, latestWeekly)) result.ImportRow(latestWeekly);
        return SortTokenRecordTable(result, true);
    }

    private static DataTable SortTokenRecordTable(DataTable table, bool descending)
    {
        if (table == null || table.Rows.Count < 2) return table;
        DataTable sorted = table.Clone();
        DataView view = table.DefaultView;
        view.Sort = descending ? "timestamp DESC, id DESC" : "timestamp ASC, id ASC";
        foreach (DataRowView row in view) sorted.ImportRow(row.Row);
        return sorted;
    }

    private static bool HasData(DataRow row, string columnName)
    {
        return row != null && row.Table != null && row.Table.Columns.Contains(columnName) &&
            row[columnName] != null && row[columnName] != DBNull.Value;
    }

    private static bool IsLaterTokenRow(DataRow candidate, DataRow current)
    {
        if (candidate == null) return false;
        if (current == null) return true;
        string candidateTs = HasData(candidate, "timestamp")
            ? Convert.ToString(candidate["timestamp"], CultureInfo.InvariantCulture) : "";
        string currentTs = HasData(current, "timestamp")
            ? Convert.ToString(current["timestamp"], CultureInfo.InvariantCulture) : "";
        DateTimeOffset candidateAt; DateTimeOffset currentAt;
        int comparison;
        if (TryParseTimestamp(candidateTs, out candidateAt) && TryParseTimestamp(currentTs, out currentAt))
            comparison = DateTimeOffset.Compare(candidateAt.ToUniversalTime(), currentAt.ToUniversalTime());
        else
            comparison = string.CompareOrdinal(candidateTs, currentTs);
        if (comparison != 0) return comparison > 0;
        long candidateId; long currentId;
        if (!TryConvertInt64(candidate["id"], out candidateId)) candidateId = 0L;
        if (!TryConvertInt64(current["id"], out currentId)) currentId = 0L;
        return candidateId > currentId;
    }

    private static string FindColumn(DataTable table, params string[] names)
    {
        if (table == null || names == null) return null;
        foreach (DataColumn column in table.Columns)
        {
            foreach (string name in names)
            {
                if (string.Equals(column.ColumnName, name, StringComparison.OrdinalIgnoreCase))
                    return column.ColumnName;
            }
        }
        return null;
    }

    private static bool TryConvertInt64(object raw, out long value)
    {
        value = 0L;
        if (raw == null || raw == DBNull.Value || raw is bool) return false;
        try
        {
            if (raw is byte || raw is sbyte || raw is short || raw is ushort ||
                raw is int || raw is uint || raw is long || raw is ulong)
            {
                value = Convert.ToInt64(raw, CultureInfo.InvariantCulture);
                return true;
            }
            double number;
            if (TryGetDoubleValue(raw, out number) && !double.IsNaN(number) &&
                !double.IsInfinity(number) && number >= (double)long.MinValue &&
                number <= (double)long.MaxValue)
            {
                value = Convert.ToInt64(Math.Truncate(number), CultureInfo.InvariantCulture);
                return true;
            }
        }
        catch (Exception)
        {
            return false;
        }
        return false;
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    /// <summary>
    /// 读取 [startOffset,endOffset) 内的 UTF-8 JSONL。StreamReader 会预读
    /// 数 KB 内容，无法用 BaseStream.Position 得到当前行结束位置；本类
    /// 直接按字节寻找换行，因此 source_offset_end 始终是准确的 UTF-8
    /// 字节边界（包含 LF 或 CRLF 的换行字节）。
    /// </summary>
    private sealed class Utf8JsonlLineReader : IDisposable
    {
        private readonly Stream _stream;
        private readonly long _endOffset;
        private readonly byte[] _buffer = new byte[64 * 1024];
        private int _bufferIndex;
        private int _bufferCount;
        private long _position;

        public Utf8JsonlLineReader(Stream stream, long startOffset, long endOffset)
        {
            _stream = stream;
            _position = Math.Max(0L, startOffset);
            _endOffset = Math.Max(_position, endOffset);
            _stream.Seek(_position, SeekOrigin.Begin);
            _bufferIndex = 0;
            _bufferCount = 0;
        }

        public bool ReadLine(out string line, out long lineEndOffset, out bool terminated)
        {
            line = null;
            lineEndOffset = _position;
            terminated = false;

            using (var bytes = new MemoryStream())
            {
                while (_position < _endOffset)
                {
                    int value = ReadByte();
                    if (value < 0) break;

                    if (value == 0x0A) // LF
                    {
                        terminated = true;
                        break;
                    }
                    if (value == 0x0D) // CR, with optional LF in CRLF
                    {
                        if (PeekByte() == 0x0A) ReadByte();
                        terminated = true;
                        break;
                    }
                    bytes.WriteByte((byte)value);
                }

                lineEndOffset = _position;
                if (bytes.Length == 0 && !terminated && _position >= _endOffset)
                    return false;
                line = Encoding.UTF8.GetString(bytes.ToArray());
                return true;
            }
        }

        private int PeekByte()
        {
            if (_position >= _endOffset) return -1;
            if (!FillBuffer()) return -1;
            return _buffer[_bufferIndex];
        }

        private int ReadByte()
        {
            if (_position >= _endOffset) return -1;
            if (!FillBuffer()) return -1;
            int value = _buffer[_bufferIndex++];
            _position++;
            return value;
        }

        private bool FillBuffer()
        {
            if (_bufferIndex < _bufferCount) return true;
            long remaining = _endOffset - _position;
            if (remaining <= 0L) return false;
            int requested = (int)Math.Min((long)_buffer.Length, remaining);
            _bufferIndex = 0;
            _bufferCount = _stream.Read(_buffer, 0, requested);
            return _bufferCount > 0;
        }

        public void Dispose()
        {
            // The importer owns and disposes the underlying FileStream.
        }
    }

    private static void EnsureFileMetadataColumn(SQLiteConnection db, string columnName, string columnDefinition)
    {
        bool exists = false;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(file_metadata)";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string existingName = reader.IsDBNull(1) ? "" : reader.GetString(1);
                    if (string.Equals(existingName, columnName, StringComparison.OrdinalIgnoreCase))
                    {
                        exists = true;
                        break;
                    }
                }
            }
        }
        if (exists) return;

        using (var cmd = db.CreateCommand())
        {
            // Column names and definitions are private constants at every
            // call site; no user-provided SQL is interpolated here.
            cmd.CommandText = "ALTER TABLE file_metadata ADD COLUMN " + columnName + " " + columnDefinition;
            cmd.ExecuteNonQuery();
        }
    }

    private static void EnsureTokenRecordColumn(SQLiteConnection db, string columnName, string columnDefinition)
    {
        bool exists = false;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(token_records)";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string existingName = reader.IsDBNull(1) ? "" : reader.GetString(1);
                    if (string.Equals(existingName, columnName, StringComparison.OrdinalIgnoreCase))
                    {
                        exists = true;
                        break;
                    }
                }
            }
        }
        if (exists) return;

        using (var cmd = db.CreateCommand())
        {
            // Column names and definitions are private constants at every
            // call site; no user-provided SQL is interpolated here.
            cmd.CommandText = "ALTER TABLE token_records ADD COLUMN " + columnName + " " + columnDefinition;
            cmd.ExecuteNonQuery();
        }
    }

    private static string GetLatestSessionModel(SQLiteConnection db, string sessionId)
    {
        if (string.IsNullOrWhiteSpace(sessionId)) return "";
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT model FROM token_records WHERE session_id = @p AND model IS NOT NULL AND model <> '' ORDER BY id DESC LIMIT 1";
            cmd.Parameters.AddWithValue("@p", sessionId);
            object value = cmd.ExecuteScalar();
            if (value == null || value == DBNull.Value) return "";
            return Convert.ToString(value, CultureInfo.InvariantCulture) ?? "";
        }
    }

    private static string ExtractSessionId(string filePath)
    {
        string name = Path.GetFileNameWithoutExtension(filePath);
        var m = _sessionIdFromPath.Match(name);
        return m.Success ? m.Groups[1].Value.ToLowerInvariant() : name.ToLowerInvariant();
    }

    private static string GetCanonicalPath(string filePath)
    {
        try { return Path.GetFullPath(filePath); }
        catch (Exception) { return filePath ?? ""; }
    }

    private static Dictionary<string, object> GetDict(Dictionary<string, object> d, string k)
    { object o; return d.TryGetValue(k, out o) ? o as Dictionary<string, object> : null; }

    private static string GetString(Dictionary<string, object> d, string k)
    { object o; return d.TryGetValue(k, out o) ? o as string : null; }

    private static double ClampPercent(double value)
    {
        if (double.IsNaN(value)) return 0.0;
        if (value < 0.0) return 0.0;
        if (value > 100.0) return 100.0;
        return value;
    }

    /// <summary>
    /// 解析记录的 timestamp，供 resets_in_seconds 使用。
    /// Codex 日志通常使用 ISO 8601 字符串，但兼容 Unix 秒/毫秒时间戳。
    /// </summary>
    private static bool TryGetObservedAt(Dictionary<string, object> record, out DateTimeOffset observedAt)
    {
        observedAt = default(DateTimeOffset);
        object raw;
        if (!record.TryGetValue("timestamp", out raw) || raw == null) return false;
        return TryParseTimestamp(raw, out observedAt);
    }

    private static bool TryParseTimestamp(object raw, out DateTimeOffset value)
    {
        value = default(DateTimeOffset);
        if (raw == null) return false;

        string text = raw as string;
        if (!string.IsNullOrWhiteSpace(text))
        {
            text = text.Trim();
            double numeric;
            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out numeric))
            {
                return TryUnixNumberToDateTimeOffset(numeric, out value);
            }

            DateTimeOffset parsed;
            if (DateTimeOffset.TryParse(
                text,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out parsed))
            {
                value = parsed.ToUniversalTime();
                return true;
            }
            return false;
        }

        double number;
        return TryGetDoubleValue(raw, out number) && TryUnixNumberToDateTimeOffset(number, out value);
    }

    /// <summary>
    /// 将 reset_at/resets_at 的 Unix 秒或毫秒值，或 ISO 字符串，归一化为 Unix 秒。
    /// </summary>
    private static bool TryNormalizeResetValue(object raw, out long unixSeconds)
    {
        unixSeconds = 0L;
        if (raw == null) return false;

        DateTimeOffset dateValue;
        string text = raw as string;
        if (!string.IsNullOrWhiteSpace(text))
        {
            text = text.Trim();
            double numeric;
            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out numeric))
            {
                if (!DateTimeOffset.TryParse(
                    text,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                    out dateValue))
                {
                    return false;
                }
                return TryDateTimeOffsetToUnixSeconds(dateValue, out unixSeconds);
            }
            return TryUnixNumberToUnixSeconds(numeric, out unixSeconds);
        }

        double number;
        if (TryGetDoubleValue(raw, out number)) return TryUnixNumberToUnixSeconds(number, out unixSeconds);
        if (raw is DateTimeOffset)
        {
            dateValue = (DateTimeOffset)raw;
            return TryDateTimeOffsetToUnixSeconds(dateValue, out unixSeconds);
        }
        if (raw is DateTime)
        {
            dateValue = new DateTimeOffset((DateTime)raw);
            return TryDateTimeOffsetToUnixSeconds(dateValue, out unixSeconds);
        }
        return false;
    }

    private static bool TryGetResetUnixSeconds(
        Dictionary<string, object> window,
        DateTimeOffset? observedAt,
        out long unixSeconds)
    {
        unixSeconds = 0L;
        object raw;
        // Prefer an absolute reset time. Some log versions use reset_at while
        // current versions generally use resets_at.
        foreach (string key in new[] { "resets_at", "reset_at" })
        {
            if (window.TryGetValue(key, out raw) && raw != null && TryNormalizeResetValue(raw, out unixSeconds))
                return true;
        }

        // Older/newer payloads may provide only a relative number of seconds.
        // It is meaningful only when the event timestamp is parseable.
        if (observedAt.HasValue && window.TryGetValue("resets_in_seconds", out raw) && raw != null)
        {
            double seconds;
            if (TryGetDoubleValue(raw, out seconds) && !double.IsNaN(seconds) && !double.IsInfinity(seconds))
            {
                try
                {
                    DateTimeOffset resetAt = observedAt.Value.AddSeconds(seconds);
                    return TryDateTimeOffsetToUnixSeconds(resetAt, out unixSeconds);
                }
                catch (ArgumentOutOfRangeException) { }
            }
        }
        return false;
    }

    private static bool TryUnixNumberToDateTimeOffset(double number, out DateTimeOffset value)
    {
        value = default(DateTimeOffset);
        long seconds;
        if (!TryUnixNumberToUnixSeconds(number, out seconds)) return false;
        try
        {
            value = UnixEpoch.AddSeconds(seconds);
            return true;
        }
        catch (ArgumentOutOfRangeException) { return false; }
    }

    private static bool TryUnixNumberToUnixSeconds(double number, out long seconds)
    {
        seconds = 0L;
        if (double.IsNaN(number) || double.IsInfinity(number)) return false;

        // Unix milliseconds are approximately 1e12 today, while Unix seconds
        // are approximately 1e9. Keep the threshold broad enough for dates
        // before/after the present without confusing seconds with milliseconds.
        if (Math.Abs(number) >= 100000000000.0) number /= 1000.0;
        if (number < (double)long.MinValue || number > (double)long.MaxValue) return false;
        double truncated = Math.Truncate(number);
        try { seconds = Convert.ToInt64(truncated, CultureInfo.InvariantCulture); }
        catch (OverflowException) { return false; }
        return true;
    }

    private static bool TryDateTimeOffsetToUnixSeconds(DateTimeOffset value, out long unixSeconds)
    {
        unixSeconds = 0L;
        try
        {
            double seconds = (value.ToUniversalTime() - UnixEpoch).TotalSeconds;
            if (double.IsNaN(seconds) || double.IsInfinity(seconds)) return false;
            unixSeconds = Convert.ToInt64(Math.Truncate(seconds), CultureInfo.InvariantCulture);
            return true;
        }
        catch (OverflowException) { return false; }
    }

    private static readonly DateTimeOffset UnixEpoch =
        new DateTimeOffset(1970, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static bool TryGetDoubleValue(object raw, out double value)
    {
        value = 0.0;
        if (raw == null || raw is bool) return false;
        if (raw is double) { value = (double)raw; return true; }
        if (raw is float) { value = (float)raw; return true; }
        if (raw is decimal) { value = (double)(decimal)raw; return true; }
        if (raw is byte || raw is sbyte || raw is short || raw is ushort ||
            raw is int || raw is uint || raw is long || raw is ulong)
        {
            try { value = Convert.ToDouble(raw, CultureInfo.InvariantCulture); return true; }
            catch (OverflowException) { return false; }
        }

        string text = raw as string;
        if (text == null) return false;
        return double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out value);
    }

    private static long GetInt64(Dictionary<string, object> d, string k)
    {
        object o; double value;
        if (d.TryGetValue(k, out o) && TryGetDoubleValue(o, out value) &&
            !double.IsNaN(value) && !double.IsInfinity(value) &&
            value >= (double)long.MinValue && value <= (double)long.MaxValue)
        {
            try { return Convert.ToInt64(Math.Truncate(value), CultureInfo.InvariantCulture); }
            catch (OverflowException) { }
        }
        return 0L;
    }

    private static double GetDouble(Dictionary<string, object> d, string k)
    {
        object o; double value;
        if (d.TryGetValue(k, out o) && TryGetDoubleValue(o, out value)) return value;
        return 0.0;
    }
}
