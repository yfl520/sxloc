import 'dart:io';

// Built-in map and search services must not depend on a stale local proxy.
// Open services try direct first, retaining a configured proxy as a fallback.
// Unrelated hosts retain their environment proxy policy, including NO_PROXY.
String mapServiceProxy(Uri uri, {Map<String, String>? environment}) {
  if (uri.scheme == 'https' &&
      (uri.host == 'restapi.amap.com' ||
          RegExp(r'^webrd0[1-4]\.is\.autonavi\.com$').hasMatch(uri.host))) {
    return 'DIRECT';
  }
  final configured = HttpClient.findProxyFromEnvironment(
    uri,
    environment: environment,
  );
  if (uri.scheme == 'https' &&
      (uri.host == 'tile.openstreetmap.org' ||
          uri.host == 'photon.komoot.io')) {
    return configured == 'DIRECT' ? 'DIRECT' : 'DIRECT; $configured';
  }
  return configured;
}
