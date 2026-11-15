using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SuixingLoc.Core;

internal static class DesktopUpdater
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    internal static string DownloadDirectory
    {
        get
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SuixingLoc", "updates");
            Directory.CreateDirectory(path);
            return path;
        }
    }

    internal sealed record Plan(string Current, string Staged, string Backup, int AppPid,
        long AppStarted, int CorePid, long CoreStarted, string Ready);

    internal static async Task<bool> Prepare(string package, string hash, int appPid, string version, int build)
    {
        if (!await Gate.WaitAsync(0)) throw new ArgumentException("更新正在准备，请稍候");
        string? staged = null;
        var helperStarted = false;
        try
        {
            var file = Path.GetFullPath(package);
            if (!file.StartsWith(DownloadDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                Path.GetFileName(file) != "sxloc-windows-x64.zip" || !File.Exists(file) ||
                new FileInfo(file).Length is <= 0 or > 2147483648L || !Regex.IsMatch(hash, "^[a-fA-F0-9]{64}$"))
                throw new ArgumentException("更新文件无效，请重新下载");
            if (!Regex.IsMatch(version, "^\\d+\\.\\d+\\.\\d+$") || build <= 0)
                throw new ArgumentException("更新版本无效");
            var core = Path.GetFullPath(Environment.ProcessPath ?? "");
            var current = Directory.GetParent(Path.GetDirectoryName(core)!)?.FullName
                ?? throw new ArgumentException("请从完整的桌面版目录更新");
            if (!Path.GetFileName(core).Equals("SuixingLoc.Core.exe", StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Path.GetFileName(Path.GetDirectoryName(core)), "core", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("请在编译完成的桌面版中进行更新");
            using var app = Process.GetProcessById(appPid);
            if (!string.Equals(app.MainModule?.FileName, Path.Combine(current, "随行定位.exe"), StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("更新目标与当前应用不匹配");
            var installedMarker = Path.Combine(current, "app_info.json");
            if (File.Exists(installedMarker))
            {
                using var info = JsonDocument.Parse(await File.ReadAllTextAsync(installedMarker));
                var installed = info.RootElement;
                var comparison = Version.Parse(version).CompareTo(Version.Parse(installed.GetProperty("version").GetString()!));
                if (comparison < 0 || comparison == 0 && build <= installed.GetProperty("buildNumber").GetInt32())
                    throw new ArgumentException("此更新不比当前版本新，请重新检查更新");
            }
            await using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
            var digest = Convert.ToHexString(await SHA256.HashDataAsync(input));
            if (!digest.Equals(hash, StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("更新文件校验失败，请重新下载");
            input.Position = 0;
            var id = Guid.NewGuid().ToString("N");
            staged = Path.Combine(Directory.GetParent(current)!.FullName, ".sxloc-update-" + id);
            try { Directory.CreateDirectory(staged); }
            catch (UnauthorizedAccessException) { throw new ArgumentException("当前应用目录无法写入，请将整个应用移到有写入权限的文件夹后更新"); }
            await Task.Run(() => ExtractChecked(input, staged, version, build));
            var helperDirectory = Path.Combine(DownloadDirectory, "helper-" + id);
            Directory.CreateDirectory(helperDirectory);
            var helper = Path.Combine(helperDirectory, "SuixingLoc.Update.exe");
            File.Copy(core, helper);
            var planPath = Path.Combine(helperDirectory, "plan.json");
            var ready = Path.Combine(helperDirectory, "ready");
            using var self = Process.GetCurrentProcess();
            var plan = new Plan(current, staged, current + ".backup-" + id, app.Id,
                app.StartTime.ToUniversalTime().Ticks, self.Id, self.StartTime.ToUniversalTime().Ticks, ready);
            await File.WriteAllTextAsync(planPath, JsonSerializer.Serialize(plan));
            var start = new ProcessStartInfo(helper) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = helperDirectory };
            start.ArgumentList.Add("--apply-update");
            start.ArgumentList.Add(planPath);
            using var process = Process.Start(start) ?? throw new ArgumentException("无法启动更新助手");
            for (var i = 0; i < 100 && !process.HasExited && !File.Exists(ready); i++) await Task.Delay(100);
            if (!File.Exists(ready))
            {
                if (!process.HasExited) process.Kill();
                throw new ArgumentException("更新助手未能就绪，应用尚未退出，请稍后重试");
            }
            helperStarted = true;
            return true;
        }
        finally
        {
            if (!helperStarted && staged is not null && Directory.Exists(staged))
            {
                try { Directory.Delete(staged, true); } catch { }
            }
            if (!helperStarted) Gate.Release();
        }
    }

    internal static void ExtractChecked(Stream package, string staged, string version, int build)
    {
        using var archive = new ZipArchive(package, ZipArchiveMode.Read, leaveOpen: true);
        if (archive.Entries.Count is 0 or > 100000) throw new ArgumentException("更新压缩包内容数量异常");
        long total = 0;
        var destinations = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in archive.Entries)
        {
            var name = entry.FullName.Replace('\\', '/');
            if (name == "随行定位/") continue;
            if (!name.StartsWith("随行定位/", StringComparison.Ordinal) ||
                name.Contains(':') || name.Contains('\0') ||
                name.Split('/').Any(s => s is ".." or "." || s.EndsWith(' ') || s.EndsWith('.')) ||
                ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000 ||
                (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0)
                throw new ArgumentException("更新包包含无效文件路径");
            var relative = name["随行定位/".Length..];
            var target = Path.GetFullPath(Path.Combine(staged, relative));
            if (!target.StartsWith(staged + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !destinations.Add(target))
                throw new ArgumentException("更新包包含重复或越界路径");
            total = checked(total + entry.Length);
            if (total > 8L * 1024 * 1024 * 1024) throw new ArgumentException("更新包解压后超出大小限制");
            if (name.EndsWith('/')) Directory.CreateDirectory(target);
            else
            {
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                entry.ExtractToFile(target, overwrite: false);
            }
        }
        foreach (var required in new[] { "随行定位.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat",
                     "data/flutter_assets/AssetManifest.bin", "core/SuixingLoc.Core.exe", "core/usb/python.exe", "app_info.json" })
            if (!File.Exists(Path.Combine(staged, required))) throw new ArgumentException("更新包缺少必要文件，请联系维护者");
        var marker = new FileInfo(Path.Combine(staged, "app_info.json"));
        if (marker.Length > 65536) throw new ArgumentException("更新包版本信息异常");
        using var document = JsonDocument.Parse(File.ReadAllText(marker.FullName));
        var info = document.RootElement;
        if (info.GetProperty("schemaVersion").GetInt32() != 1 || info.GetProperty("platform").GetString() != "windows-x64" ||
            info.GetProperty("version").GetString() != version || info.GetProperty("buildNumber").GetInt32() != build)
            throw new ArgumentException("更新包版本与发布说明不一致");
    }

    internal static async Task RunHelper(string path)
    {
        Plan? plan = null;
        var replaced = false;
        var oldMoved = false;
        var processesExited = false;
        try
        {
            plan = JsonSerializer.Deserialize<Plan>(await File.ReadAllTextAsync(path)) ?? throw new ArgumentException("更新计划无效");
            var parent = Directory.GetParent(plan.Current)?.FullName;
            if (parent is null || Directory.GetParent(plan.Staged)?.FullName != parent ||
                !Path.GetFileName(plan.Staged).StartsWith(".sxloc-update-", StringComparison.Ordinal) ||
                !plan.Backup.StartsWith(plan.Current + ".backup-", StringComparison.Ordinal) ||
                !File.Exists(Path.Combine(plan.Staged, "随行定位.exe"))) throw new ArgumentException("更新目录校验失败");
            await File.WriteAllTextAsync(plan.Ready, "ready");
            await Task.WhenAll(WaitForExit(plan.AppPid, plan.AppStarted), WaitForExit(plan.CorePid, plan.CoreStarted));
            processesExited = true;
            Directory.Move(plan.Current, plan.Backup);
            oldMoved = true;
            Directory.Move(plan.Staged, plan.Current);
            replaced = true;
            using var app = StartApp(plan.Current);
            await Task.Delay(3000);
            if (app.HasExited && app.ExitCode != 0) throw new IOException("新版本未能启动");
        }
        catch (Exception error)
        {
            var restored = false;
            if (plan is not null && oldMoved)
            {
                try
                {
                    if (replaced && Directory.Exists(plan.Current)) Directory.Move(plan.Current, plan.Current + ".failed-" + Guid.NewGuid().ToString("N"));
                    Directory.Move(plan.Backup, plan.Current);
                    using var app = StartApp(plan.Current);
                    restored = true;
                }
                catch { }
            }
            else if (plan is not null && processesExited && File.Exists(Path.Combine(plan.Current, "随行定位.exe")))
            {
                try { using var app = StartApp(plan.Current); restored = true; } catch { }
            }
            MessageBox(IntPtr.Zero, restored ? "更新失败，已恢复旧版本。\n" + error.Message
                : "更新未完成。旧版文件未删除，请检查应用目录或 backup 备份文件夹。\n" + error.Message,
                "随行定位 · 更新", 0x10);
        }
    }

    private static Process StartApp(string directory) => Process.Start(new ProcessStartInfo(Path.Combine(directory, "随行定位.exe"))
        { WorkingDirectory = directory, UseShellExecute = true }) ?? throw new IOException("无法重新打开随行定位");

    private static async Task WaitForExit(int id, long started)
    {
        Process process;
        try { process = Process.GetProcessById(id); } catch (ArgumentException) { return; }
        using (process)
        {
            try { if (process.StartTime.ToUniversalTime().Ticks != started) return; }
            catch (InvalidOperationException) { return; }
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
            await process.WaitForExitAsync(timeout.Token);
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr owner, string message, string title, uint type);
}
