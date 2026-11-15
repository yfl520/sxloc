import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:suixing_loc/android_place_search.dart';
import 'package:suixing_loc/coordinates.dart';

void main() {
  var checks = 0;
  void expect(bool condition, String message) {
    if (!condition) throw StateError(message);
    checks++;
  }

  bool near(LatLng a, LatLng b) =>
      (a.latitude - b.latitude).abs() < .000001 &&
      (a.longitude - b.longitude).abs() < .000001;

  final shanghai = const LatLng(31.2304, 121.4737);
  expect(
    near(
      AndroidPlaceSearch.coordinate('31.230400,121.473700')!.point!,
      shanghai,
    ),
    'WGS84 input must keep latitude and longitude in the documented order',
  );
  expect(
    near(
      AndroidPlaceSearch.coordinate('wgs84: -33.8688，151.2093')!.point!,
      const LatLng(-33.8688, 151.2093),
    ),
    'Southern hemisphere and Chinese separators',
  );
  expect(
    AndroidPlaceSearch.coordinate('上海 人民广场') == null,
    'Names must use place search',
  );
  expect(
    near(AndroidPlaceSearch.coordinate('0,0')!.point!, const LatLng(0, 0)),
    'Zero is a valid coordinate',
  );

  for (final invalid in ['91,0', '-91,0', '0,181', '0,-181']) {
    var rejected = false;
    try {
      AndroidPlaceSearch.coordinate(invalid);
    } on FormatException {
      rejected = true;
    }
    expect(
      rejected,
      'Out-of-range coordinate must not reach Bluetooth: $invalid',
    );
  }

  for (final point in [
    shanghai,
    const LatLng(39.908823, 116.397470),
    const LatLng(-33.8688, 151.2093),
    const LatLng(40.7128, -74.006),
  ]) {
    final displayed = Coordinates.display(point, true);
    final parsed = AndroidPlaceSearch.coordinate(
      'gcj: ${displayed.latitude},${displayed.longitude}',
    )!.point!;
    expect(
      near(parsed, point),
      'Picking/searching a GCJ point must return WGS84: $point',
    );
    var target = point;
    for (var i = 0; i < 20; i++) {
      target = Coordinates.picked(Coordinates.display(target, true), true);
      target = Coordinates.picked(Coordinates.display(target, false), false);
    }
    expect(
      near(target, point),
      'Repeated source changes must not accumulate target drift',
    );
  }
  stdout.writeln('Android map coordinate checks: $checks passed');
}
