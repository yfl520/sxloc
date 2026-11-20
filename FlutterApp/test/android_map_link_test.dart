import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suixing_loc/android_map_link.dart';
import 'package:suixing_loc/coordinates.dart';
import 'package:suixing_loc/map_link_coordinates.dart';

void main() {
  test('高德分享文本、编码逗号和经纬度反序转换到同一个位置', () {
    const original = LatLng(30.25, 120.15);
    final gcj = Coordinates.toGcj(original);
    final inputs = [
      '湖滨公园 https://uri.amap.com/marker?position=${gcj.longitude},${gcj.latitude}&name=湖滨公园',
      'https://www.amap.com/?q=${gcj.latitude}%2C${gcj.longitude}%2C湖滨公园',
      'https://www.amap.com/?p=B0123,${gcj.latitude},${gcj.longitude},湖滨公园,杭州',
    ];
    for (final input in inputs) {
      final place = AndroidMapLink.parse(input)!;
      expect(place.name, '湖滨公园');
      expect(const Distance()(place.point(), original), lessThan(.5));
      expect(place.datum, MapLinkDatum.gcj02);
    }
  });

  test('苹果大陆转换，香港与境外保持 WGS84，允许手动指定来源坐标系', () {
    final mainland = AndroidMapLink.parse(
      'https://maps.apple.com/?coordinate=31.23,121.47&name=上海',
    )!;
    expect(mainland.datum, MapLinkDatum.gcj02);
    expect(mainland.point(MapLinkDatum.wgs84), const LatLng(31.23, 121.47));
    final hk = AndroidMapLink.parse(
      'https://maps.apple.com/?ll=22.284774,114.159437',
    )!;
    expect(hk.datum, MapLinkDatum.wgs84);
    final outside = AndroidMapLink.parse(
      'https://maps.apple.com/?ll=37.3346,-122.009&q=Apple+Park',
    )!;
    expect(outside.point(), const LatLng(37.3346, -122.009));
    expect(outside.name, 'Apple Park');
  });

  test('Google 优先地点针脚，只有画面中心时明确提示', () {
    final pin = AndroidMapLink.parse(
      'https://www.google.com/maps/place/Apple+Park/@37.439,-122.05,11z/data=!8m2!3d37.3346!4d-122.009',
    )!;
    expect(pin.point(), const LatLng(37.3346, -122.009));
    expect(pin.approximate, isFalse);
    final center = AndroidMapLink.parse(
      'https://www.google.com/maps/@37.439,-122.05,11z',
    )!;
    expect(center.approximate, isTrue);
    expect(center.notice, contains('地图中心'));
  });

  test('百度墨卡托及 BD09 转换，保留明确标注 WGS84 的原始坐标', () {
    final place = AndroidMapLink.parse(
      'https://map.baidu.com/poi/万象天地/@12686385.66,2560876.53,19z',
    )!;
    expect(place.source, '百度地图');
    expect(
      const Distance()(place.point(), const LatLng(22.544865, 113.951072)),
      lessThan(30),
    );
    final wgs = AndroidMapLink.parse(
      'https://api.map.baidu.com/marker?location=22.54,113.95&coord_type=wgs84',
    )!;
    expect(wgs.point(), const LatLng(22.54, 113.95));
    expect(MapLinkCoordinates.baiduMercator(double.infinity, 0), isNull);
  });

  test('纯坐标允许零值，拒绝越界、无关站点、凭据和非标准端口', () {
    expect(AndroidMapLink.parse('0,0')!.point(), const LatLng(0, 0));
    for (final input in [
      '91,120',
      '31,181',
      'https://example.com/?ll=31,120',
      'https://maps.apple.com.evil.test/?ll=31,120',
      'https://u:p@maps.apple.com/?ll=31,120',
      'https://maps.apple.com:8443/?ll=31,120',
      'https://127.0.0.1/?ll=31,120',
      'https://map.qq.com.evil.test/?coord=31,120',
      'https://news.qq.com/?coord=31,120',
      'https://mapapi.qq.com/unrelated/?coord=31,120',
      'https://maps.google.com.evil.test/?q=31,120',
    ]) {
      expect(AndroidMapLink.parse(input), isNull, reason: input);
    }
  });

  test('腾讯 URI 标注、传统点位及 fragment 统一转换，显式 GPS 坐标保持原值', () {
    const original = LatLng(30.25, 120.15);
    final gcj = Coordinates.toGcj(original);
    final coord = '${gcj.latitude},${gcj.longitude}';
    for (final input in [
      'https://apis.map.qq.com/uri/v1/marker?marker=coord:$coord;title:公园;addr:杭州&referer=test',
      'https://map.qq.com/?type=marker&pointx=${gcj.longitude}&pointy=${gcj.latitude}&name=公园',
      'https://map.qq.com/#type=marker&coord=$coord&name=公园',
      'https://mapapi.qq.com/web/mapComponents/locationMarker/v/index.html?marker=coord:$coord;title:公园',
    ]) {
      final place = AndroidMapLink.parse(input)!;
      expect(place.source, '腾讯地图');
      expect(place.name, '公园');
      expect(place.approximate, isFalse);
      expect(const Distance()(place.point(), original), lessThan(.5));
    }
    final gps = AndroidMapLink.parse(
      'https://apis.map.qq.com/uri/v1/geocoder?coord=30.25,120.15&coord_type=1',
    )!;
    expect(gps.datum, MapLinkDatum.wgs84);
    expect(gps.point(), original);
    expect(
      AndroidMapLink.parse(
        'https://map.qq.com/?marker=coord:30,120;title:A|coord:31,121;title:B',
      ),
      isNull,
    );
    expect(
      AndroidMapLink.parse('https://map.qq.com/?coord=30,120&coord_type=9'),
      isNull,
    );
  });

  test('百度手动落点优先使用 sharegeo，避免附近地点替代目标', () {
    final dropped = AndroidMapLink.parse(
      'https://map.baidu.com/mobile/webapp/place/detail/qt=inf&uid=test/act=read_share&sharegeo=13224540%2C3750567',
    )!;
    final desktop = AndroidMapLink.parse(
      'https://map.baidu.com/poi/地图上的点/@13224540,3750567,17z',
    )!;
    expect(const Distance()(dropped.point(), desktop.point()), lessThan(.1));
    expect(
      const Distance()(dropped.point(), const LatLng(32.07309, 118.78513)),
      lessThan(2),
    );
    expect(
      AndroidMapLink.parse('https://ditu.baidu.com/?location=30,120')?.source,
      '百度地图',
    );
  });

  test('Google 旧域名、标准搜索与地图中心，苹果新旧地点链接均可解析', () {
    for (final link in [
      'https://maps.google.com/?q=37.3346,-122.009',
      'https://maps.google.cn/?q=37.3346,-122.009',
      'https://www.google.com/maps/search/?api=1&query=37.3346%2C-122.009',
      'https://maps.apple.com/place?coordinate=37.3346,-122.009&name=Apple+Park',
      'https://maps.apple.com.cn/place?coordinate=37.3346,-122.009&name=Apple+Park',
      'https://maps.apple.com/?q=37.3346,-122.009',
    ]) {
      final place = AndroidMapLink.parse(link)!;
      expect(place.point(), const LatLng(37.3346, -122.009));
      expect(place.approximate, isFalse);
    }
    final center = AndroidMapLink.parse(
      'https://www.google.com/maps/@?api=1&map_action=map&center=37.3,-122.0',
    )!;
    expect(center.approximate, isTrue);
    expect(center.point(), const LatLng(37.3, -122));
  });

  test('分享文本跳过无关网址，保留编码的地点名称', () {
    final place = AndroidMapLink.parse(
      '来自 https://example.com/ 分享地点： https://map.qq.com/?coord=30,120&name=%E5%85%AC%E5%9B%AD%E3%80%82',
    )!;
    expect(place.source, '腾讯地图');
    expect(place.name, '公园。');
    expect(AndroidMapLink.parse('https://map.qq.com/?name=%E0%A4%A'), isNull);
  });

  test('四种地图短链按重定向解析，不将链接交给其他应用', () async {
    final samples = {
      'https://map.qq.com/shorturl?l=test':
          'https://map.qq.com/?pointx=120.15&pointy=30.25&name=公园',
      'https://j.map.baidu.com/test':
          'https://map.baidu.com/?location=30.25,120.15',
      'https://maps.apple/test': 'https://maps.apple.com/place?coordinate=37.3346,-122.009&name=Apple+Park',
      'https://maps.app.goo.gl/test':
          'https://maps.google.com/?q=37.3346,-122.009',
    };
    for (final sample in samples.entries) {
      final client = _Client((_) => _Response(302, location: sample.value));
      final place = await AndroidMapLink(clientFactory: () => client)
          .resolve(sample.key);
      expect(place.approximate, isFalse);
      expect(client.visited.length, 1);
      expect(client.closed, isTrue);
    }
  });

  test('网页中的视角和无关数字不成为目标', () {
    final origin = Uri.parse('https://map.baidu.com/poi/test');
    expect(
      AndroidMapLink.parsePage(
        '{"view_dir":"-0.8477,0.0000","x":"320","y":"480"}',
        origin,
      ),
      isNull,
    );
    expect(
      AndroidMapLink.parsePage(
        '{"point":{"x":"12686385.66","y":"2560876.53"}}',
        origin,
      )?.source,
      '百度地图',
    );
    expect(
      AndroidMapLink.parsePage('https://evil.test/?ll=31,120', origin),
      isNull,
    );
    expect(
      AndroidMapLink.parsePage(
        '<a href="https://map.baidu.com/?location=22.3,114.1">推荐地点</a>',
        origin,
      ),
      isNull,
    );
    expect(
      AndroidMapLink.parsePage(
        '<meta property="og:url" content="https://map.baidu.com/?location=22.3,114.1">',
        origin,
      )?.rawPoint,
      const LatLng(22.3, 114.1),
    );
  });

  test('百度短链页面使用地点 point，不把默认城市 geo 当作坐标', () {
    final origin = Uri.parse(
      'https://map.baidu.com/mobile/webapp/search/search/qt=inf&uid=test',
    );
    final place = AndroidMapLink.parsePage(
      '<title>【成都市人民公园】地址,电话_百度地图</title>'
      '{"geo":"1|12959238.56,4825347.47;","x":"12959238.56","y":"4825347.47",'
      '"point":{"x":"11584491.23","y":"3567106.32"}}',
      origin,
    )!;
    expect(place.name, '成都市人民公园');
    expect(place.point().latitude, closeTo(30.66, .02));
    expect(place.point().longitude, closeTo(104.05, .02));
    expect(
      AndroidMapLink.parsePage('{"geo":"1|12959238.56,4825347.47;"}', origin),
      isNull,
    );
    expect(
      AndroidMapLink.parsePage('{"x":"12959238.56","y":"4825347.47"}', origin),
      isNull,
    );
  });

  test('百度手动落点页面的 content.point 保留指定点位，不误用附近 POI', () {
    final page =
        r'{"geo":"1|12959238.56,4825347.47;","content":{"point":"13224540|3750567","title":"\u5730\u56fe\u4e0a\u7684\u70b9"},"nearby":{"point":{"x":"11584491.23","y":"3567106.32"}}}';
    final place = AndroidMapLink.parsePage(
      page,
      Uri.parse(
        'https://map.baidu.com/mobile/webapp/place/detail/qt=inf&uid=test/act=read_share',
      ),
    )!;
    expect(place.name, '地图上的点');
    expect(
      const Distance()(place.point(), const LatLng(32.07309, 118.78513)),
      lessThan(2),
    );
  });

  test('短链逐跳校验并读取重定向坐标，关闭请求连接', () async {
    final client = _Client(
      (uri) =>
          _Response(302, location: 'https://www.amap.com/?q=30.25,120.15,公园'),
    );
    final resolver = AndroidMapLink(clientFactory: () => client);
    final place = await resolver.resolve('分享：https://surl.amap.com/test');
    expect(place.name, '公园');
    expect(client.visited.length, 1);
    expect(client.closed, isTrue);
  });

  test('短链跳到非地图域名或回环时不会继续访问', () async {
    for (final location in [
      'https://evil.test/?ll=31,120',
      'https://127.0.0.1/',
    ]) {
      final client = _Client((uri) => _Response(302, location: location));
      final resolver = AndroidMapLink(clientFactory: () => client);
      await expectLater(
        resolver.resolve('https://surl.amap.com/test'),
        throwsA(isA<MapLinkException>()),
      );
      expect(client.visited.length, 1);
      expect(client.closed, isTrue);
    }
  });

  test('旧 HTTP 地图分享只升级为 HTTPS 访问', () async {
    final client = _Client(
      (uri) =>
          _Response(302, location: 'http://maps.apple.com/?ll=37.3,-122.0'),
    );
    final place = await AndroidMapLink(clientFactory: () => client)
        .resolve('http://surl.amap.com/test');
    expect(client.visited.single.scheme, 'https');
    expect(place.source, '苹果地图');
  });

  test('页面体积、重定向循环与服务错误受到限制', () async {
    for (final response in [
      _Response(200, text: 'a' * (512 * 1024 + 1)),
      _Response(302, location: 'https://surl.amap.com/test'),
      _Response(403),
    ]) {
      final client = _Client((uri) => response);
      await expectLater(
        AndroidMapLink(clientFactory: () => client)
            .resolve('https://surl.amap.com/test'),
        throwsA(isA<MapLinkException>()),
      );
      expect(client.visited.length, 1);
      expect(client.closed, isTrue);
    }
  });
}

class _Client implements HttpClient {
  _Client(this.respond);
  final _Response Function(Uri) respond;
  final visited = <Uri>[];
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    visited.add(url);
    return _Request(respond(url));
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  _Headers([this.location]);
  final String? location;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  String? value(String name) =>
      name == HttpHeaders.locationHeader ? location : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final _Response response;
  @override
  final headers = _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, {String? location, String text = ''})
    : headers = _Headers(location),
      data = utf8.encode(text);
  final List<int> data;
  @override
  final int statusCode;
  @override
  final _Headers headers;
  @override
  bool get isRedirect => statusCode >= 300 && statusCode < 400;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(data).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
