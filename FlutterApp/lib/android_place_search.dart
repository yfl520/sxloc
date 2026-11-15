import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';

import 'coordinates.dart';

class AndroidPlace {
  const AndroidPlace(
    this.name,
    this.address,
    this.point, {
    this.id = '',
    this.category = '',
    this.source = '坐标',
    this.region = '',
    this.adcode = '',
  });

  final String name;
  final String address;
  final LatLng? point;
  final String id;
  final String category;
  final String source;
  final String region;
  final String adcode;
}

class PlaceSearchOptions {
  const PlaceSearchOptions({
    this.provider = 'auto',
    this.key = '',
    this.city = '',
    this.nearby = true,
  });

  final String provider;
  final String key;
  final String city;
  final bool nearby;
  bool get useAmap =>
      provider == 'amap' || (provider == 'auto' && key.isNotEmpty);
}

class PlaceSearchResult {
  const PlaceSearchResult(
    this.places,
    this.source, {
    this.notice,
    this.needsConfirmation = false,
  });
  final List<AndroidPlace> places;
  final String source;
  final String? notice;
  final bool needsConfirmation;
}

/// Both providers return WGS84 here; raw Amap coordinates never reach Bluetooth.
class AndroidPlaceSearch {
  HttpClient? _client;
  final _cities = <String, String>{};

