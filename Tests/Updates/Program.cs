using System.IO.Compression;
using System.Text.Json;
using SuixingLoc.Core;

var directory = Path.Combine(Path.GetTempPath(), "sxloc-update-regression-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(directory);
var passed = 0;
try
{
    Check("complete bundle accepted", null, false);
    Check("path traversal rejected", "随行定位/../escaped.txt", true);
    Check("absolute path rejected", "C:/escaped.txt", true);
    Check("alternate stream rejected", "随行定位/core/file:stream", true);
    Check("wrong top level rejected", "unrelated/file", true);
    Check("case-insensitive duplicate rejected", "随行定位/FLUTTER_WINDOWS.DLL", true);
    Check("trailing-dot alias rejected", "随行定位/core/alias.", true);
    Check("missing required file rejected", null, true, omit: "随行定位/core/usb/python.exe");
    Check("wrong bundle version rejected", null, true, version: "1.0.0");
    Check("symlink rejected", "随行定位/core/link", true, symlink: true);
    Console.WriteLine($"Windows update extraction: {passed} passed; no process launched or real app files modified.");
    return 0;
}
finally { Directory.Delete(directory, recursive: true); }

void Check(string title, string? extra, bool rejected, string? omit = null, string version = "1.1.5", bool symlink = false)
{
    using var bytes = new MemoryStream();
    using (var zip = new ZipArchive(bytes, ZipArchiveMode.Create, leaveOpen: true))
    {
        foreach (var name in new[] { "随行定位.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat",
                     "data/flutter_assets/AssetManifest.bin", "core/SuixingLoc.Core.exe", "core/usb/python.exe", "app_info.json" })
        {
            var path = "随行定位/" + name;
            if (path == omit) continue;
            var entry = zip.CreateEntry(path);
            using var writer = new StreamWriter(entry.Open());
            writer.Write(name == "app_info.json" ? JsonSerializer.Serialize(new { schemaVersion = 1,
                platform = "windows-x64", version, buildNumber = 10 }) : "placeholder, never executed");
        }
        if (extra is not null)
        {
            var entry = zip.CreateEntry(extra);
            if (symlink) entry.ExternalAttributes = unchecked((int)(0xA1FFu << 16));
            using var writer = new StreamWriter(entry.Open());
            writer.Write("placeholder");
        }
    }
    bytes.Position = 0;
    var stage = Path.Combine(directory, "case-" + passed);
    Directory.CreateDirectory(stage);
    var failed = false;
    try { DesktopUpdater.ExtractChecked(bytes, stage, "1.1.5", 10); }
    catch (ArgumentException) { failed = true; }
    if (failed != rejected) throw new Exception(title + " failed");
    if (File.Exists(Path.Combine(directory, "escaped.txt"))) throw new Exception("Archive escaped staging root");
    passed++;
}
