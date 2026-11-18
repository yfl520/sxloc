import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suixing_loc/map_tile_network.dart';
import 'package:suixing_loc/map_service_proxy.dart';

void main() {
  const proxyEnvironment = {
    'https_proxy': 'http://127.0.0.1:1',
    'http_proxy': 'http://127.0.0.1:1',
  };

  test('all four Amap tile hosts bypass a leftover proxy', () {
    for (var i = 1; i <= 4; i++) {
      expect(
        mapServiceProxy(
          Uri.parse('https://webrd0$i.is.autonavi.com/appmaptile'),
          environment: proxyEnvironment,
        ),
        'DIRECT',
      );
    }
  });

  test('OpenStreetMap tries direct before a configured proxy', () {
    expect(
      mapServiceProxy(
        Uri.parse('https://tile.openstreetmap.org/13/6860/3347.png'),
        environment: proxyEnvironment,
      ),
      'DIRECT; PROXY 127.0.0.1:1',
    );
  });

  test('OpenStreetMap still respects NO_PROXY', () {
    expect(
      mapServiceProxy(
        Uri.parse('https://tile.openstreetmap.org/13/6860/3347.png'),
        environment: {
          ...proxyEnvironment,
          'no_proxy': 'tile.openstreetmap.org',
        },
      ),
      'DIRECT',
    );
  });

  test('the bypass does not match unrelated or lookalike domains', () {
    for (final host in [
      'restapi.amap.com.example.org',
      'webrd01.is.autonavi.com.example.org',
      'tile.openstreetmap.org.example.org',
      'photon.komoot.io.example.org',
      'example.org',
    ]) {
      expect(
        mapServiceProxy(Uri.https(host, '/'), environment: proxyEnvironment),
        'PROXY 127.0.0.1:1',
      );
    }
  });

  test(
    'Amap suggestions, search, details and geocoding bypass a stopped proxy',
    () {
      for (final path in [
        '/v3/assistant/inputtips',
        '/v3/place/text',
        '/v3/place/detail',
        '/v3/geocode/geo',
      ]) {
        expect(
          mapServiceProxy(
            Uri.https('restapi.amap.com', path),
            environment: proxyEnvironment,
          ),
          'DIRECT',
        );
      }
    },
  );

  test('built-in open search tries direct before a configured proxy', () {
    expect(
      mapServiceProxy(
        Uri.https('photon.komoot.io', '/api/', {'q': 'test'}),
        environment: proxyEnvironment,
      ),
      'DIRECT; PROXY 127.0.0.1:1',
    );
  });

  test('custom services preserve their proxy and NO_PROXY settings', () {
    for (final host in ['custom.example.org', 'nominatim.openstreetmap.org']) {
      expect(
        mapServiceProxy(Uri.https(host, '/'), environment: proxyEnvironment),
        'PROXY 127.0.0.1:1',
      );
      expect(
        mapServiceProxy(
          Uri.https(host, '/'),
          environment: {...proxyEnvironment, 'no_proxy': host},
        ),
        'DIRECT',
      );
    }
  });

  Future<void> checkRetries(List<int> statuses, int requests) async {
    await HttpOverrides.runZoned(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var received = 0;
      server.listen((request) async {
        request.response.statusCode =
            statuses[received.clamp(0, statuses.length - 1)];
        received++;
        request.response.write('tile-response');
        await request.response.close();
      });
      final client = createMapTileClient();
      try {
        final response = await client.get(
          Uri.parse('http://127.0.0.1:${server.port}/tile'),
        );
        expect(received, requests);
        expect(
          response.statusCode,
          statuses[(requests - 1).clamp(0, statuses.length - 1)],
        );
      } finally {
        client.close();
        await server.close(force: true);
      }
    }, findProxyFromEnvironment: (_, _) => 'DIRECT');
  }

  test('a temporary server failure is retried once', () async {
    await checkRetries([503, 200], 2);
  });

  test('persistent failures stop after one retry', () async {
    await checkRetries([503], 2);
  });

  test('permanent HTTP errors are not retried', () async {
    await checkRetries([404], 1);
  });
}