  static AndroidPlace? coordinate(String query) {
    query = query.trim();
    final gcj = RegExp(r'^(gcj|高德)[:：]', caseSensitive: false).hasMatch(query);
    final text = query.replaceFirst(
      RegExp(r'^(wgs(?:84)?|gcj|高德)[:：]\s*', caseSensitive: false),
      '',
    );
    final match = RegExp(
      r'^([+-]?\d+(?:\.\d+)?)\s*[,，;；\s]\s*([+-]?\d+(?:\.\d+)?)$',
    ).firstMatch(text.trim());
    if (match == null) return null;
    final lat = double.parse(match[1]!);
    final lon = double.parse(match[2]!);
    if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
      throw const FormatException('坐标超出范围，请按“纬度,经度”输入');
    }
    return AndroidPlace(
      '输入的坐标',
      gcj ? '高德坐标已转换为 WGS-84' : 'WGS-84 坐标',
      Coordinates.picked(LatLng(lat, lon), gcj),
    );
  }

  Future<PlaceSearchResult> search(
    String query, {
    PlaceSearchOptions options = const PlaceSearchOptions(),
    LatLng? center,
    bool suggestions = false,
  }) async {
    query = query.trim();
    if (query.isEmpty) return const PlaceSearchResult([], '');
    if (query.length > 200) throw const FormatException('搜索内容请控制在 200 字以内');
    cancel();
    final parsed = coordinate(query);
    if (parsed != null) return PlaceSearchResult([parsed], '坐标解析');
    if (options.useAmap && options.key.isEmpty) {
      throw const FormatException('请在搜索设置中填写高德 Web 服务 Key，或选择自动／开放地图');
    }
    return _withClient((client) async {
      if (options.useAmap) {
        List<AndroidPlace> places = [];
        Object? amapError;
        try {
          places = await _amap(client, query, options, center, suggestions);
          if (options.provider != 'auto' ||
              places.any((p) => p.point != null) ||
              (suggestions && places.isNotEmpty)) {
            return PlaceSearchResult(places, '高德搜索');
          }
        } on SearchCancelled {
          rethrow;
        } catch (error) {
          if (options.provider != 'auto') rethrow;
          amapError = error;
        }
        try {
          final extra = await _photon(
            client,
            query,
            options,
            center,
            suggestions,
          );
          return PlaceSearchResult(
            rankAndMerge([...places, ...extra], query, center),
            extra.isEmpty ? '高德搜索' : '开放地图 · © OpenStreetMap',
            notice: amapError != null
                ? '${searchErrorText(amapError)} 已改用开放地图。'
                : '高德暂无可用坐标，已补查开放地图。',
          );
        } on SearchCancelled {
          rethrow;
        } catch (error) {
          if (places.isEmpty) rethrow;
          return PlaceSearchResult(
            places,
            '高德搜索',
            notice: '开放地图暂不可用，仍可点击已有建议继续查找。',
          );
        }
      }
      return PlaceSearchResult(
        await _photon(client, query, options, center, suggestions),
        '开放地图 · © OpenStreetMap',
      );
    });
  }

  Future<AndroidPlace> detail(AndroidPlace place, String key) async {
    // Input tips and POI search often already include the authoritative point.
    // A missing detail record must never invalidate that usable coordinate.
    if (place.point != null) return place;
    if (place.source != '高德搜索' || place.id.isEmpty) return place;
    cancel();
    return _withClient((client) => _amapDetail(client, place, key));
  }

  Future<AndroidPlace> _amapDetail(
    HttpClient client,
    AndroidPlace place,
    String key,
  ) async {
    final found = await _amapRequest(client, '/v3/place/detail', {
      'key': key,
      'id': place.id,
      'extensions': 'all',
    });
    if (found.isEmpty) {
      throw const PlaceSearchException('地点详情未提供坐标');
    }
    return found.first;
  }

  /// Resolve a selected suggestion without discarding its administrative context.
  /// Ambiguous or approximate matches return a list for the user to confirm.
  Future<PlaceSearchResult> resolve(
    AndroidPlace place, {
    PlaceSearchOptions options = const PlaceSearchOptions(),
    LatLng? center,
  }) async {
    cancel();
    if (place.point != null) return PlaceSearchResult([place], place.source);
    final query = contextualQuery(place);
    return _withClient((client) async {
      List<AndroidPlace> alternatives = [];
      Object? lastError;
      if (options.useAmap && options.key.isNotEmpty) {
        if (place.id.isNotEmpty && place.source == '高德搜索') {
          try {
            final found = await _amapDetail(client, place, options.key);
            if (_sameRegion(place.adcode, found.adcode)) {
              return PlaceSearchResult([found], '高德搜索');
            }
          } on SearchCancelled {
            rethrow;
          } catch (error) {
            lastError = error;
          }
        }
        final city = place.adcode.isNotEmpty
            ? place.adcode
            : (place.region.isNotEmpty ? '' : options.city);
        try {
          alternatives =
              (await _amapText(
                    client,
                    query,
                    options.key,
                    city,
                    strictCity: place.adcode.isNotEmpty,
                  ))
                  .where(
                    (p) =>
                        p.adcode.isEmpty || _sameRegion(place.adcode, p.adcode),
                  )
                  .toList();
          final exact = alternatives
              .where((p) => p.name == place.name && _matchesContext(place, p))
              .toList();
          if (exact.isNotEmpty) {
            return PlaceSearchResult(exact, '高德搜索');
          }
        } on SearchCancelled {
          rethrow;
        } catch (error) {
          lastError = error;
        }
        try {
          final geocodes =
              (await _amapGeocode(client, query, options.key, city))
                  .where(
                    (p) =>
                        p.adcode.isEmpty || _sameRegion(place.adcode, p.adcode),
                  )
                  .toList();
          if (geocodes.isNotEmpty) {
            return PlaceSearchResult(
              geocodes,
              '高德地址解析',
              notice: '已按完整地址找到位置，请核对地址和匹配级别后选择。',
              needsConfirmation: true,
            );
          }
        } on SearchCancelled {
          rethrow;
        } catch (error) {
          lastError = error;
        }
      }
      if (options.provider != 'amap') {
        try {
          // The suggestion's own region takes priority over the current map or
          // a previously preferred city, including when the user searches afar.
          final extra = await _photon(
            client,
            query,
            PlaceSearchOptions(
              city: place.region.isEmpty && place.address.isEmpty
                  ? options.city
                  : '',
              nearby:
                  place.region.isEmpty &&
                  place.address.isEmpty &&
                  options.nearby,
            ),
            center,
            false,
          );
          if (extra.isNotEmpty) {
            return PlaceSearchResult(
              rankAndMerge([...extra, ...alternatives], place.name, center),
              '开放地图 · © OpenStreetMap',
              notice: '已补查开放地图，请核对地区后选择具体位置。',
              needsConfirmation: true,
            );
          }
        } on SearchCancelled {
          rethrow;
        } catch (error) {
          lastError = error;
        }
      }
      if (alternatives.isNotEmpty) {
        return PlaceSearchResult(
          alternatives,
          '高德搜索',
          notice: '找到相关地点，请核对名称和地址后选择。',
          needsConfirmation: true,
        );
      }
      if (lastError != null) {
        throw PlaceSearchException(
          '${searchErrorText(lastError)} 仍可关闭结果，在地图上选点。',
        );
      }
      return const PlaceSearchResult(
        [],
        '地址补查',
        notice: '暂未查到这个地点的坐标，可补充乡镇、街道，或在地图上选点。',
      );
    });
  }

  static String contextualQuery(AndroidPlace place) {
    var query = '';
    for (final part in [place.region, place.address, place.name]) {
      final text = part.replaceAll(RegExp(r'\s*·\s*'), ' ').trim();
      if (text.isEmpty) continue;
      final compact = text.replaceAll(RegExp(r'\s+'), '');
      final previous = query.replaceAll(RegExp(r'\s+'), '');
      if (previous.contains(compact)) continue;
      query = compact.contains(previous) ? text : '$query $text'.trim();
    }
    return query;
  }

  static bool _sameRegion(String expected, String actual) {
    if (expected.isEmpty) return true;
    if (actual.isEmpty) return false;
    final length = expected.endsWith('0000')
        ? 2
        : (expected.endsWith('00') ? 4 : 6);
    return expected.length >= length &&
        actual.length >= length &&
        expected.substring(0, length) == actual.substring(0, length);
  }

  static bool _matchesContext(AndroidPlace expected, AndroidPlace actual) {
    if (expected.adcode.isNotEmpty) {
      return _sameRegion(expected.adcode, actual.adcode);
    }
    if (expected.region.isEmpty) return true;
    final region = expected.region.replaceAll(RegExp(r'\s+|·'), '');
    return actual.region.replaceAll(RegExp(r'\s+|·'), '').contains(region);
  }

  Future<List<AndroidPlace>> _amapRequest(
    HttpClient client,
    String path,
    Map<String, String> parameters, {
    bool tips = false,
  }) async {
    final data = await _json(
      client,
      Uri.https('restapi.amap.com', path, {...parameters, 'output': 'JSON'}),
    );
    _checkAmap(data);
    return parseAmap(data, tips: tips);
  }

  Future<List<AndroidPlace>> _amapText(
    HttpClient client,
    String query,
    String key,
    String city, {
    bool strictCity = false,
  }) => _amapRequest(client, '/v3/place/text', {
    'key': key,
    'keywords': query,
    'citylimit': strictCity ? 'true' : 'false',
    if (city.isNotEmpty) 'city': city,
    'offset': '20',
    'page': '1',
    'extensions': 'all',
  });

  Future<List<AndroidPlace>> _amapGeocode(
    HttpClient client,
    String address,
    String key,
    String city,
  ) async {
    final data = await _json(
      client,
      Uri.https('restapi.amap.com', '/v3/geocode/geo', {
        'key': key,
        'address': address,
        if (city.isNotEmpty) 'city': city,
        'output': 'JSON',
      }),
    );
    _checkAmap(data);
    return parseAmapGeocodes(data);
  }

  Future<T> _withClient<T>(Future<T> Function(HttpClient) run) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..userAgent = 'SuixingLoc/1.2 (Android; place search)';
    _client = client;
    try {
      return await run(client).timeout(const Duration(seconds: 30));
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  Future<List<AndroidPlace>> _photon(
    HttpClient client,
    String query,
    PlaceSearchOptions options,
    LatLng? center,
    bool suggestions,
  ) async {
    final data = await _json(
      client,
      Uri.https('photon.komoot.io', '/api/', {
        'q': options.city.isEmpty || query.contains(options.city)
            ? query
            : '${options.city} $query',
        'limit': suggestions ? '10' : '20',
        if (center != null && options.nearby) ...{
          'lat': center.latitude.toStringAsFixed(6),
          'lon': center.longitude.toStringAsFixed(6),
          'zoom': '12',
          'location_bias_scale': '0.2',
        },
      }),
    );
    if (data['features'] is! List) {
      throw const FormatException('搜索服务返回异常，请稍后重试');
    }
    return parsePhoton(data, query);
  }

  Future<List<AndroidPlace>> _amap(
    HttpClient client,
    String query,
    PlaceSearchOptions options,
    LatLng? center,
    bool suggestions,
  ) async {
    var city = options.city;
    final local = center != null && options.nearby && _mainland(center);
    if (local && city.isEmpty) {
      final cell =
          '${center.latitude.toStringAsFixed(1)},${center.longitude.toStringAsFixed(1)}';
      city = _cities[cell] ?? '';
      if (!_cities.containsKey(cell)) {
        try {
          final region = await _json(
            client,
            Uri.https('restapi.amap.com', '/v3/geocode/regeo', {
              'key': options.key,
              'location': amapLocation(center),
              'extensions': 'base',
            }),
          );
          _checkAmap(region);
          final regeo = region['regeocode'];
          if (regeo is Map && regeo['addressComponent'] is Map) {
            final component = regeo['addressComponent'] as Map;
            city = _text(component['citycode']);
            if (city.isEmpty) city = _text(component['city']);
          }
          if (_cities.length >= 40) _cities.clear();
          _cities[cell] = city;
        } on SearchCancelled {
          rethrow;
        } catch (_) {
          // Inferring a nearby city is optional; search can still work without it.
        }
      }
    }
    final params = <String, String>{
      'key': options.key,
      'keywords': query,
      'output': 'JSON',
      'citylimit': 'false',
      if (city.isNotEmpty) 'city': city,
    };
    if (suggestions) {
      return _amapRequest(client, '/v3/assistant/inputtips', {
        ...params,
        'datatype': 'poi',
        if (local) 'location': amapLocation(center),
      }, tips: true);
    }
    var places = <AndroidPlace>[];
    Object? firstError;
    var succeeded = false;
    try {
      places = await _amapText(client, query, options.key, city);
      succeeded = true;
    } on SearchCancelled {
      rethrow;
    } catch (error) {
      firstError = error;
    }
    if (local) {
      try {
        final around = await _amapRequest(client, '/v3/place/around', {
          'key': options.key,
          'keywords': query,
          'location': amapLocation(center),
          'radius': '50000',
          if (options.city.isNotEmpty) 'city': options.city,
          'sortrule': 'distance',
          'offset': '20',
          'page': '1',
          'extensions': 'all',
          'output': 'JSON',
        });
        succeeded = true;
        places = rankAndMerge([...places, ...around], query, center);
      } on SearchCancelled {
        rethrow;
      } catch (error) {
        firstError ??= error;
      }
    }
    if (places.isNotEmpty) {
      // A full address or village name may match related POIs rather than the
      // address itself. Include geocoding without losing those usable results.
      if (!places.any((p) => p.name == query) &&
          RegExp(r'[村乡镇路街巷弄号县区]|\d').hasMatch(query)) {
        try {
          final geocodes = await _amapGeocode(client, query, options.key, city);
          return rankAndMerge([...geocodes, ...places], query, center);
        } on SearchCancelled {
          rethrow;
        } catch (_) {
          // Optional address enrichment must not discard a successful POI search.
        }
      }
      return places;
    }
    try {
      // Some village names are suggestions but not indexed as searchable POIs.
      places = await _amapRequest(client, '/v3/assistant/inputtips', {
        ...params,
        'datatype': 'poi',
      }, tips: true);
      succeeded = true;
      if (places.any((p) => p.point != null)) return places;
    } on SearchCancelled {
      rethrow;
    } catch (error) {
      firstError ??= error;
    }
    try {
      final geocodes = await _amapGeocode(client, query, options.key, city);
      succeeded = true;
      if (geocodes.isNotEmpty) {
        return rankAndMerge([...geocodes, ...places], query, center);
      }
    } on SearchCancelled {
      rethrow;
    } catch (error) {
      firstError ??= error;
    }
    if (!succeeded && firstError != null) throw firstError;
    return places;
  }

  static String amapLocation(LatLng wgs) {
    final p = Coordinates.toGcj(wgs);
    return '${p.longitude.toStringAsFixed(6)},${p.latitude.toStringAsFixed(6)}';
  }

  static bool _mainland(LatLng p) =>
      p.longitude > 73.66 &&
      p.longitude < 135.05 &&
      p.latitude > 3.86 &&
      p.latitude < 53.55;

  static String _text(dynamic value) => value is String ? value.trim() : '';

  static LatLng? _point(num? lat, num? lon) {
    if (lat == null ||
        lon == null ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      return null;
    }
    return LatLng(lat.toDouble(), lon.toDouble());
  }

  static LatLng? _amapPoint(dynamic location) {
    final parts = _text(location).split(',');
    if (parts.length != 2) return null;
    final raw = _point(double.tryParse(parts[1]), double.tryParse(parts[0]));
    return raw == null ? null : Coordinates.picked(raw, true);
  }

  static String _region(Map item, List<String> keys) => keys
      .map((key) => _text(item[key]))
      .where((s) => s.isNotEmpty)
      .toSet()
      .join();

  static List<AndroidPlace> parseAmapGeocodes(Map data) {
    final list = data['geocodes'];
    if (list is! List) return [];
    final found = <AndroidPlace>[];
    for (final item in list.whereType<Map>()) {
      final point = _amapPoint(item['location']);
      final name = _text(item['formatted_address']);
      if (point == null || name.isEmpty) continue;
      final level = _text(item['level']);
      found.add(
        AndroidPlace(
          name,
          name,
          point,
          category: level.isEmpty ? '地址匹配 · 级别未知' : '地址匹配 · $level',
          source: '高德地址解析',
          region: _region(item, ['province', 'city', 'district']),
          adcode: _text(item['adcode']),
        ),
      );
    }
    return found;
  }

  static List<AndroidPlace> parseAmap(Map data, {required bool tips}) {
    final list = data[tips ? 'tips' : 'pois'];
    if (list is! List) return [];
    final found = <AndroidPlace>[];
    for (final item in list.whereType<Map>()) {
      final name = _text(item['name']);
      if (name.isEmpty) continue;
      final point = _amapPoint(item['location']);
      if (!tips && point == null) continue;
      final address =
          (tips
                  ? ['district', 'address']
                  : ['pname', 'cityname', 'adname', 'address'])
              .map((key) => _text(item[key]))
              .where((s) => s.isNotEmpty)
              .toSet()
              .join(' · ');
      found.add(
        AndroidPlace(
          name,
          address,
          point,
          id: _text(item['id']),
          category: tips ? '' : _text(item['type']).split(';').last,
          source: '高德搜索',
          region: tips
              ? _text(item['district'])
              : _region(item, ['pname', 'cityname', 'adname']),
          adcode: _text(item['adcode']),
        ),
      );
    }
    return found;
  }

  static List<AndroidPlace> parsePhoton(Map data, String query) {
    final features = data['features'];
    if (features is! List) return [];
    final found = <AndroidPlace>[];
    for (final feature in features.whereType<Map>()) {
      final geometry = feature['geometry'], properties = feature['properties'];
      if (geometry is! Map || properties is! Map) continue;
      final values = geometry['coordinates'];
      if (values is! List ||
          values.length < 2 ||
          values[0] is! num ||
          values[1] is! num) {
        continue;
      }
      final p = _point(values[1] as num, values[0] as num);
      if (p == null) continue;
      final address =
          [
                'country',
                'state',
                'city',
                'district',
                'locality',
                'street',
                'housenumber',
              ]
              .map((key) => _text(properties[key]))
              .where((s) => s.isNotEmpty)
              .toSet()
              .join(' · ');
      final name = _text(properties['name']);
      found.add(
        AndroidPlace(
          name.isEmpty ? query : name,
          address,
          p,
          category: '开放地图地点',
          source: '开放地图',
        ),
      );
    }
    return found;
  }

  static List<AndroidPlace> rankAndMerge(
    List<AndroidPlace> input,
    String query,
    LatLng? center,
  ) {
    final unique = <String, AndroidPlace>{};
    for (final place in input) {
      final id = place.id.isNotEmpty
          ? '${place.source}|${place.id}'
          : '${place.name}|${place.point}|${place.address}';
      final previous = unique[id];
      if (previous == null || (previous.point == null && place.point != null)) {
        unique[id] = place;
      }
    }
    final places = unique.values.toList();
    // Preserve exact-name intent across cities; then prefer nearby matching POIs.
    places.sort((a, b) {
      final exactA = a.name.toLowerCase() == query.toLowerCase();
      final exactB = b.name.toLowerCase() == query.toLowerCase();
      if (exactA != exactB) return exactA ? -1 : 1;
      if (center == null) return 0;
      final da = a.point == null
          ? double.infinity
          : const Distance()(center, a.point!);
      final db = b.point == null
          ? double.infinity
          : const Distance()(center, b.point!);
      return da.compareTo(db);
    });
    return places.take(30).toList();
  }

  Future<Map> _json(HttpClient client, Uri uri) async {
    if (!identical(client, _client)) throw const SearchCancelled();
    // Never surface HttpClient's URL-bearing errors: the URL can contain a private Key.
    HttpClientRequest? pending;
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        pending = request;
        if (!identical(client, _client)) throw const SearchCancelled();
        request.headers.set(
          HttpHeaders.acceptLanguageHeader,
          'zh-CN,zh;q=0.9,en;q=0.6',
        );
        final response = await request.close();
        if (response.statusCode == 429) {
          throw const PlaceSearchException('搜索过于频繁或额度受限，请稍后重试');
        }
        if (response.statusCode != 200) {
          throw PlaceSearchException('搜索服务暂不可用（${response.statusCode}）');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 2 * 1024 * 1024) {
            throw const PlaceSearchException('搜索结果过大，请缩小搜索范围');
          }
          bytes.addAll(chunk);
        }
        if (!identical(client, _client)) throw const SearchCancelled();
        final data = jsonDecode(utf8.decode(bytes));
        if (data is! Map) throw const FormatException('搜索服务返回异常');
        return data;
      })().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      pending?.abort();
      if (!identical(client, _client)) throw const SearchCancelled();
      throw const PlaceSearchException('搜索服务响应超时，请稍后重试');
    } on SearchCancelled {
      rethrow;
    } on PlaceSearchException {
      rethrow;
    } catch (error) {
      if (!identical(client, _client)) throw const SearchCancelled();
      if (error is FormatException) throw const FormatException('搜索服务返回异常');
      throw const PlaceSearchException('无法连接搜索服务，请检查网络');
    }
  }

  static void _checkAmap(Map data) {
    if (data['status'] == '1') return;
    final message = switch (_text(data['infocode'])) {
      '10001' => '高德 Key 无效，请检查搜索设置。',
      '10003' || '10004' || '10021' || '10044' => '高德调用额度已用完或权限受限。',
      '10009' => '高德 Key 类型不符，请使用 Web 服务 Key。',
      '10005' || '10006' || '10007' => '高德 Key 的访问限制未通过。',
      _ => '高德搜索暂不可用，请检查 Key 权限或稍后重试。',
    };
    throw PlaceSearchException(message);
  }

  void cancel() {
    final previous = _client;
    _client = null;
    previous?.close(force: true);
  }
}

class SearchCancelled implements Exception {
  const SearchCancelled();
}

class PlaceSearchException implements Exception {
  const PlaceSearchException(this.message);
  final String message;
}

String searchErrorText(Object error) => switch (error) {
  TimeoutException() => '搜索超时，请检查网络后重试。',
  PlaceSearchException() => error.message,
  FormatException() => error.message,
  _ => '搜索失败，请稍后重试。',
};
