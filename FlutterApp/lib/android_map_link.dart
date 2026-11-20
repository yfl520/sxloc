import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';

import 'coordinates.dart';
import 'map_link_coordinates.dart';

enum MapLinkDatum { automatic, wgs84, gcj02, bd09 }

class MapLinkPlace {
  const MapLinkPlace(
    this.rawPoint,
    this.source,
    this.name,
    this.datum, {
    this.approximate = false,
  });
  final LatLng rawPoint;
  final String source;
  final String name;
  final MapLinkDatum datum;
  final bool approximate;

  LatLng point([MapLinkDatum selected = MapLinkDatum.automatic]) =>
      switch (selected == MapLinkDatum.automatic ? datum : selected) {
        MapLinkDatum.gcj02 => Coordinates.picked(rawPoint, true),
        MapLinkDatum.bd09 => MapLinkCoordinates.fromBaidu(rawPoint),
        _ => rawPoint,
      };

  String get title => name.isEmpty ? '$source导入位置' : name;
  String get notice =>
      approximate ? '链接只包含地图中心，请在地图上核对具体位置。' : '已识别$source点位，请在地图上核对后使用。';
}

class MapLinkException implements Exception {
  const MapLinkException(this.message);
  final String message;
}

/// All requests remain on-device, are bounded and restricted to map providers.
/// No WebView, remote parser, script execution or certificate override is used.
class AndroidMapLink {
  AndroidMapLink({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() _clientFactory;
  HttpClient? _client;

  void cancel() {
    _client?.close(force: true);
    _client = null;
  }

  static const _number = r'([+-]?\d+(?:\.\d+)?)';
  static final _pair = RegExp(
    '^\\s*$_number\\s*[,，]\\s*$_number(?:\\s*[,，].*)?\\s*\$',
  );
  static final _url = RegExp(r'''https?://[^\s<>"“”]+''', caseSensitive: false);

  static String? provider(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'amap.com' ||
        host.endsWith('.amap.com') ||
        host == 'gaode.com' ||
        host.endsWith('.gaode.com')) {
      return '高德地图';
    }
    if (host == 'maps.apple.com' ||
        host == 'maps.apple.com.cn' ||
        host == 'maps.apple') {
      return '苹果地图';
    }
    if (host == 'map.baidu.com' ||
        host == 'ditu.baidu.com' ||
        host == 'j.map.baidu.com' ||
        host == 'api.map.baidu.com') {
      return '百度地图';
    }
    if (const [
          'map.qq.com',
          'j.map.qq.com',
          'apis.map.qq.com',
        ].contains(host) ||
        (host == 'mapapi.qq.com' &&
            uri.path.startsWith('/web/mapComponents/'))) {
      return '腾讯地图';
    }
    if (host == 'maps.google.com' || host == 'maps.google.cn') {
      return 'Google 地图';
    }
    if (host == 'maps.app.goo.gl' ||
        (host == 'goo.gl' && uri.path.startsWith('/maps'))) {
      return 'Google 地图';
    }
    if (const [
          'google.com',
          'www.google.com',
          'www.google.cn',
          'www.google.com.hk',
          'google.com.hk',
          'www.google.co.jp',
          'www.google.co.uk',
        ].contains(host) &&
        uri.path.startsWith('/maps')) {
      return 'Google 地图';
    }
    return null;
  }

  static bool allowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      provider(uri) != null;

  static Uri? inputUri(String text) {
    for (final match in _url.allMatches(text)) {
      final uri = Uri.tryParse(
        match[0]!.replaceFirst(RegExp(r'[)）\]】。，；;]+$'), ''),
      );
      if (uri != null) {
        final candidate = _secure(uri);
        if (allowed(candidate)) return candidate;
      }
    }
    return null;
  }

  // Older map share sheets still emit HTTP links. Upgrade only known map hosts;
  // the resolver never performs an HTTP request or disables TLS verification.
  static Uri _secure(Uri uri) =>
      uri.scheme == 'http' &&
          uri.userInfo.isEmpty &&
          (!uri.hasPort || uri.port == 80) &&
          provider(uri) != null
      ? uri.replace(scheme: 'https', port: 443)
      : uri;

  static LatLng? _coordinates(String? value, {bool longitudeFirst = false}) {
    if (value == null) return null;
    final match = _pair.firstMatch(value);
    if (match == null) return null;
    final a = double.tryParse(match[1]!), b = double.tryParse(match[2]!);
    if (a == null || b == null) return null;
    final lat = longitudeFirst ? b : a, lon = longitudeFirst ? a : b;
    return MapLinkCoordinates.valid(lat, lon) ? LatLng(lat, lon) : null;
  }

  static MapLinkPlace? _parseUri(Uri uri) {
    try {
      return _parseLocation(uri);
    } on FormatException {
      return null;
    }
  }

  static MapLinkPlace? _parseLocation(Uri uri) {
    if (!allowed(uri)) return null;
    final source = provider(uri)!;
    final q = {...uri.queryParameters};
    if (source == '腾讯地图' && uri.fragment.contains('=')) {
      for (final entry in Uri.splitQueryString(uri.fragment).entries) {
        q.putIfAbsent(entry.key, () => entry.value);
      }
    }
    var name = q['name'] ?? q['poiname'] ?? q['title'] ?? q['address'] ?? '';
    LatLng? point;
    var approximate = false;
    if (source == '高德地图') {
      final p = q['p']?.split(',');
      if (p != null && p.length >= 3) {
        point = _coordinates('${p[1]},${p[2]}');
        if (p.length > 3) name = p[3];
      }
      point ??= _coordinates(q['q']);
      if (point != null &&
          name.isEmpty &&
          (q['q']?.split(',').length ?? 0) > 2) {
        name = q['q']!.split(',').skip(2).join(',');
      }
      point ??= _coordinates(
        q['position'] ?? q['lnglat'] ?? q['location'],
        longitudeFirst: true,
      );
      if (point == null) {
        point = _coordinates(q['center'], longitudeFirst: true);
        approximate = point != null;
      }
    } else if (source == '腾讯地图') {
      // Tencent URI marker uses lat,lng; legacy pointx/pointy is lng/lat.
      // https://lbs.qq.com/webApi/uriV1/uriGuide/uriWebMarker
      final marker = q['marker'];
      if (marker != null) {
        if (RegExp(r'(?:^|[;|])coord:').allMatches(marker).length != 1) {
          return null;
        }
        final attributes = <String, String>{};
        for (final field in marker.split(';')) {
          final colon = field.indexOf(':');
          if (colon > 0) {
            attributes[field.substring(0, colon)] = field.substring(colon + 1);
          }
        }
        point = _coordinates(attributes['coord']);
        if (name.isEmpty) name = attributes['title'] ?? '';
      }
      point ??= _coordinates(q['coord']?.split(';').first);
      if (point == null && q['pointx'] != null && q['pointy'] != null) {
        point = _coordinates('${q['pointy']},${q['pointx']}');
      }
      if (point == null) {
        point = _coordinates(q['center']);
        approximate = point != null;
      }
      if (point != null && q['coord_type'] == '1') {
        return MapLinkPlace(
          point,
          source,
          _name(name),
          MapLinkDatum.wgs84,
          approximate: approximate,
        );
      }
      if (q['coord_type'] != null && q['coord_type'] != '2') return null;
    } else if (source == '苹果地图') {
      point =
          _coordinates(q['coordinate']) ??
          _coordinates(q['ll']) ??
          _coordinates(q['q']);
      if (name.isEmpty && _coordinates(q['q']) == null) name = q['q'] ?? '';
      if (point == null) {
        point = _coordinates(q['sll'] ?? q['center']);
        approximate = point != null;
      }
    } else if (source == 'Google 地图') {
      final path = Uri.decodeFull(uri.path);
      final pin = RegExp('!3d$_number!4d$_number').firstMatch(uri.toString());
      if (pin != null) point = _coordinates('${pin[1]},${pin[2]}');
      point ??= _coordinates(q['query'] ?? q['q'] ?? q['destination']);
      if (point == null) {
        final center = RegExp('@$_number,$_number').firstMatch(path);
        if (center != null) point = _coordinates('${center[1]},${center[2]}');
        point ??= _coordinates(q['ll'] ?? q['center']);
        approximate = point != null;
      }
      final placeName = RegExp(r'/place/([^/]+)').firstMatch(path)?[1];
      if (name.isEmpty && placeName != null) {
        name = placeName.replaceAll('+', ' ');
      }
    } else {
      // Dropped pins may carry their exact BD09MC point in the mobile path,
      // separate from the nearby POI's coordinates in the page body.
      final shareGeo = RegExp('(?:^|[/&?])sharegeo=$_number,$_number')
          .firstMatch(Uri.decodeFull('${uri.path}?${uri.query}'));
      if (shareGeo != null) {
        final x = double.tryParse(shareGeo[1]!),
            y = double.tryParse(shareGeo[2]!);
        if (x != null && y != null) {
          point = MapLinkCoordinates.baiduMercator(x, y);
        }
        return point == null
            ? null
            : MapLinkPlace(point, source, _name(name), MapLinkDatum.bd09);
      }
      point = _coordinates(q['location'] ?? q['latlng']);
      final mc = RegExp('@$_number,$_number')
          .firstMatch(Uri.decodeFull(uri.path));
      if (point == null && mc != null) {
        final x = double.tryParse(mc[1]!), y = double.tryParse(mc[2]!);
        if (x != null && y != null && x.abs() > 100000) {
          point = MapLinkCoordinates.baiduMercator(x, y);
        }
      }
      if (name.isEmpty) {
        name =
            RegExp(r'/poi/([^/]+)').firstMatch(Uri.decodeFull(uri.path))?[1] ??
            '';
      }
      // lat/lng values from the Baidu URI API may explicitly use another datum.
      if (point != null && q['coord_type'] == 'wgs84') {
        return MapLinkPlace(point, source, _name(name), MapLinkDatum.wgs84);
      }
      if (point != null && q['coord_type'] == 'gcj02') {
        return MapLinkPlace(point, source, _name(name), MapLinkDatum.gcj02);
      }
    }
    if (point == null) return null;
    final datum = source == '百度地图'
        ? MapLinkDatum.bd09
        : source == '高德地图' ||
              source == '腾讯地图' ||
              MapLinkCoordinates.mainland(point)
        ? MapLinkDatum.gcj02
        : MapLinkDatum.wgs84;
    return MapLinkPlace(
      point,
      source,
      _name(name),
      datum,
      approximate: approximate,
    );
  }

  static String _name(String name) => name
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
      .trim()
      .runes
      .take(100)
      .map(String.fromCharCode)
      .join();

  static MapLinkPlace? parse(String input) {
    final text = input.trim();
    if (text.isEmpty || text.length > 8192) return null;
    final uri = inputUri(text);
    if (uri != null) return _parseUri(uri);
    final match = RegExp('^\\s*$_number\\s*[,，]\\s*$_number\\s*\$')
        .firstMatch(text);
    if (match == null) return null;
    final point = _coordinates(text);
    return point == null
        ? null
        : MapLinkPlace(point, '坐标', '', MapLinkDatum.wgs84);
  }

  Future<MapLinkPlace> resolve(String input) async {
    cancel();
    if (input.length > 8192) {
      throw const MapLinkException('分享内容过长');
    }
    final direct = parse(input);
    if (direct != null) return direct;
    var uri = inputUri(input);
    if (uri == null || !allowed(uri)) {
      throw const MapLinkException('分享内容不包含支持的地图链接');
    }
    final client = _clientFactory();
    _client = client;
    client.connectionTimeout = const Duration(seconds: 7);
    try {
      return await (() async {
        final seen = <String>{};
        for (var hop = 0; hop < 5; hop++) {
          final current = uri!;
          if (!identical(_client, client)) {
            throw const MapLinkException('解析已取消');
          }
          if (!allowed(current) || !seen.add(current.toString())) break;
          final request = await client.getUrl(current);
          request.followRedirects = false;
          request.headers.set(
            HttpHeaders.userAgentHeader,
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131.0 Mobile Safari/537.36',
          );
          request.headers.set(
            HttpHeaders.acceptLanguageHeader,
            'zh-CN,zh;q=0.9,en;q=0.5',
          );
          final response = await request.close();
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (response.isRedirect && location != null) {
            uri = _secure(current.resolve(location));
            if (!allowed(uri!)) {
              throw const MapLinkException('不支持此地图分享地址');
            }
            final place = _parseUri(uri!);
            if (place != null) return place;
            // No response body is required for redirects.
            await response.take(0).drain<void>();
            continue;
          }
          if (response.statusCode != 200) {
            throw const MapLinkException('地图分享页暂时无法访问');
          }
          final bytes = <int>[];
          await for (final chunk in response) {
            if (bytes.length + chunk.length > 512 * 1024) {
              throw const MapLinkException('地图分享页过大');
            }
            bytes.addAll(chunk);
          }
          final found = parsePage(
            utf8.decode(bytes, allowMalformed: true),
            current,
          );
          if (found != null) return found;
          break;
        }
        throw const MapLinkException('分享链接中没有可用坐标');
      })().timeout(const Duration(seconds: 18));
    } on MapLinkException {
      rethrow;
    } on TimeoutException {
      throw const MapLinkException('地图链接解析超时');
    } catch (_) {
      throw const MapLinkException('无法读取地图分享页');
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  static MapLinkPlace? parsePage(String html, Uri origin) {
    if (!allowed(origin)) return null;
    // Only inspect a page's canonical/share metadata, never unrelated links,
    // recommended places or arbitrary pairs of numbers in HTML.
    final text = html.replaceAll('&amp;', '&').replaceAll(r'\/', '/');
    for (final tag in RegExp(
      r'<(?:meta|link)\b[^>]{0,4096}>',
      caseSensitive: false,
    ).allMatches(text)) {
      final attributes = <String, String>{};
      for (final attr in RegExp(
        r'''([\w:-]+)\s*=\s*(["'])(.*?)\2''',
        dotAll: true,
      ).allMatches(tag[0]!)) {
        attributes[attr[1]!.toLowerCase()] = attr[3]!;
      }
      final value = attributes['property']?.toLowerCase() == 'og:url'
          ? attributes['content']
          : attributes['rel']?.toLowerCase() == 'canonical'
          ? attributes['href']
          : null;
      final parsed = value == null ? null : Uri.tryParse(value);
      final candidate = parsed == null
          ? null
          : _secure(origin.resolveUri(parsed));
      if (candidate == null || provider(candidate) != provider(origin)) {
        continue;
      }
      final hit = _parseUri(candidate);
      if (hit != null) return hit;
    }
    if (provider(origin) == '百度地图') {
      final dropped = origin.path.contains('/place/detail/')
          ? RegExp(
              r'"content"\s*:\s*\{\s*"point"\s*:\s*"([0-9.]+)\|([0-9.]+)"\s*,\s*"title"\s*:\s*"((?:\\.|[^"\\])*)"',
            ).firstMatch(text)
          : null;
      // Read the POI's explicit point object. A page may also contain a default
      // city's geo string or camera x/y, neither of which identifies this POI.
      final hit =
          dropped ??
          RegExp(
            r'''["']point["']\s*:\s*\{\s*["']x["']\s*:\s*["']?([0-9.]+)["']?\s*,\s*["']y["']\s*:\s*["']?([0-9.]+)["']?\s*\}''',
          ).firstMatch(text);
      if (hit != null) {
        final x = double.tryParse(hit[1]!), y = double.tryParse(hit[2]!);
        if (x != null && y != null && x > 1000000 && y > 100000) {
          final bd = MapLinkCoordinates.baiduMercator(x, y);
          if (bd != null) {
            String? title;
            if (dropped != null) {
              try {
                title = jsonDecode('"${dropped[3]}"') as String;
              } on FormatException {
                // A malformed label must not discard an otherwise valid pin.
              }
            } else {
              title = RegExp(
                r'<title>【([^<>]{1,100})】',
                caseSensitive: false,
              ).firstMatch(text)?[1];
            }
            return MapLinkPlace(
              bd,
              '百度地图',
              _name(title ?? ''),
              MapLinkDatum.bd09,
            );
          }
        }
      }
    }
    return null;
  }
}
