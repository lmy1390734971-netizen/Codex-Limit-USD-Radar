using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

/// <summary>
/// 零外部依赖的 JSONL → 内存索引引擎。使用 .NET Framework 内置类型
/// （JavaScriptSerializer for JSON 解析，泛型集合 for 存储，LINQ for 聚合），
/// 不需要 System.Data.SQLite 或 Newtonsoft.Json 等外部 DLL。
///
/// 编译：csc /target:library /reference:System.Web.Extensions.dll /optimize+ ...
/// </summary>
public static class TokenRaderIndexer
{
    // ── 数据模型 ─────────────────────────────────────────────────────────

    public class TokenRecord
    {
        public string SessionId;
        public string Timestamp;
        public string Model;
        public long TotalInput, TotalCached, TotalOutput, TotalReasoning;
        public long CallInput, CallCached, CallOutput, CallReasoning;
        public string Fingerprint;
        public double? FiveHourUsed;
        public int? FiveHourWindow;
        public long? FiveHourResets;
        public double? WeeklyUsed;
        public int? WeeklyWindow;
        public long? WeeklyResets;
        public string PlanType;
        // 文件跟踪（用于增量同步）
        public string FilePath;
        public long FileOffset; // 该记录所在字节偏移
    }

    public class FileMeta
    {
        public string Path;
        public long Length;
        public long LastWriteTicks;
        public long ParsedOffset;
    }

    // ── 正则（预编译加速） ─────────────────────────────────────────────────

    private static readonly Regex _turnContextModel = new Regex(
        @"""type""\s*:\s*""turn_context"".*?""model""\s*:\s*""([^""]+)""",
        RegexOptions.Compiled);

    private static readonly Regex _sessionIdFromPath = new Regex(
        @"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$",
        RegexOptions.Compiled);

    private static readonly JavaScriptSerializer _json = new JavaScriptSerializer();

    // ── 解析 ─────────────────────────────────────────────────────────────

    /// <summary>
    /// 增量解析一个 JSONL 文件。从 startOffset 字节偏移开始，返回新记录
    /// 列表和新文件偏移。
    /// </summary>
    public static void ParseFile(
        string filePath, long startOffset, string filePathCanonical,
        out List<TokenRecord> records, out long newOffset)
    {
        records = new List<TokenRecord>();
        newOffset = startOffset;
        long fileLength = new FileInfo(filePath).Length;

        using (var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete))
        using (var sr = new StreamReader(fs, Encoding.UTF8, detectEncodingFromByteOrderMarks: true))
        {
            // 跳到 startOffset
            if (startOffset > 0)
            {
                if (startOffset >= fileLength)
                {
                    newOffset = fileLength;
                    return;
                }

                fs.Seek(startOffset, SeekOrigin.Begin);
                int firstByte = fs.ReadByte();
                if (firstByte != '\n')
                {
                    sr.ReadLine();
                }
                else
                {
                    fs.Seek(startOffset, SeekOrigin.Begin);
                }
            }

            string currentModel = "";
            string line;
            while ((line = sr.ReadLine()) != null)
        {
            long lineEndOffset = fs.Position;
            if (string.IsNullOrWhiteSpace(line)) { newOffset = lineEndOffset; continue; }

            line = line.TrimStart('\uFEFF');

            // turn_context → 更新当前模型
            if (line.Contains("turn_context"))
            {
                var m = _turnContextModel.Match(line);
                if (m.Success) currentModel = m.Groups[1].Value;
                newOffset = lineEndOffset;
                continue;
            }

            // 不含 token_count → 跳过
            if (!line.Contains("token_count")) { newOffset = lineEndOffset; continue; }

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

                // 钳位：cached ≤ input
                if (totalCached > totalInput) totalCached = totalInput;
                if (callCached > callInput) callCached = callInput;

                // rate_limits
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
                        {
                            fiveHourUsed = used; fiveHourWindow = winMin;
                            fiveHourResets = GetInt64OrNull(win, "resets_at");
                        }
                        else if (winMin >= 9000)
                        {
                            weeklyUsed = used; weeklyWindow = winMin;
                            weeklyResets = GetInt64OrNull(win, "resets_at");
                        }
                    }
                }

