using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SQLite;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
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
    // ── Schema ──────────────────────────────────────────────────────────

    public static void CreateSchema(SQLiteConnection db)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "CREATE TABLE IF NOT EXISTS file_metadata (path TEXT PRIMARY KEY, length INTEGER NOT NULL, last_write_ticks INTEGER NOT NULL, parsed_offset INTEGER NOT NULL DEFAULT 0, session_id TEXT NOT NULL DEFAULT '', cwd TEXT NOT NULL DEFAULT '', parent_thread_id TEXT NOT NULL DEFAULT '', forked_from_id TEXT NOT NULL DEFAULT '')";
            cmd.ExecuteNonQuery();

            // Existing installations may have a four-column file_metadata table.
            // ALTER TABLE is intentionally additive so the on-disk index remains
            // readable and existing rows retain their offsets and timestamps.
            EnsureFileMetadataColumn(db, "session_id", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "cwd", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "parent_thread_id", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "forked_from_id", "TEXT NOT NULL DEFAULT ''");

            cmd.CommandText = "CREATE TABLE IF NOT EXISTS token_records (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, timestamp TEXT NOT NULL, model TEXT NOT NULL DEFAULT '', total_input INTEGER NOT NULL, total_cached INTEGER NOT NULL, total_output INTEGER NOT NULL, total_reasoning INTEGER NOT NULL DEFAULT 0, call_input INTEGER NOT NULL, call_cached INTEGER NOT NULL, call_output INTEGER NOT NULL, call_reasoning INTEGER NOT NULL DEFAULT 0, fingerprint TEXT NOT NULL DEFAULT '', five_hour_used REAL, five_hour_window INTEGER, five_hour_resets INTEGER, weekly_used REAL, weekly_window INTEGER, weekly_resets INTEGER, plan_type TEXT NOT NULL DEFAULT '')";
            cmd.ExecuteNonQuery();

            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_session ON token_records(session_id)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_timestamp ON token_records(timestamp)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_model ON token_records(model)";
            cmd.ExecuteNonQuery();

            cmd.CommandText = "CREATE TABLE IF NOT EXISTS index_settings (key TEXT PRIMARY KEY, value TEXT)";
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
        return ImportFile(db, filePath, startOffset, long.MaxValue);
    }

    /// <summary>解析指定字节边界内的 JSONL，避免并发追加越过冻结边界。</summary>
    public static int ImportFile(SQLiteConnection db, string filePath, long startOffset, long endOffset)
    {
        int count = 0;
        string sessionId = ExtractSessionId(filePath);
        // Read this before opening the import transaction: the lookup command
        // intentionally uses the connection's normal transaction context.
        string inheritedModel = GetLatestSessionModel(db, sessionId);

        using (var tx = db.BeginTransaction())
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "INSERT INTO token_records (session_id, timestamp, model, total_input, total_cached, total_output, total_reasoning, call_input, call_cached, call_output, call_reasoning, fingerprint, five_hour_used, five_hour_window, five_hour_resets, weekly_used, weekly_window, weekly_resets, plan_type) VALUES (@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,@p9,@p10,@p11,@p12,@p13,@p14,@p15,@p16,@p17,@p18,@p19)";
            var p = new SQLiteParameter[19];
            for (int i = 0; i < p.Length; i++)
            {
                var prm = new SQLiteParameter("@p" + (i + 1));
                cmd.Parameters.Add(prm);
                p[i] = prm;
            }

            using (var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                long effectiveEnd = Math.Min(fs.Length, endOffset < 0 ? 0 : endOffset);
                if (effectiveEnd == 0) { tx.Commit(); return 0; }
                bool skipPartialLine = false;
                if (startOffset > 0)
                {
                    if (startOffset >= effectiveEnd) { tx.Commit(); return 0; }
                    fs.Seek(startOffset - 1, SeekOrigin.Begin);
                    int previousByte = fs.ReadByte();
                    skipPartialLine = previousByte != '\n' && previousByte != '\r';
                    fs.Seek(startOffset, SeekOrigin.Begin);
                }

                long readPosition = fs.Position;
                fs.Seek(effectiveEnd - 1, SeekOrigin.Begin);
                bool hasUnterminatedTail = fs.ReadByte() != '\n';
                fs.Seek(readPosition, SeekOrigin.Begin);

                using (var bounded = new BoundedReadStream(fs, effectiveEnd - readPosition))
                using (var sr = new StreamReader(bounded, Encoding.UTF8, detectEncodingFromByteOrderMarks: startOffset == 0))
                {
                    // Only discard text when the stored offset truly points
                    // into an incomplete line. A normal parsed_offset follows
                    // a newline and must begin with the first appended record.
                    if (skipPartialLine) sr.ReadLine();

                    // An incremental import starts in the middle of a JSONL file,
                    // where the preceding turn_context is not available. Inherit
                    // the latest non-empty model already indexed for this session;
                    // a later turn_context in the appended segment still wins.
                    string currentModel = inheritedModel;
                    string line;
                    while ((line = sr.ReadLine()) != null)
                    {
                        if (hasUnterminatedTail && sr.EndOfStream) break;
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
                        string type = record["type"] as string ?? "";
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
            var where = cutoffLastWriteTicks > 0L ? " WHERE last_write_ticks >= @cutoff" : "";
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

    public static void UpdateFileMetadata(SQLiteConnection db, string path, long length, long lastWriteTicks, long parsedOffset)
    {
        // Keep metadata columns untouched for callers compiled against the
        // original five-argument API.
        UpsertFileMetadata(db, path, length, lastWriteTicks, parsedOffset, null, null, null, null, false);
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
        UpsertFileMetadata(db, path, length, lastWriteTicks, parsedOffset,
            sessionId, cwd, parentThreadId, forkedFromId, true);
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
        bool writeRelationshipMetadata)
    {
        int affected;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = writeRelationshipMetadata
                ? "UPDATE file_metadata SET length=@p2, last_write_ticks=@p3, parsed_offset=@p4, session_id=@p5, cwd=@p6, parent_thread_id=@p7, forked_from_id=@p8 WHERE path=@p1"
                : "UPDATE file_metadata SET length=@p2, last_write_ticks=@p3, parsed_offset=@p4 WHERE path=@p1";
            cmd.Parameters.AddWithValue("@p1", path); cmd.Parameters.AddWithValue("@p2", length);
            cmd.Parameters.AddWithValue("@p3", lastWriteTicks); cmd.Parameters.AddWithValue("@p4", parsedOffset);
            if (writeRelationshipMetadata)
            {
                cmd.Parameters.AddWithValue("@p5", sessionId ?? "");
                cmd.Parameters.AddWithValue("@p6", cwd ?? "");
                cmd.Parameters.AddWithValue("@p7", parentThreadId ?? "");
                cmd.Parameters.AddWithValue("@p8", forkedFromId ?? "");
            }
            affected = cmd.ExecuteNonQuery();
        }

        if (affected > 0) return;

        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = writeRelationshipMetadata
                ? "INSERT OR IGNORE INTO file_metadata (path, length, last_write_ticks, parsed_offset, session_id, cwd, parent_thread_id, forked_from_id) VALUES (@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8)"
                : "INSERT OR IGNORE INTO file_metadata (path, length, last_write_ticks, parsed_offset) VALUES (@p1,@p2,@p3,@p4)";
            cmd.Parameters.AddWithValue("@p1", path); cmd.Parameters.AddWithValue("@p2", length);
            cmd.Parameters.AddWithValue("@p3", lastWriteTicks); cmd.Parameters.AddWithValue("@p4", parsedOffset);
            if (writeRelationshipMetadata)
            {
                cmd.Parameters.AddWithValue("@p5", sessionId ?? "");
                cmd.Parameters.AddWithValue("@p6", cwd ?? "");
                cmd.Parameters.AddWithValue("@p7", parentThreadId ?? "");
                cmd.Parameters.AddWithValue("@p8", forkedFromId ?? "");
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

    /// <summary>
    /// 清理截止时间之前的 SQLite 索引记录，不删除源 JSONL 文件。
    /// 返回被删除的 file_metadata 行数；cutoffLastWriteTicks 为 0 或负数时不执行清理。
    /// </summary>
    public static int PurgeIndexBefore(SQLiteConnection db, long cutoffLastWriteTicks)
    {
        if (cutoffLastWriteTicks <= 0L) return 0;

        using (var tx = db.BeginTransaction())
        {
            // Delete token rows first while the qualifying file_metadata rows
            // are still visible to the subquery. Empty relationship IDs are
            // intentionally excluded so an old/incomplete metadata row cannot
            // remove unrelated records whose session_id is also empty.
            using (var tokenCmd = db.CreateCommand())
            {
                tokenCmd.Transaction = tx;
                tokenCmd.CommandText = "DELETE FROM token_records WHERE session_id IN (SELECT session_id FROM file_metadata WHERE last_write_ticks < @cutoff AND session_id IS NOT NULL AND session_id <> '') AND session_id NOT IN (SELECT session_id FROM file_metadata WHERE last_write_ticks >= @cutoff AND session_id IS NOT NULL AND session_id <> '')";
                tokenCmd.Parameters.AddWithValue("@cutoff", cutoffLastWriteTicks);
                tokenCmd.ExecuteNonQuery();
            }

            int deletedFiles;
            using (var metadataCmd = db.CreateCommand())
            {
                metadataCmd.Transaction = tx;
                metadataCmd.CommandText = "DELETE FROM file_metadata WHERE last_write_ticks < @cutoff";
                metadataCmd.Parameters.AddWithValue("@cutoff", cutoffLastWriteTicks);
                deletedFiles = metadataCmd.ExecuteNonQuery();
            }

            tx.Commit();
            return deletedFiles;
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private sealed class BoundedReadStream : Stream
    {
        private readonly Stream _inner;
        private long _remaining;

        public BoundedReadStream(Stream inner, long length)
        {
            _inner = inner;
            _remaining = Math.Max(0L, length);
        }

        public override bool CanRead { get { return _inner.CanRead; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { return _remaining; } }
        public override long Position
        {
            get { return _inner.Position; }
            set { throw new NotSupportedException(); }
        }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count)
        {
            if (_remaining <= 0) return 0;
            int requested = (int)Math.Min((long)count, _remaining);
            int read = _inner.Read(buffer, offset, requested);
            _remaining -= read;
            return read;
        }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }

        protected override void Dispose(bool disposing)
        {
            // The outer FileStream owns the underlying handle.
            base.Dispose(disposing);
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
