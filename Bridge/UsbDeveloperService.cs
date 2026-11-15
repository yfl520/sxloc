using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using Iap2Loc.Protocol;

namespace SuixingLoc.Core;

/// <summary>Owns the optional isolated USB runtime; snapshots never wait on device I/O.</summary>
internal sealed class UsbDeveloperService : IAsyncDisposable
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private readonly object gate = new();
    private readonly SemaphoreSlim startup = new(1, 1);
    private readonly SemaphoreSlim writes = new(1, 1);
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> pending = new();
    private Process? process;
    private Task? exitTask;
    private SafeFileHandle? job;
    private int next;
    private bool disposed;
    private TargetState? target;
    private JsonElement state = JsonSerializer.SerializeToElement(new { phase = "idle", status = "尚未连接" });

    public JsonElement Snapshot() { lock (gate) return state; }

    public void Remember(TargetState value)
    {
        lock (gate)
        {
            if (target is null || value.Revision >= target.Revision) target = value;
        }
    }

    public async Task UpdateTarget(TargetState value)
    {
        Remember(value);
        Process? current;
        lock (gate) current = process;
        if (current is null || current.HasExited) return;
        try { await SendTarget(); }
        catch (Exception ex) { SetFailure(ex.Message, exited: false); }
    }

    private Task<JsonElement> SendTarget()
    {
        TargetState current;
        lock (gate) current = target ?? throw new InvalidOperationException("请先保存目标位置。");
        return Request("target", new { latitude = current.ResolvedLatitude, longitude = current.ResolvedLongitude, current.Revision });
    }

    public async Task<JsonElement> Devices()
    {
        await EnsureStarted();
        return await Request("devices", new { });
    }

    public async Task<bool> Connect(string udid)
    {
        await EnsureStarted();
        await SendTarget();
        await Request("connect", new { udid });
        return true;
    }

    public async Task<JsonElement> RevealDeveloperMode(string udid)
    {
        await EnsureStarted();
        return await Request("revealDeveloperMode", new { udid });
    }

    public async Task<bool> Stop()
    {
        Process? current;
        lock (gate) current = process;
        if (current is not null && !current.HasExited) await Request("stop", new { });
        return true;
    }

    public async Task<bool> ClearError()
    {
        Process? current;
        lock (gate) current = process;
        if (current is not null && !current.HasExited) await Request("clearError", new { });
        else lock (gate)
        {
            var values = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(state.GetRawText())!;
            values["phase"] = JsonSerializer.SerializeToElement("idle");
            values["error"] = JsonSerializer.SerializeToElement<string?>(null);
            values["status"] = JsonSerializer.SerializeToElement("尚未连接");
            state = JsonSerializer.SerializeToElement(values);
        }
        return true;
    }

    private async Task EnsureStarted()
    {
        await startup.WaitAsync();
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (process is { HasExited: false }) return;
            if (exitTask is not null) await exitTask;
            process?.Dispose();
            job?.Dispose();
            var directory = Path.Combine(AppContext.BaseDirectory, "usb");
            var executable = Path.Combine(directory, "python.exe");
            if (!File.Exists(executable) || !File.Exists(Path.Combine(directory, "worker.py")))
                throw new InvalidOperationException("USB 开发者组件缺失，请使用完整测试目录。");
            var info = new ProcessStartInfo(executable)
            {
                WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            info.ArgumentList.Add("-u");
            info.ArgumentList.Add("-X");
            info.ArgumentList.Add("utf8");
            info.ArgumentList.Add(Path.Combine(directory, "worker.py"));
            info.Environment["PYTHONIOENCODING"] = "utf-8";
            info.Environment["PYTHONUTF8"] = "1";
            var child = Process.Start(info) ?? throw new IOException("USB 开发者组件启动失败。");
            try { job = CreateChildJob(child); }
            catch { child.Kill(true); child.Dispose(); throw; }
            lock (gate) process = child;
            var outputTask = ReadOutput(child);
            _ = DrainErrors(child);
            exitTask = WatchExit(child, outputTask);
        }
        finally { startup.Release(); }
    }

    private async Task<JsonElement> Request(string method, object args)
    {
        var id = Interlocked.Increment(ref next);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = completion;
        try
        {
            await writes.WaitAsync();
            try
            {
                var child = process ?? throw new IOException("USB 开发者组件尚未启动。");
                await child.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { id, method, args }, Json));
                await child.StandardInput.FlushAsync();
            }
            finally { writes.Release(); }
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(23));
        }
        catch (TimeoutException) { throw new IOException("USB 组件响应超时，请停止连接后重试。"); }
        finally { pending.TryRemove(id, out _); }
    }

    private async Task ReadOutput(Process child)
    {
        try
        {
            while (await child.StandardOutput.ReadLineAsync() is { } line)
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (root.TryGetProperty("event", out var evt) && evt.GetString() == "state")
                {
                    lock (gate) state = root.GetProperty("state").Clone();
                }
                else if (root.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.Number &&
                         pending.TryRemove(id.GetInt32(), out var completion))
                {
                    if (root.TryGetProperty("error", out var error))
                        completion.TrySetException(new InvalidOperationException(error.GetString()));
                    else completion.TrySetResult(root.GetProperty("result").Clone());
                }
            }
        }
        catch (Exception) { if (!disposed) SetFailure("USB 组件通信中断，请重新连接。"); }
    }

    private static async Task DrainErrors(Process child)
    {
        // Third-party traces may contain device identifiers; never echo them into UI logs.
        try { while (await child.StandardError.ReadLineAsync() is not null) { } }
        catch (Exception) { }
    }

    private async Task WatchExit(Process child, Task outputTask)
    {
        await child.WaitForExitAsync();
        await outputTask;
        foreach (var item in pending) if (pending.TryRemove(item.Key, out var completion))
            completion.TrySetException(new IOException("USB 开发者组件已退出，请重新连接。"));
        if (!disposed) SetFailure("USB 开发者组件已退出，请重新连接；若曾提交定位，停止模拟状态未确认。");
    }

    private void SetFailure(string message, bool exited = true)
    {
        lock (gate)
        {
            var values = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(state.GetRawText())!;
            if (exited) values["phase"] = JsonSerializer.SerializeToElement("error");
            if (exited && values.TryGetValue("lastRevision", out var revision) && revision.ValueKind == JsonValueKind.Number)
                values["restoreWarning"] = JsonSerializer.SerializeToElement("USB 组件已中断，停止模拟状态未确认；请重新连接后再停止模拟。");
            values["error"] = JsonSerializer.SerializeToElement(message);
            state = JsonSerializer.SerializeToElement(values);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await startup.WaitAsync();
        try
        {
            if (disposed) return;
            disposed = true;
            if (process is { HasExited: false } child)
            {
                try
                {
                    await Request("shutdown", new { }).WaitAsync(TimeSpan.FromSeconds(14));
                    child.StandardInput.Close();
                    await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
                    if (exitTask is not null) await exitTask;
                }
                catch (Exception) { if (!child.HasExited) child.Kill(true); }
            }
            job?.Dispose(); // Also kills the child on an unexpected core exit.
            process?.Dispose();
        }
        finally { startup.Release(); }
    }

    private static SafeFileHandle CreateChildJob(Process child)
    {
        var handle = CreateJobObject(IntPtr.Zero, null);
        if (handle.IsInvalid) throw new IOException("无法创建 USB 组件生命周期管理器。");
        var info = new JobExtendedLimits { BasicLimitInformation = new JobBasicLimits { LimitFlags = 0x2000 } };
        if (!SetInformationJobObject(handle, 9, ref info, (uint)Marshal.SizeOf<JobExtendedLimits>()) ||
            !AssignProcessToJobObject(handle, child.Handle))
        {
            handle.Dispose();
            throw new IOException("无法管理 USB 组件进程，请检查 Windows 进程权限。");
        }
        return handle;
    }

    [StructLayout(LayoutKind.Sequential)] private struct JobBasicLimits
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong A, B, C, D, E, F; }
    [StructLayout(LayoutKind.Sequential)] private struct JobExtendedLimits
    {
        public JobBasicLimits BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref JobExtendedLimits info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
}
