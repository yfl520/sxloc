import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/retry.dart';

import 'map_service_proxy.dart';

http.Client createMapTileClient() {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..findProxy = mapServiceProxy;
  return RetryClient(
    IOClient(client),
    retries: 1,
    when: (response) => const [502, 503, 504].contains(response.statusCode),
    whenError: (error, _) =>
        error is SocketException || error is TimeoutException,
  );
}