                string sessionId = ExtractSessionId(filePath);
                string fingerprint = string.Format("{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}",
                    totalInput, totalCached, totalOutput, totalReasoning,
                    callInput, callCached, callOutput, callReasoning);

                records.Add(new TokenRecord
                {
                    SessionId = sessionId,
                    Timestamp = GetString(record, "timestamp") ?? "",
                    Model = currentModel,
                    TotalInput = totalInput, TotalCached = totalCached,
                    TotalOutput = totalOutput, TotalReasoning = totalReasoning,
                    CallInput = callInput, CallCached = callCached,
                    CallOutput = callOutput, CallReasoning = callReasoning,
                    Fingerprint = fingerprint,
                    FiveHourUsed = fiveHourUsed, FiveHourWindow = fiveHourWindow,
                    FiveHourResets = fiveHourResets,
                    WeeklyUsed = weeklyUsed, WeeklyWindow = weeklyWindow,
                    WeeklyResets = weeklyResets, PlanType = planType,
                    FilePath = filePathCanonical,
                    FileOffset = lineEndOffset,
                });

                newOffset = lineEndOffset;
            }
            catch { continue; }
        }

        return;
    }
    }

    // ── 文件元数据管理 ───────────────────────────────────────────────────

    /// <summary>
    /// 从磁盘读取文件元数据。返回 { path → FileMeta } 字典。
    /// </summary>
    public static Dictionary<string, FileMeta> LoadFileMeta(string metaPath)
    {
        var result = new Dictionary<string, FileMeta>(StringComparer.OrdinalIgnoreCase);
        if (!File.Exists(metaPath)) return result;
        try
        {
            string json = File.ReadAllText(metaPath, Encoding.UTF8);
            var list = _json.Deserialize<List<Dictionary<string, object>>>(json);
            if (list == null) return result;
            foreach (var d in list)
            {
                var fm = new FileMeta
                {
                    Path = GetString(d, "path") ?? "",
                    Length = GetInt64(d, "length"),
                    LastWriteTicks = GetInt64(d, "last_write_ticks"),
                    ParsedOffset = GetInt64(d, "parsed_offset"),
                };
                if (!string.IsNullOrEmpty(fm.Path))
                    result[fm.Path] = fm;
            }
        }
        catch { }
        return result;
    }

    /// <summary>
    /// 将文件元数据保存到磁盘。
    /// </summary>
    public static void SaveFileMeta(string metaPath, Dictionary<string, FileMeta> meta)
    {
        var list = new List<object>();
        foreach (var fm in meta.Values)
        {
            list.Add(new Dictionary<string, object>
            {
                { "path", fm.Path },
                { "length", fm.Length },
                { "last_write_ticks", fm.LastWriteTicks },
                { "parsed_offset", fm.ParsedOffset },
            });
        }
        string dir = Path.GetDirectoryName(metaPath);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
            Directory.CreateDirectory(dir);
        string json = _json.Serialize(list);
        File.WriteAllText(metaPath, json, Encoding.UTF8);
    }

    // ── 查询辅助 ─────────────────────────────────────────────────────────

    /// <summary>
    /// 从记录列表中提取最新一条（按时间戳降序）。
    /// </summary>
    public static TokenRecord LatestRecord(List<TokenRecord> records)
    {
        return records.OrderByDescending(r => r.Timestamp).FirstOrDefault();
    }

    /// <summary>
    /// 按模型+长上下文分组聚合，返回每组的总 input/cached/output 和调用次数。
    /// </summary>
    public static List<Dictionary<string, object>> AggregateByModel(
        List<TokenRecord> records, long longContextThreshold)
    {
        var groups = new Dictionary<string, AggBucket>();
        foreach (var r in records)
        {
            if (r.CallInput <= 0 && r.CallOutput <= 0) continue;
            string model = string.IsNullOrEmpty(r.Model) ? "unknown" : r.Model;
            bool longCtx = longContextThreshold > 0 && r.CallInput > longContextThreshold;
            string key = model.ToLowerInvariant() + "|" + (longCtx ? "long" : "standard");

            if (!groups.ContainsKey(key))
                groups[key] = new AggBucket { LongContext = longCtx };
            var g = groups[key];
            g.Input += r.CallInput;
            g.Cached += r.CallCached;
            g.Output += r.CallOutput;
            g.Reasoning += r.CallReasoning;
            g.Count++;
            g.Events++;
        }

        var result = new List<Dictionary<string, object>>();
        foreach (var kvp in groups)
        {
            var g = kvp.Value;
            var d = new Dictionary<string, object>();
            string m = kvp.Key.Contains('|') ? kvp.Key.Split('|')[0] : kvp.Key;
            d["model"] = m;
            d["longContext"] = g.LongContext;
            d["input"] = g.Input;
            d["cached"] = g.Cached;
            d["uncached"] = g.Input - g.Cached;
            d["output"] = g.Output;
            d["reasoning"] = g.Reasoning;
            d["count"] = g.Count;
            result.Add(d);
        }
        return result;
    }

    private class AggBucket
    {
        public long Input, Cached, Output, Reasoning, Count, Events;
        public bool LongContext;
    }

    /// <summary>
    /// 从记录中提取最新 rate_limits 快照。
    /// </summary>
    public static Dictionary<string, object> LatestRateLimits(List<TokenRecord> records)
    {
        double? fiveHourUsed = null; int? fiveHourWindow = null; long? fiveHourResets = null;
        double? weeklyUsed = null; int? weeklyWindow = null; long? weeklyResets = null;
        string planType = "";
        string latestObserved = "";

        foreach (var r in records)
        {
            if (r.FiveHourUsed == null && r.WeeklyUsed == null) continue;
            // 按时间戳取最新
            if (string.CompareOrdinal(r.Timestamp, latestObserved) <= 0) continue;
            latestObserved = r.Timestamp;
            planType = r.PlanType;
            if (r.FiveHourUsed != null) { fiveHourUsed = r.FiveHourUsed; fiveHourWindow = r.FiveHourWindow; fiveHourResets = r.FiveHourResets; }
            if (r.WeeklyUsed != null) { weeklyUsed = r.WeeklyUsed; weeklyWindow = r.WeeklyWindow; weeklyResets = r.WeeklyResets; }
        }

        return new Dictionary<string, object>
        {
            { "observedAt", latestObserved },
            { "planType", planType },
            { "fiveHourUsed", (object)fiveHourUsed ?? "" },
            { "fiveHourWindow", (object)fiveHourWindow ?? "" },
            { "fiveHourResets", (object)fiveHourResets ?? "" },
            { "weeklyUsed", (object)weeklyUsed ?? "" },
            { "weeklyWindow", (object)weeklyWindow ?? "" },
            { "weeklyResets", (object)weeklyResets ?? "" },
        };
    }

    // ── 辅助方法 ─────────────────────────────────────────────────────────

    private static string ExtractSessionId(string filePath)
    {
        string name = Path.GetFileNameWithoutExtension(filePath);
        var m = _sessionIdFromPath.Match(name);
        return m.Success ? m.Groups[1].Value.ToLowerInvariant() : name.ToLowerInvariant();
    }

    private static Dictionary<string, object> GetDict(Dictionary<string, object> dict, string key)
    {
        object obj;
        if (dict.TryGetValue(key, out obj))
            return obj as Dictionary<string, object>;
        return null;
    }

    private static string GetString(Dictionary<string, object> dict, string key)
    {
        object obj;
        if (dict.TryGetValue(key, out obj))
            return obj as string;
        return null;
    }

    private static long GetInt64(Dictionary<string, object> dict, string key)
    {
        object obj;
        if (dict.TryGetValue(key, out obj))
        {
            if (obj is int) return (int)obj;
            if (obj is long) return (long)obj;
        }
        return 0;
    }

    private static double GetDouble(Dictionary<string, object> dict, string key)
    {
        object obj;
        if (dict.TryGetValue(key, out obj))
        {
            if (obj is double) return (double)obj;
            if (obj is int) return (int)obj;
            if (obj is long) return (long)obj;
        }
        return 0.0;
    }

    private static long? GetInt64OrNull(Dictionary<string, object> dict, string key)
    {
        object obj;
        if (dict.TryGetValue(key, out obj))
        {
            if (obj is int) return (int)obj;
            if (obj is long) return (long)obj;
        }
        return null;
    }
}