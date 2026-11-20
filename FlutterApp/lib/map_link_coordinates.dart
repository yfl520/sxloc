import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'coordinates.dart';

/// BD09MC coefficients and inverse polynomial adapted from gcoord (MIT).
/// Copyright (c) 2018-present, Jiulong Hu.
/// https://github.com/hujiulong/gcoord/blob/master/src/crs/BD09MC.ts
abstract final class MapLinkCoordinates {
  static bool valid(double lat, double lon) =>
      lat.isFinite && lon.isFinite && lat.abs() <= 90 && lon.abs() <= 180;

  static LatLng fromBaidu(LatLng point) {
    final x = point.longitude - .0065, y = point.latitude - .006;
    final k = math.pi * 3000 / 180;
    final radius = math.sqrt(x * x + y * y) - .00002 * math.sin(y * k);
    final angle = math.atan2(y, x) - .000003 * math.cos(x * k);
    return Coordinates.picked(
      LatLng(radius * math.sin(angle), radius * math.cos(angle)),
      true,
    );
  }

  static LatLng? baiduMercator(double x, double y) {
    if (!x.isFinite ||
        !y.isFinite ||
        x.abs() > 21000000 ||
        y.abs() > 20000000) {
      return null;
    }
    final index = _bands.indexWhere((band) => y.abs() >= band);
    if (index < 0) return null;
    final f = _factors[index], t = y.abs() / _factors[index][9];
    var lat = f[8];
    for (var i = 7; i >= 2; i--) {
      lat = lat * t + f[i];
    }
    final lon = (f[0] + f[1] * x.abs()) * (x < 0 ? -1 : 1);
    lat *= y < 0 ? -1 : 1;
    return valid(lat, lon) ? LatLng(lat, lon) : null;
  }

  // Region inference is only for shared Apple/Google links. Users can explicitly
  // choose a datum in the import page when a link's coordinate origin is unclear.
  static bool mainland(LatLng p) {
    final lat = p.latitude, lon = p.longitude;
    if (lon < 73.66 || lon > 135.05 || lat < 3.86 || lat > 53.55) return false;
    if (lon >= 119.3 && lon <= 122.1 && lat >= 21.7 && lat <= 25.5) {
      return false;
    }
    if (lon >= 113.83 && lon <= 114.45 && lat >= 22.15 && lat <= 22.57) {
      return false;
    }
    if (lon >= 113.52 && lon <= 113.62 && lat >= 22.1 && lat <= 22.23) {
      return false;
    }
    return true;
  }

  static const _bands = [
    12890594.86,
    8362377.87,
    5591021.0,
    3481989.83,
    1678043.12,
    0.0,
  ];
  static const _factors = [
    [
      1.410526172116255e-8,
      8.98305509648872e-6,
      -1.9939833816331,
      200.9824383106796,
      -187.2403703815547,
      91.6087516669843,
      -23.38765649603339,
      2.57121317296198,
      -0.03801003308653,
      17337981.2,
    ],
    [
      -7.435856389565537e-9,
      8.983055097726239e-6,
      -0.78625201886289,
      96.32687599759846,
      -1.85204757529826,
      -59.36935905485877,
      47.40033549296737,
      -16.50741931063887,
      2.28786674699375,
      10260144.86,
    ],
    [
      -3.030883460898826e-8,
      8.98305509983578e-6,
      0.30071316287616,
      59.74293618442277,
      7.357984074871,
      -25.38371002664745,
      13.45380521110908,
      -3.29883767235584,
      0.32710905363475,
      6856817.37,
    ],
    [
      -1.981981304930552e-8,
      8.983055099779535e-6,
      0.03278182852591,
      40.31678527705744,
      0.65659298677277,
      -4.44255534477492,
      0.85341911805263,
      0.12923347998204,
      -0.04625736007561,
      4482777.06,
    ],
    [
      3.09191371068437e-9,
      8.983055096812155e-6,
      0.00006995724062,
      23.10934304144901,
      -0.00023663490511,
      -0.6321817810242,
      -0.00663494467273,
      0.03430082397953,
      -0.00466043876332,
      2555164.4,
    ],
    [
      2.890871144776878e-9,
      8.983055095805407e-6,
      -3.068298e-8,
      7.47137025468032,
      -0.00000353937994,
      -0.02145144861037,
      -0.00001234426596,
      0.00010322952773,
      -0.00000323890364,
      826088.5,
    ],
  ];
}

const mapLinkCoordinateLicense = '''MIT License

Copyright (c) 2018-present, Jiulong Hu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''';
