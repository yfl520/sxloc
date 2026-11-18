import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import 'map_tile_network.dart';

class MapTileLayer extends StatefulWidget {
  const MapTileLayer({
    super.key,
    required this.amap,
    required this.userAgentPackageName,
    required this.onError,
  });

  final bool amap;
  final String userAgentPackageName;
  final ErrorTileCallBack onError;

  @override
  State<MapTileLayer> createState() => _MapTileLayerState();
}

class _MapTileLayerState extends State<MapTileLayer> {
  // Keep the connection pool across ordinary UI rebuilds. TileLayer owns and
  // disposes the provider when this layer is replaced or the map is closed.
  late final _provider = _MapTileProvider(createMapTileClient());

  @override
  Widget build(BuildContext context) => TileLayer(
    urlTemplate: widget.amap
        ? 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}'
        : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    subdomains: widget.amap ? const ['1', '2', '3', '4'] : const [],
    userAgentPackageName: widget.userAgentPackageName,
    maxZoom: widget.amap ? 18 : 19,
    tileProvider: _provider,
    evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
    errorTileCallback: widget.onError,
  );
}

class _MapTileProvider extends NetworkTileProvider {
  _MapTileProvider(this._client)
    : super(httpClient: _client, attemptDecodeOfHttpErrorResponses: false);

  final http.Client _client;

  @override
  Future<void> dispose() async {
    _client.close();
    await super.dispose();
  }
}
