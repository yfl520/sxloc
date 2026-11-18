namespace SuixingLoc.Core;

internal readonly record struct PhoneConnection(bool Running, bool Starting, bool Identified, bool Authenticated, bool Failed);

internal static class ApplyAvailability
{
    public const string NotConnected = "请先连接 iPhone，再应用定位。";

    public static string? BlockedReason(IEnumerable<PhoneConnection> sessions, string? usbPhase, bool usbFailed)
    {
        var phones = sessions.ToArray();
        // Subscription may start only after Maps requests a location. Authentication is sufficient.
        if (phones.Any(s => s.Running && !s.Starting && s.Identified && s.Authenticated && !s.Failed)
            || usbPhase == "simulating" && !usbFailed) return null;
        if (phones.Any(s => (s.Running || s.Starting) && !s.Failed)
            || usbPhase == "connecting" && !usbFailed)
            return "iPhone 正在连接或认证，请等待连接完成后再应用定位。";
        return NotConnected;
    }
}
