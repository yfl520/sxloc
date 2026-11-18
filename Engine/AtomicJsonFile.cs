using System.Text;
using System.Text.Json;

namespace Iap2Loc.Engine;

// A completed rename is the commit point. Keep the previous valid document for recovery.
internal static class AtomicJsonFile
{
    public static void Write(string path, string contents)
    {
        try { WriteCore(path, contents); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new ConfigurationSaveException(ex);
        }
    }

    private static void WriteCore(string path, string contents)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                var bytes = Encoding.UTF8.GetBytes(contents);
                stream.Write(bytes);
                stream.Flush(true);
            }
            if (File.Exists(path))
            {
                var validPrevious = true;
                try { using var previous = JsonDocument.Parse(File.ReadAllText(path)); }
                catch (JsonException) { Preserve(path); validPrevious = false; }
                if (validPrevious) File.Replace(temporary, path, path + ".bak");
                else File.Move(temporary, path, true);
            }
            else File.Move(temporary, path);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public static string Preserve(string path)
    {
        var backup = path + $".corrupt-{DateTime.UtcNow:yyyyMMddHHmmss}-{Guid.NewGuid():N}";
        File.Copy(path, backup);
        return backup;
    }

    public static T? Read<T>(string path, Func<string, T> parse, out string? warning) where T : class
    {
        warning = null;
        string contents;
        try { contents = File.ReadAllText(path); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        try { return parse(contents); }
        catch (Exception ex) when (ex is JsonException or ArgumentException)
        {
            // If preserving the original fails, stop instead of overwriting the only copy.
            Preserve(path);
            warning = "本地配置损坏，已保留原文件副本，暂用默认值。";
            if (File.Exists(path + ".bak"))
            {
                try
                {
                    var recovered = parse(File.ReadAllText(path + ".bak"));
                    warning = "本地配置损坏，已保留原文件副本，并恢复上一次保存的数据。";
                    return recovered;
                }
                catch (Exception backupError) when (backupError is JsonException or ArgumentException) { }
            }
            return null;
        }
    }
}

internal sealed class ConfigurationSaveException(Exception inner)
    : IOException("本地配置保存失败，请检查磁盘空间和目录权限后重试。", inner);
