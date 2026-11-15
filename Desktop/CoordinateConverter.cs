namespace Iap2Loc.Desktop;

internal static class CoordinateConverter
{
    private const double Axis = 6378245.0;
    private const double Eccentricity = 0.00669342162296594323;
    public static (double Lat, double Lon) WgsToGcj(double lat, double lon)
    {
        if (!(lon > 73.66 && lon < 135.05 && lat > 3.86 && lat < 53.55)) return (lat, lon);
        var x = lon - 105; var y = lat - 35;
        var a = -100 + 2*x + 3*y + 0.2*y*y + 0.1*x*y + 0.2*Math.Sqrt(Math.Abs(x));
        a += (20*Math.Sin(6*x*Math.PI) + 20*Math.Sin(2*x*Math.PI))*2/3;
        a += (20*Math.Sin(y*Math.PI) + 40*Math.Sin(y/3*Math.PI))*2/3;
        a += (160*Math.Sin(y/12*Math.PI) + 320*Math.Sin(y*Math.PI/30))*2/3;
        var b = 300 + x + 2*y + 0.1*x*x + 0.1*x*y + 0.1*Math.Sqrt(Math.Abs(x));
        b += (20*Math.Sin(6*x*Math.PI) + 20*Math.Sin(2*x*Math.PI))*2/3;
        b += (20*Math.Sin(x*Math.PI) + 40*Math.Sin(x/3*Math.PI))*2/3;
        b += (150*Math.Sin(x/12*Math.PI) + 300*Math.Sin(x/30*Math.PI))*2/3;
        var rad = lat / 180*Math.PI;
        var magic = 1 - Eccentricity*Math.Pow(Math.Sin(rad), 2);
        return (lat + a*180 / ((Axis*(1-Eccentricity))/(magic*Math.Sqrt(magic))*Math.PI),
                lon + b*180 / (Axis/Math.Sqrt(magic)*Math.Cos(rad)*Math.PI));
    }

    public static (double Lat, double Lon) GcjToWgs(double lat, double lon)
    {
        var result = (Lat: lat, Lon: lon);
        for (var i = 0; i < 8; i++)
        {
            var projected = WgsToGcj(result.Lat, result.Lon);
            result = (result.Lat + lat - projected.Lat, result.Lon + lon - projected.Lon);
        }
        return result;
    }
}
