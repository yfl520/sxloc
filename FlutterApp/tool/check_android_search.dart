import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:suixing_loc/android_place_search.dart';
import 'package:suixing_loc/coordinates.dart';

/// Exercises the real HTTP pipeline against a local fixture server; no external requests or Key.
Future<void> main() async {
  var checks = 0;
  void expect(bool value, String message) {
    if (!value) throw StateError(message);
    checks++;
  }

  const origin = LatLng(31.2304, 121.4737);
  final gcj = Coordinates.toGcj(origin);
  final rawLocation = '${gcj.longitude},${gcj.latitude}';
  final poi = <String, dynamic>{
    'id': 'fixture-poi',
    'name': '人民广场',
    'location': rawLocation,
    'pname': '上海市',
    'cityname': '上海市',
    'adname': '黄浦区',
    'adcode': '310101',
    'address': '人民大道',
    'type': '风景名胜;公园广场;城市广场',
  };
  final photon = {
    'features': [
      {
        'geometry': {
          'coordinates': [121.4737, 31.2304],
        },
        'properties': {
          'name': '人民广场',
          'country': '中国',
          'city': '上海市',
          'street': '人民大道',
        },
      },
      {
        'geometry': {
          'coordinates': [999, 999],
        },
        'properties': {'name': 'invalid'},
      },
      {
        'geometry': {'coordinates': []},
        'properties': {'name': 'missing'},
      },
    ],
  };
  final uris = <Uri>[];
  Map? Function(Uri)? replyOverride;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final slowStarted = Completer<void>();
  final slowRelease = Completer<void>();
  final resolutionStarted = Completer<void>();
  final resolutionRelease = Completer<void>();
  final detailTimeoutRelease = Completer<void>();
  final subscription = server.listen((request) async {
    Object body;
    final path = request.uri.path;
    if (request.uri.queryParameters['q'] == 'slow') {
      slowStarted.complete();
      await slowRelease.future;
    }
    if (request.uri.queryParameters['address'] == 'slow-resolution') {
      resolutionStarted.complete();
      await resolutionRelease.future;
    }
    if (path == '/v3/place/detail' &&
        request.uri.queryParameters['key'] == 'timeout-fixture-key') {
      await detailTimeoutRelease.future;
    }
    final overridden = replyOverride?.call(request.uri);
    if (overridden != null) {
      body = overridden;
    } else if (request.uri.queryParameters['key'] == 'invalid-fixture-key') {
      body = {'status': '0', 'infocode': '10001'};
    } else if (path == '/v3/geocode/regeo') {
      body = {
        'status': '1',
        'regeocode': {
          'addressComponent': {'citycode': '021'},
        },
      };
    } else if (path == '/v3/assistant/inputtips') {
      body = {
        'status': '1',
        'tips': [
          {...poi, 'district': '上海市黄浦区'},
          {
            'name': '无坐标建议',
            'id': [],
            'location': [],
            'address': [],
            'district': '上海市',
          },
        ],
      };
    } else if (path.startsWith('/v3/place/')) {
      body = {
        'status': '1',
        'pois': [
          poi,
          {'name': '无效点', 'location': '999,999'},
        ],
      };
    } else {
      body = photon;
    }
    try {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    } catch (_) {
      // An intentionally cancelled request may close its socket before a fixture replies.
    }
  });
  final search = AndroidPlaceSearch();
  try {
    await HttpOverrides.runWithHttpOverrides(() async {
      const options = PlaceSearchOptions(key: 'fixture-key');
      var result = await search.search(
        '人民',
        options: options,
        center: origin,
        suggestions: true,
      );
      expect(
        result.source == '高德搜索' && result.places.length == 2,
        'Amap suggestions and source',
      );
      expect(
        result.places.last.point == null && result.places.last.id.isEmpty,
        'Missing coordinates/array fields must not become an arbitrary coordinate',
      );
      expect(
        const Distance()(result.places.first.point!, origin) < .2,
        'Amap GCJ must convert to WGS',
      );
      expect(
        result.places.first.address.contains('黄浦区'),
        'Suggestion district and full address',
      );
      final tipsUri = uris.last;
      expect(
        tipsUri.queryParameters['city'] == '021',
        'Infer city for location-biased suggestions',
      );
      expect(
        tipsUri.queryParameters['location'] ==
            AndroidPlaceSearch.amapLocation(origin),
        'Send GCJ longitude first to Amap',
      );
      final countBeforeDirect = uris.length;
      final direct = await search.detail(result.places.first, options.key);
      expect(
        identical(direct, result.places.first) &&
            uris.length == countBeforeDirect,
        'An existing coordinate must not require a detail request',
      );
      final resolvedDirect = await search.resolve(
        result.places.first,
        options: const PlaceSearchOptions(key: 'invalid-fixture-key'),
      );
      expect(
        identical(resolvedDirect.places.single, direct) &&
            uris.length == countBeforeDirect,
        'Even an unavailable detail service or invalid Key must not block an existing point',
      );
      final detail = await search.detail(
        const AndroidPlace('人民广场', '', null, id: 'fixture-poi', source: '高德搜索'),
        options.key,
      );
      expect(
        detail.category == '城市广场' && detail.address.contains('人民大道'),
        'A coordinate-less POI can still use ID detail lookup',
      );
      expect(
        const Distance()(detail.point!, origin) < .2,
        'Detail must not shift target twice',
      );

      result = await search.search('人民广场', options: options, center: origin);
      expect(
        result.places.length == 1,
        'Merge text and nearby results by stable POI id',
      );
      expect(
        uris.where((u) => u.path == '/v3/geocode/regeo').length == 1,
        'Cache inferred city',
      );
      expect(
        uris.any((u) => u.path == '/v3/place/around'),
        'Nearby results requested',
      );

      result = await search.search(
        '人民广场',
        options: const PlaceSearchOptions(city: '上海'),
        center: origin,
      );
      expect(
        result.source.contains('开放地图') && result.places.length == 1,
        'No Key uses Photon and filters malformed points',
      );
      expect(
        uris.last.queryParameters['lat'] == '31.230400' &&
            uris.last.queryParameters['q'] == '上海 人民广场',
        'Photon WGS location bias and city',
      );
      expect(
        uris.last.queryParameters['limit'] == '20',
        'Expanded explicit search results',
      );

      result = await search.search(
        '人民',
        options: const PlaceSearchOptions(key: 'invalid-fixture-key'),
        center: origin,
      );
      expect(
        result.source.contains('开放地图') && result.notice!.contains('Key 无效'),
        'Visible auto fallback',
      );
      expect(
        !result.notice!.contains('invalid-fixture-key'),
        'Never echo a private Key in errors',
      );
      var failed = false;
      try {
        await search.search(
          '人民',
          options: const PlaceSearchOptions(
            provider: 'amap',
            key: 'invalid-fixture-key',
          ),
        );
      } on PlaceSearchException {
        failed = true;
      }
      expect(
        failed && uris.last.host == 'restapi.amap.com',
        'Explicit provider errors do not silently switch',
      );

      final countBeforeCoordinate = uris.length;
      result = await search.search('31.2304,121.4737', center: origin);
      expect(
        uris.length == countBeforeCoordinate && result.source == '坐标解析',
        'Coordinate input stays offline',
      );

      final old = search
          .search('slow')
          .then<bool>(
            (_) => false,
            onError: (Object e) => e is SearchCancelled,
          );
      await slowStarted.future;
      final fresh = await search.search('fresh');
      slowRelease.complete();
      expect(await old, 'A replacement query cancels the previous request');
      expect(
        fresh.places.first.name == '人民广场',
        'New query survives previous cancellation',
      );

      const village = AndroidPlace(
        '测试村',
        '浙江省杭州市余杭区 · 百丈镇',
        null,
        id: 'expired-id',
        source: '高德搜索',
        region: '浙江省杭州市余杭区',
        adcode: '330110',
      );
      final villagePoi = {
        ...poi,
        'id': 'resolved-village',
        'name': '测试村',
        'adcode': '330110',
        'pname': '浙江省',
        'cityname': '杭州市',
        'adname': '余杭区',
        'address': '百丈镇',
      };
      final villageGeocode = {
        'formatted_address': '浙江省杭州市余杭区百丈镇测试村',
        'province': '浙江省',
        'city': '杭州市',
        'district': '余杭区',
        'adcode': '330110',
        'location': rawLocation,
        'level': '村庄',
      };
      Map emptyAmap() => {
        'status': '1',
        'pois': [],
        'tips': [],
        'geocodes': [],
      };

      // An expired suggestion ID must continue with a county-scoped lookup.
      replyOverride = (uri) => uri.path == '/v3/place/text'
          ? {
              'status': '1',
              'pois': [
                {...villagePoi, 'id': 'wrong-county', 'adcode': '110101'},
                villagePoi,
              ],
            }
          : emptyAmap();
      var countBeforeResolve = uris.length;
      var resolved = await search.resolve(
        village,
        options: options,
        center: origin,
      );
      expect(
        resolved.places.single.id == 'resolved-village' &&
            !resolved.needsConfirmation,
        'Expired ID falls through to a matching name in the original county',
      );
      final resolveUris = uris.skip(countBeforeResolve).toList();
      final scoped = resolveUris.singleWhere((u) => u.path == '/v3/place/text');
      expect(
        scoped.queryParameters['city'] == '330110' &&
            scoped.queryParameters['citylimit'] == 'true' &&
            scoped.queryParameters['keywords'] == '浙江省杭州市余杭区 百丈镇 测试村',
        'Selected suggestion region must override the current map city',
      );
      resolved = await search.resolve(
        village,
        options: const PlaceSearchOptions(key: 'timeout-fixture-key'),
      );
      detailTimeoutRelease.complete();
      expect(
        resolved.places.single.id == 'resolved-village',
        'A timed-out detail request must allow the next resolution stage to succeed',
      );

      // A suggestion without an ID or a POI record can resolve by full address.
      replyOverride = (uri) => uri.path == '/v3/geocode/geo'
          ? {
              'status': '1',
              'geocodes': [villageGeocode],
            }
          : emptyAmap();
      const noId = AndroidPlace(
        '测试村',
        '浙江省杭州市余杭区 · 百丈镇',
        null,
        source: '高德搜索',
        region: '浙江省杭州市余杭区',
        adcode: '330110',
      );
      resolved = await search.resolve(
        noId,
        options: const PlaceSearchOptions(key: 'fixture-key', city: '上海'),
      );
      final geocodeUri = uris.last;
      expect(
        geocodeUri.path == '/v3/geocode/geo' &&
            geocodeUri.queryParameters['address'] == '浙江省杭州市余杭区 百丈镇 测试村' &&
            geocodeUri.queryParameters['city'] == '330110',
        'Full region, township and village survive forward geocoding',
      );
      expect(
        resolved.needsConfirmation &&
            resolved.places.single.category == '地址匹配 · 村庄' &&
            const Distance()(resolved.places.single.point!, origin) < .2,
        'Geocoding exposes granularity and converts GCJ to WGS only once',
      );
      final beforeGeocodePick = uris.length;
      final pickedGeocode = await search.resolve(
        resolved.places.single,
        options: options,
      );
      expect(
        pickedGeocode.places.single.point == resolved.places.single.point &&
            uris.length == beforeGeocodePick,
        'Selecting a geocoded candidate needs no further network lookup',
      );

      // AMap input tips can lack adcode: keep the full region in the text query.
      countBeforeResolve = uris.length;
      await search.resolve(
        const AndroidPlace(
          '测试村',
          '百丈镇',
          null,
          region: '浙江省杭州市余杭区',
          source: '高德搜索',
        ),
        options: const PlaceSearchOptions(key: 'fixture-key', city: '上海'),
      );
      final unscoped = uris.skip(countBeforeResolve).first;
      expect(
        unscoped.queryParameters['keywords'] == '浙江省杭州市余杭区 百丈镇 测试村' &&
            !unscoped.queryParameters.containsKey('city'),
        'Missing adcode must not reduce a remote village to a bare name or wrong preferred city',
      );

      // Multiple same-name records are returned, never silently reduced to one.
      replyOverride = (uri) => uri.path == '/v3/place/text'
          ? {
              'status': '1',
              'pois': [
                villagePoi,
                {...villagePoi, 'id': 'another-village'},
              ],
            }
          : emptyAmap();
      resolved = await search.resolve(noId, options: options);
      expect(
        resolved.places.length == 2,
        'Same-name candidates remain available for explicit selection',
      );

      // Reject known wrong counties, retain unknown counties for confirmation.
      replyOverride = (uri) => uri.path == '/v3/place/text'
          ? {
              'status': '1',
              'pois': [
                {...villagePoi, 'adcode': []},
              ],
            }
          : emptyAmap();
      resolved = await search.resolve(
        noId,
        options: const PlaceSearchOptions(provider: 'amap', key: 'fixture-key'),
      );
      expect(
        resolved.places.length == 1 && resolved.needsConfirmation,
        'Missing region metadata must require confirmation without discarding usable coordinates',
      );
      resolved = await search.resolve(
        const AndroidPlace('测试村', '', null, region: '北京市东城区', source: '高德搜索'),
        options: const PlaceSearchOptions(provider: 'amap', key: 'fixture-key'),
      );
      expect(
        resolved.needsConfirmation,
        'Same-name POIs without a matching administrative region must not be auto-selected',
      );

      // No usable AMap coordinates: auto mode now falls back on empty results too.
      replyOverride = (uri) =>
          uri.path.startsWith('/v3/') ? emptyAmap() : photon;
      result = await search.search('无结果村', options: options);
      expect(
        result.source.contains('开放地图') &&
            result.places.single.point == origin &&
            result.notice!.contains('暂无可用坐标'),
        'Successful but empty AMap responses also trigger open-map fallback',
      );
      countBeforeResolve = uris.length;
      result = await search.search(
        '无结果村',
        options: const PlaceSearchOptions(provider: 'amap', key: 'fixture-key'),
      );
      expect(
        result.places.isEmpty &&
            uris
                .skip(countBeforeResolve)
                .every((u) => u.host == 'restapi.amap.com'),
        'Explicit AMap selection stays within the requested provider even on empty results',
      );

      // A remote selected village must keep its address across providers.
      replyOverride = (uri) => uri.path == '/v3/geocode/geo'
          ? {
              'status': '1',
              'geocodes': [
                {...villageGeocode, 'adcode': '110101'},
              ],
            }
          : (uri.path.startsWith('/v3/') ? emptyAmap() : photon);
      resolved = await search.resolve(
        noId,
        options: const PlaceSearchOptions(key: 'fixture-key', city: '上海'),
        center: origin,
      );
      expect(
        resolved.needsConfirmation &&
            resolved.source.contains('开放地图') &&
            uris.last.queryParameters['q'] == '浙江省杭州市余杭区 百丈镇 测试村' &&
            !uris.last.queryParameters.containsKey('lat'),
        'Cross-provider fallback preserves the selected region, not a stale local bias',
      );

      // Optional city inference and around calls may fail independently of POI search.
      replyOverride = (uri) => uri.path == '/v3/place/text'
          ? {
              'status': '1',
              'pois': [poi],
            }
          : {'status': '0', 'infocode': '10044'};
      result = await search.search(
        '人民广场',
        options: options,
        center: const LatLng(30, 120),
      );
      expect(
        result.places.single.id == 'fixture-poi' && result.source == '高德搜索',
        'Optional region and nearby failures must not erase valid POI results',
      );

      // A full address can be geocoded alongside a related POI result.
      replyOverride = (uri) => uri.path == '/v3/place/text'
          ? {
              'status': '1',
              'pois': [
                {...villagePoi, 'name': '测试村卫生室'},
              ],
            }
          : (uri.path == '/v3/geocode/geo'
                ? {
                    'status': '1',
                    'geocodes': [villageGeocode],
                  }
                : emptyAmap());
      result = await search.search('测试村', options: options);
      expect(
        result.places.length == 2 &&
            result.places.any((p) => p.category == '地址匹配 · 村庄'),
        'A related POI must not prevent a full-address or village match',
      );

      replyOverride = (uri) => uri.path == '/v3/geocode/geo'
          ? {
              'status': '1',
              'geocodes': [villageGeocode],
            }
          : {'status': '0', 'infocode': '10044'};
      result = await search.search('测试村', options: options);
      expect(
        result.places.single.source == '高德地址解析',
        'Forward geocoding can succeed when POI permission is unavailable',
      );

      // Coordinate-less suggestions remain available if the optional fallback fails.
      replyOverride = (uri) => uri.path == '/v3/assistant/inputtips'
          ? {
              'status': '1',
              'tips': [
                {'name': '测试村', 'district': '浙江省杭州市', 'location': []},
              ],
            }
          : (uri.path.startsWith('/v3/')
                ? emptyAmap()
                : {'features': 'malformed'});
      result = await search.search('测试村', options: options);
      expect(
        result.places.single.point == null && result.notice!.contains('暂不可用'),
        'An optional fallback failure must not erase resolvable suggestions',
      );
      countBeforeResolve = uris.length;
      result = await search.search('测试', options: options, suggestions: true);
      expect(
        result.places.single.point == null &&
            uris
                .skip(countBeforeResolve)
                .every((u) => u.host == 'restapi.amap.com'),
        'Useful coordinate-less suggestions must not be discarded or trigger extra fallback on each keystroke',
      );

      // No data anywhere must not manufacture a fallback/default coordinate.
      replyOverride = (uri) =>
          uri.path.startsWith('/v3/') ? emptyAmap() : {'features': []};
      resolved = await search.resolve(noId, options: options, center: origin);
      expect(
        resolved.places.isEmpty && resolved.notice!.contains('地图上选点'),
        'Unresolved suggestions must never substitute the map center as their location',
      );

      replyOverride = (uri) =>
          uri.path.startsWith('/v3/') ? emptyAmap() : photon;
      final oldResolution = search
          .resolve(
            const AndroidPlace('slow-resolution', '', null),
            options: options,
          )
          .then<bool>(
            (_) => false,
            onError: (Object e) => e is SearchCancelled,
          );
      await resolutionStarted.future;
      final freshAfterResolve = await search.search('fresh');
      resolutionRelease.complete();
      expect(
        await oldResolution,
        'A new search cancels an in-progress address resolution',
      );
      expect(
        freshAfterResolve.places.single.point == origin,
        'Cancelled resolution cannot overwrite the replacement search',
      );
      replyOverride = null;
    }, _LocalOverrides(server.port, uris));

    final parsed = AndroidPlaceSearch.parseAmap({
      'pois': [
        poi,
        {'name': 'bad', 'location': 'NaN,0'},
      ],
    }, tips: false);
    expect(parsed.length == 1, 'Reject non-finite provider coordinates');
    final parsedGeocodes = AndroidPlaceSearch.parseAmapGeocodes({
      'geocodes': [
        {
          'formatted_address': '零坐标',
          'location': '0,0',
          'province': [],
          'level': [],
        },
        {'formatted_address': 'invalid', 'location': 'NaN,0'},
        {'formatted_address': 'invalid', 'location': '181,0'},
        {'formatted_address': [], 'location': '1,1'},
        {'formatted_address': 'missing', 'location': []},
      ],
    });
    expect(
      parsedGeocodes.length == 1 &&
          parsedGeocodes.single.point == const LatLng(0, 0),
      'Geocoding rejects malformed coordinates/array fields while preserving a real zero point',
    );
    expect(
      AndroidPlaceSearch.contextualQuery(
            const AndroidPlace(
              '测试村',
              '浙江省杭州市余杭区百丈镇测试村',
              null,
              region: '浙江省杭州市余杭区',
            ),
          ) ==
          '浙江省杭州市余杭区百丈镇测试村',
      'A full address must not duplicate region or place name',
    );
    final ranked = AndroidPlaceSearch.rankAndMerge(
      [
        const AndroidPlace(
          '咖啡店 分店',
          '',
          LatLng(31.23041, 121.4737),
          id: 'near',
        ),
        const AndroidPlace('咖啡店', '', LatLng(39.9, 116.4), id: 'exact'),
        const AndroidPlace(
          '咖啡店 分店',
          '',
          LatLng(31.23041, 121.4737),
          id: 'near',
        ),
      ],
      '咖啡店',
      origin,
    );
    expect(
      ranked.length == 2 && ranked.first.id == 'exact',
      'Deduplicate and preserve exact-name intent',
    );
    final upgraded = AndroidPlaceSearch.rankAndMerge(
      [
        const AndroidPlace('测试村', '区域', null, id: 'same', source: '高德搜索'),
        const AndroidPlace('测试村', '区域', origin, id: 'same', source: '高德搜索'),
      ],
      '测试村',
      null,
    );
    expect(
      upgraded.length == 1 && upgraded.single.point == origin,
      'Deduplication must preserve the usable point when an earlier suggestion had none',
    );
    stdout.writeln('Android search integration checks: $checks passed');
  } finally {
    search.cancel();
    if (!slowRelease.isCompleted) slowRelease.complete();
    if (!resolutionRelease.isCompleted) resolutionRelease.complete();
    if (!detailTimeoutRelease.isCompleted) detailTimeoutRelease.complete();
    await subscription.cancel();
    await server.close(force: true);
  }
}

class _LocalOverrides extends HttpOverrides {
  _LocalOverrides(this.port, this.uris);
  final int port;
  final List<Uri> uris;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _LocalClient(super.createHttpClient(context), port, uris);
}

class _LocalClient implements HttpClient {
  _LocalClient(this.inner, this.port, this.uris);
  final HttpClient inner;
  final int port;
  final List<Uri> uris;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  set userAgent(String? value) => inner.userAgent = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    uris.add(url);
    return inner.getUrl(
      url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
