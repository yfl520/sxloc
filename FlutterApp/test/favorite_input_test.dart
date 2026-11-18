import 'package:flutter_test/flutter_test.dart';

import 'package:suixing_loc/favorite_input.dart';

void main() {
  Map<String, String> fields() => {
    'latitude': '0',
    'longitude': '0',
    'altitude': '10',
    'accuracy': '5',
  };

  test('收藏接受零点和当前字段坐标', () {
    final zero = FavoriteInput.parse(fields());
    expect((zero.latitude, zero.longitude), (0, 0));
    final point = FavoriteInput.parse(
      fields()
        ..['latitude'] = '31.23'
        ..['longitude'] = '121.47',
    );
    expect((point.latitude, point.longitude), (31.23, 121.47));
  });

  for (final pair in [
    ('latitude', ''),
    ('latitude', 'NaN'),
    ('latitude', '91'),
    ('longitude', 'abc'),
    ('longitude', '-181'),
    ('altitude', 'Infinity'),
    ('altitude', '100001'),
    ('accuracy', '0'),
    ('accuracy', '100001'),
  ]) {
    test('收藏拒绝无效字段 ${pair.$1}=${pair.$2}', () {
      expect(
        () => FavoriteInput.parse(fields()..[pair.$1] = pair.$2),
        throwsFormatException,
      );
    });
  }
}
