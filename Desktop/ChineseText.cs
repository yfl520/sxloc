using System.IO;
using System.Net.Http;
using System.Text.RegularExpressions;

namespace Iap2Loc.Desktop;

internal static class ChineseText
{
    public static string Error(Exception exception)
    {
        if (exception is Iap2Loc.Engine.ConfigurationSaveException) return exception.Message;
        var ex = exception.GetBaseException();
        return ex switch
        {
            FileNotFoundException => "未找到所需文件，请检查文件位置或重新导入身份",
            DirectoryNotFoundException => "指定目录不存在，请重新选择",
            UnauthorizedAccessException => "无法写入文件，请检查目录权限",
            System.Security.Cryptography.CryptographicException => "身份或密钥无法读取，请在当前 Windows 用户下重新导入",
            HttpRequestException => "网络连接失败，请检查网络后重试",
            TaskCanceledException or OperationCanceledException => "操作已取消或超时",
            _ => Log(ex.Message),
        };
    }

    public static string Log(string text)
    {
        var replacements = new (string From, string To)[]
        {
            ("StartIdentification", "开始身份识别"), ("IdentificationInformation", "配件识别信息"),
            ("IdentificationAccepted", "身份识别通过"), ("IdentificationRejected", "身份识别被拒绝"),
            ("RequestAuthenticationCertificate", "请求认证证书"), ("AuthenticationSucceeded", "认证通过"),
            ("AuthenticationFailed: the phone rejected the certificate or the signature", "认证失败：设备拒绝证书或签名"),
            ("StartLocationInformation", "设备已订阅定位"), ("StopLocationInformation", "设备停止订阅定位"),
            ("transport read failed", "传输读取失败"), ("transport closed by the peer", "设备已关闭连接"),
            ("the device did not answer the iAP2 detect marker", "设备未响应 iAP2 探测"),
            ("the device reset the iAP2 link", "设备重置了 iAP2 链路"),
            ("iAP2 detect timed out", "iAP2 设备探测超时"), ("iAP2 negotiation timed out", "iAP2 协议协商超时"),
            ("iAP2 acknowledge timed out", "设备确认超时，连接已中断"),
            ("iAP2 link is closed", "iAP2 链路已关闭"), ("control session lost the 0x4040 marker", "控制消息标记错误"),
            ("header checksum mismatch, dropped", "包头校验失败，已丢弃"), ("payload checksum mismatch, dropped", "数据校验失败，已丢弃"),
            ("offending parameters", "被拒绝的参数"), ("raw parameters", "原始参数"),
            ("transport 17", "蓝牙传输组件 17"), ("present", "存在"), ("absent", "缺失"),
            ("sending 0xFFFB failed", "定位数据发送失败"), ("streaming", "开始发送"),
            ("sentence(s)", "条语句"), ("sentences", "语句"), ("requested", "请求周期"),
            ("sending every", "发送周期"), (" ms NMEA for ", " 毫秒，NMEA 目标 "),
            (" bytes)", " 字节)"), ("challenge", "认证挑战"), ("signature", "签名"),
            ("rx ", "收到 "), ("tx ", "发送 "), ("handling ", "处理 "),
            (" failed:", "失败："), ("but no identity was given", "但未配置身份材料"),
            ("authentication cannot succeed", "无法完成认证"), ("without a challenge in parameter 0", "缺少参数 0 中的认证挑战"),
        };
        foreach (var (from, to) in replacements) text = text.Replace(from, to, StringComparison.Ordinal);
        // Never display key-bearing service URLs in diagnostic output.
        text = Regex.Replace(text, @"(?i)(key=)[^&\s]+", "$1[已隐藏]");
        return text;
    }
}
