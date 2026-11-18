// Windows coordinate fields are authoritative; the map draft may still hold the last valid point.
class FavoriteInput {
  const FavoriteInput(
    this.latitude,
    this.longitude,
    this.altitude,
    this.accuracy,
  );

  final double latitude, longitude, altitude, accuracy;

  static FavoriteInput parse(Map<String, String> fields) {
    double value(String key, double min, double max, String label) {
      final result = double.tryParse(fields[key]?.trim() ?? '');
      if (result == null || !result.isFinite || result < min || result > max) {
        throw FormatException('请输入有效的$label（$min 至 $max）');
      }
      return result;
    }

    return FavoriteInput(
      value('latitude', -90, 90, '纬度'),
      value('longitude', -180, 180, '经度'),
      value('altitude', -12000, 100000, '高度'),
      value('accuracy', .1, 100000, '精度'),
    );
  }
}
