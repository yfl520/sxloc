using System.Windows;
using System.Windows.Controls;

namespace Iap2Loc.Desktop;

public sealed class HelpWindow : Window
{
    public HelpWindow()
    {
        Title = "使用说明 · 随行定位"; Width = 590; Height = 650; MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterOwner; ShowInTaskbar = false;
        var panel = new StackPanel { Margin = new Thickness(25) };
        panel.Children.Add(new TextBlock { Text = "开始使用随行定位", FontSize = 23, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0,0,0,15) });
        Add(panel, "1  配对 iPhone", "在 Windows 蓝牙设置中完成配对，并保持手机唤醒。返回本应用点击刷新，选择设备后连接。");
        Add(panel, "2  选择目标位置", "搜索地名、详细地址或直接输入“纬度,经度”。搜索结果或地图点选只改变待应用坐标，点击“应用定位”后才生效。Ctrl+Enter 也可应用。");
        Add(panel, "3  查看设备状态", "程序依次进行连接、协议握手、配件识别和认证。设备订阅定位后才发送数据。已发送计数不代表 iOS 一定采用该位置。");
        Add(panel, "4  检查设备端位置", "以 iPhone 地图中的定位为准。若仍显示原位置，可按上游说明尝试关闭 Wi-Fi、蜂窝数据与定位服务，稍等后先打开定位服务和地图，待位置稳定再恢复网络；不同系统的结果可能不同。");
        Add(panel, "搜索与坐标", "开放地图无需 Key，地名覆盖随地区变化；国内详细地址建议在设置中配置高德 Web 服务 Key。手动坐标默认 WGS-84；搜索框可使用 gcj:纬度,经度 输入高德坐标，程序会自动转换。");
        Add(panel, "身份与数据", "本地内置实验身份取自 DiPlay v0.2.22 公开 APK。也支持导入包含 offline-mfi 的 APK，或同目录的 identity.pk8 / certificate.p7b。导入材料按当前 Windows 用户加密保存。配置和收藏位于应用数据目录，不放在 EXE 旁边。");
        Add(panel, "关闭与诊断", "关闭窗口会停止定位会话并释放蓝牙连接。诊断日志可导出，默认不会打印私钥或地图 Key。高级参数中的速度和航向只改变上报字段，不会自动生成行走路线。");
        Add(panel, "开源信息", "基于 D1ngtalk/iap2loc，GPL-3.0。地图使用 Leaflet，版权和许可证随发布包提供。地图与地点搜索需要网络；搜索词会发送给所选服务。");
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
    private static void Add(Panel panel, string title, string text)
    {
        panel.Children.Add(new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0,10,0,7) });
        panel.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = System.Windows.Media.Brushes.DimGray, LineHeight = 21 });
    }
}

internal sealed class NameDialog : Window
{
    private readonly TextBox _name;
    public string FavoriteName => _name.Text.Trim();
    public NameDialog(string name)
    {
        Title = "收藏位置"; Width = 380; Height = 205; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "给这个位置起个名字", FontSize = 15, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0,0,0,13) });
        _name = new TextBox { Text = name, MaxLength = 80 };
        panel.Children.Add(_name);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0,15,0,0) };
        var cancel = new Button { Content = "取消", IsCancel = true };
        var save = new Button { Content = "保存收藏", IsDefault = true, Style = (Style)FindResource("PrimaryButton") };
        save.Click += (_, _) => { if (FavoriteName.Length > 0) DialogResult = true; else _name.Focus(); };
        buttons.Children.Add(cancel); buttons.Children.Add(save); panel.Children.Add(buttons); Content = panel;
        Loaded += (_, _) => { _name.Focus(); _name.SelectAll(); };
    }
}
