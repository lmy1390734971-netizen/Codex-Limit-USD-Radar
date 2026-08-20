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
/// 写入 SQLite 数据库（%TEMP%\TokenRader\index.db），后续所有查询走 SQL，
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
            cmd.CommandText = "CREATE TABLE IF NOT EXISTS file_metadata (path TEXT PRIMARY KEY, length INTEGER NOT NULL, last_write_ticks INTEGER NOT NULL, parsed_offset INTEGER NOT NULL DEFAULT 0)";
            cmd.ExecuteNonQuery();

            cmd.CommandText = "CREATE TABLE IF NOT EXISTS token_records (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, timestamp TEXT NOT NULL, model TEXT NOT NULL DEFAULT '', total_input INTEGER NOT NULL, total_cached INTEGER NOT NULL, total_output INTEGER NOT NULL, total_reasoning INTEGER NOT NULL DEFAULT 0, call_input INTEGER NOT NULL, call_cached INTEGER NOT NULL, call_output INTEGER NOT NULL, call_reasoning INTEGER NOT NULL DEFAULT 0, fingerprint TEXT NOT NULL DEFAULT '', five_hour_used REAL, five_hour_window INTEGER, five_hour_resets INTEGER, weekly_used REAL, weekly_window INTEGER, weekly_resets INTEGER, plan_type TEXT NOT NULL DEFAULT '')";
            cmd.ExecuteNonQuery();

            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_session ON token_records(session_id)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_timestamp ON token_records(timestamp)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_model ON token_records(model)";
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
        int count = 0;
        string sessionId = ExtractSessionId(filePath);

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
            using (var sr = new StreamReader(fs, Encoding.UTF8, detectEncodingFromByteOrderMarks: true))
            {
                if (startOffset > 0)
                {
                    if (startOffset >= fs.Length) { tx.Commit(); return 0; }
                    fs.Seek(startOffset, SeekOrigin.Begin);
                    int firstByte = fs.ReadByte();
                    if (firstByte != '\n') { sr.ReadLine(); } else { fs.Seek(startOffset, SeekOrigin.Begin); }
                }

                string currentModel = "";
                string line;
                while ((line = sr.ReadLine()) != null)
                {
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
                            foreach (string key in new[] { "primary", "secondary" })
                            {
                                var win = GetDict(rateLimits, key);
                                if (win == null) continue;
                                double used = GetDouble(win, "used_percent");
                                int winMin = (int)GetInt64(win, "window_minutes");
                                if (winMin >= 240 && winMin <= 360)
                                { fiveHourUsed = used; fiveHourWindow = winMin; fiveHourResets = GetInt64OrNull(win, "resets_at"); }
                                else if (winMin >= 9000)
                                { weeklyUsed = used; weeklyWindow = winMin; weeklyResets = GetInt64OrNull(win, "resets_at"); }
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
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT * FROM file_metadata";
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    public static void UpdateFileMetadata(SQLiteConnection db, string path, long length, long lastWriteTicks, long parsedOffset)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "INSERT OR REPLACE INTO file_metadata (path, length, last_write_ticks, parsed_offset) VALUES (@p1,@p2,@p3,@p4)";
            cmd.Parameters.AddWithValue("@p1", path); cmd.Parameters.AddWithValue("@p2", length);
            cmd.Parameters.AddWithValue("@p3", lastWriteTicks); cmd.Parameters.AddWithValue("@p4", parsedOffset);
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

    // ── Helpers ─────────────────────────────────────────────────────────

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

    private static long GetInt64(Dictionary<string, object> d, string k)
    {
        object o; if (d.TryGetValue(k, out o)) { if (o is int) return (int)o; if (o is long) return (long)o; }
        return 0;
    }

    private static double GetDouble(Dictionary<string, object> d, string k)
    {
        object o; if (d.TryGetValue(k, out o)) { if (o is double) return (double)o; if (o is int) return (int)o; if (o is long) return (long)o; }
        return 0.0;
    }

    private static long? GetInt64OrNull(Dictionary<string, object> d, string k)
    {
        object o; if (d.TryGetValue(k, out o)) { if (o is int) return (int)o; if (o is long) return (long)o; }
        return null;
    }
}