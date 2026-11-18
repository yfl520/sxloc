using System.IO;
using System.Text.Json;
using Iap2Loc.Desktop;
using Iap2Loc.Engine;

internal static class PersistenceRegression
{
    public static Task Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "SuixingLoc-persistence", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var originalData = Environment.GetEnvironmentVariable("SUIXING_DATA");
        Environment.SetEnvironmentVariable("SUIXING_DATA", root);
        try
        {
            var path = Path.Combine(root, "favorites.json");
            var config = AppConfig.Load(path);
            var zero = config.AddFavorite("零点", 0, 0, 0, 1);
            config.AddFavorite("第二点", 31, 121, 10, 5);
            Check(AppConfig.Load(path).Favorites.Count == 2, "正常收藏未恢复");
            var previous = File.ReadAllText(path);
            var profile = config.Accessory;
            using (var locked = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                Fails(() => config.AddFavorite("失败", 32, 122, 10, 5));
                Check(config.Favorites.Count == 2, "添加失败仍改变收藏");
                Fails(() => config.RemoveFavorite(zero.Id));
                Check(config.Favorites.Any(f => f.Id == zero.Id), "删除失败仍移除收藏");
                Fails(() => config.RotateIdentity(null));
                Check(config.Accessory == profile, "旋转失败仍改变身份");
                Fails(() => config.PrepareForRun(null));
                Check(config.Accessory == profile, "启动保存失败仍改变身份");
            }
            Check(File.ReadAllText(path) == previous, "保存失败破坏原文件");
            Check(!Directory.EnumerateFiles(root, "*.tmp").Any(), "失败临时文件没有清理");
            foreach (var point in new[] { (double.NaN, 1d), (91d, 1d), (0d, 181d) })
                Fails(() => config.AddFavorite("非法", point.Item1, point.Item2, 10, 5));
            Fails(() => config.AddFavorite("非法", 0, 0, double.PositiveInfinity, 5));
            Check(config.Favorites.Count == 2, "无效收藏改变了内存");

            File.WriteAllText(path, "{损坏");
            var recovered = AppConfig.Load(path);
            Check(recovered.Favorites.Count == 1 && recovered.LoadWarning is not null, "未恢复上一份收藏");
            recovered.PrepareForRun(null);
            Check(Directory.EnumerateFiles(root, "favorites.json.corrupt-*").Any(p => File.ReadAllText(p) == "{损坏"), "未保留损坏原件");
            Check(AppConfig.Load(path + ".bak").Favorites.Count == 1, "恢复后的首次保存破坏有效备份");
            File.WriteAllText(path, "null");
            Check(AppConfig.Load(path).Favorites.Count == 1, "空配置未恢复备份");
            var freshPath = Path.Combine(root, "no-backup.json");
            File.WriteAllText(freshPath, "{损坏");
            AppConfig.Load(freshPath).PrepareForRun(null);
            Check(Directory.EnumerateFiles(root, "no-backup.json.corrupt-*").Any(), "无备份损坏文件被覆盖");

            var settings = new DesktopSettings { Latitude = 12, SearchCity = "上海", SearchHistory = ["旧历史"] };
            settings.AmapKey = "fake-regression-key";
            settings.Save();
            var next = settings.Copy(); next.Latitude = 40; next.SearchCity = "北京";
            using (var locked = new FileStream(DesktopSettings.SettingsPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                Fails(() => settings.Commit(next));
                Check(settings.Latitude == 12 && settings.SearchCity == "上海", "提交失败改变当前设置");
                Check(!settings.RememberSearch("新历史") && settings.SearchHistory.SequenceEqual(new[] { "旧历史" }), "历史保存失败影响内存");
            }
            Check(DesktopSettings.Load().SearchCity == "上海", "失败提交覆盖已有设置");
            next.Rate = -1; next.Save();
            var partial = DesktopSettings.Load();
            Check(partial.Rate == 250 && partial.SearchCity == "北京" && partial.AmapKey == "fake-regression-key", "单字段错误丢失其他设置");
            File.WriteAllText(DesktopSettings.SettingsPath, """{"Latitude":"错误","SearchCity":"广州","Rate":123,"ProtectedAmapKey":"无效密文"}""");
            partial = DesktopSettings.Load();
            Check(partial.Latitude == 31.2304 && partial.Rate == 123 && partial.SearchCity == "广州", "字段类型错误丢失可用字段");
            Check(partial.LoadWarning?.Contains("Key 无法解密") == true, "Key 解密失败缺少提示");
            File.WriteAllText(DesktopSettings.SettingsPath, "{损坏");
            partial = DesktopSettings.Load();
            Check(partial.SearchCity == "上海" && partial.LoadWarning is not null, "桌面配置未恢复有效备份");
            partial.Save();
            using var parsed = JsonDocument.Parse(File.ReadAllText(DesktopSettings.SettingsPath));
            Check(!Directory.EnumerateFiles(root, "*.tmp").Any(), "留下临时文件");
            Console.WriteLine("PASS: 收藏写入失败回滚、原件保护、损坏恢复、字段容错与设置提交故障回归");
        }
        finally
        {
            Environment.SetEnvironmentVariable("SUIXING_DATA", originalData);
            Directory.Delete(root, true);
        }
        return Task.CompletedTask;
    }

    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static void Fails(Action action)
    {
        try { action(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { return; }
        throw new Exception("预期的失败未发生");
    }
}
