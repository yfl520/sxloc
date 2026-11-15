import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:suixing_loc/coordinates.dart';

void main() {
  test('unresolved bridge suggestions never become zero coordinates', () {
    final data = jsonDecode(
      '{"places":[{"name":"幸福村",'
      '"latitude":null,"longitude":null,"adcode":"330111"}]}',
    ) as Map;
    final place = Map<String, dynamic>.from(
      (data['places'] as List).single as Map,
    );
    expect(Coordinates.searchPoint(place), isNull);
    expect(Coordinates.searchPoint({'latitude': 31.2}), isNull);
    expect(Coordinates.searchPoint({'longitude': 121.4}), isNull);
    expect(Coordinates.searchPoint({}), isNull);
  });

  test('explicit zero and WGS coordinates stay exact', () {
    final zero = Coordinates.searchPoint({'latitude': 0, 'longitude': 0})!;
    expect(zero.latitude, 0);
    expect(zero.longitude, 0);
    final point = Coordinates.searchPoint({
      'latitude': 31.23,
      'longitude': 121.47,
    })!;
    expect(point.latitude, 31.23);
    expect(point.longitude, 121.47);
  });

  test('malformed and out of range pairs cannot be selected', () {
    for (final pair in [
      ['31', '121'],
      [double.nan, 121],
      [31, double.infinity],
      [91, 121],
      [31, 181],
      [-91, -181],
      [[], []],
    ]) {
      expect(
        Coordinates.searchPoint({'latitude': pair[0], 'longitude': pair[1]}),
        isNull,
      );
    }
  });
}
