import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

abstract final class Coordinates {
  /// Missing search coordinates stay unresolved; only explicit numeric pairs
  /// may become map targets. The real point (0, 0) remains valid.
  static LatLng? searchPoint(Map<String, dynamic> place) {
    final lat = place['latitude'], lon = place['longitude'];
    if (lat is! num ||
        lon is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      return null;
    }
    return LatLng(lat.toDouble(), lon.toDouble());
  }

  static LatLng display(LatLng point, bool amap) => amap ? toGcj(point) : point;
  static LatLng picked(LatLng point, bool amap) {
    if (!amap) return point;
    var result = point;
    for (var i = 0; i < 8; i++) {
      final shifted = toGcj(result);
      result = LatLng(
        result.latitude + point.latitude - shifted.latitude,
        result.longitude + point.longitude - shifted.longitude,
      );
    }
    return result;
  }

  static LatLng toGcj(LatLng p) {
    final lat = p.latitude, lon = p.longitude;
    if (!(lon > 73.66 && lon < 135.05 && lat > 3.86 && lat < 53.55)) return p;
    const pi = math.pi, axis = 6378245.0, ee = .00669342162296594323;
    final x = lon - 105, y = lat - 35;
    var a =
        -100 +
        2 * x +
        3 * y +
        .2 * y * y +
        .1 * x * y +
        .2 * math.sqrt(x.abs());
    a += (20 * math.sin(6 * x * pi) + 20 * math.sin(2 * x * pi)) * 2 / 3;
    a += (20 * math.sin(y * pi) + 40 * math.sin(y / 3 * pi)) * 2 / 3;
    a += (160 * math.sin(y / 12 * pi) + 320 * math.sin(y * pi / 30)) * 2 / 3;
    var b = 300 + x + 2 * y + .1 * x * x + .1 * x * y + .1 * math.sqrt(x.abs());
    b += (20 * math.sin(6 * x * pi) + 20 * math.sin(2 * x * pi)) * 2 / 3;
    b += (20 * math.sin(x * pi) + 40 * math.sin(x / 3 * pi)) * 2 / 3;
    b += (150 * math.sin(x / 12 * pi) + 300 * math.sin(x / 30 * pi)) * 2 / 3;
    final rad = lat / 180 * pi;
    final magic = 1 - ee * math.pow(math.sin(rad), 2);
    final sq = math.sqrt(magic);
    return LatLng(
      lat + a * 180 / (axis * (1 - ee) / (magic * sq) * pi),
      lon + b * 180 / (axis / sq * math.cos(rad) * pi),
    );
  }
}
