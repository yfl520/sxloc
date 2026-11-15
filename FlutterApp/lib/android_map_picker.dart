import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'android_place_search.dart';
import 'android_search_settings.dart';
import 'coordinates.dart';

class AndroidMapPicker extends StatefulWidget {
  const AndroidMapPicker({super.key, this.initial});

  final LatLng? initial;

  @override
  State<AndroidMapPicker> createState() => _AndroidMapPickerState();
}

class _AndroidMapPickerState extends State<AndroidMapPicker> {
  final _map = MapController();
  final _query = TextEditingController();
  final _search = AndroidPlaceSearch();
  final _searchFocus = FocusNode();
  PlaceSearchOptions _options = const PlaceSearchOptions();
  Timer? _debounce;
  bool _configLoaded = false;
  bool _suggestions = false;
  bool _resolving = false;
  bool _composing = false;
  String _observedQuery = '';
  String _resultSource = '';
  String _resultQuery = '';
  String _address = '';
  String? _searchNotice;
  String? _configError;
  LatLng? _resultCenter;
  late LatLng _point;
  bool _amap = true;
  bool _ready = false;
  bool _searching = false;
  bool _hasSelection = false;
  bool _showResults = false;
  int _generation = 0;
  int _tileRevision = 0;
  DateTime? _lastSearch;
  String _name = '地图选点';
  String? _searchMessage;
  String? _tileWarning;
  List<AndroidPlace> _results = [];

  static const _blue = Color(0xFF007AFF);
  static const _secondary = Color(0xFF71717A);

  @override
  void initState() {
    super.initState();
    _point = widget.initial ?? const LatLng(31.2304, 121.4737);
    _hasSelection = widget.initial != null;
    if (_hasSelection) _name = '当前填写的位置';
    _query.addListener(_onQueryChanged);
    unawaited(_loadSearchOptions());
  }

  Future<void> _loadSearchOptions() async {
    try {
      final options = await loadAndroidSearchOptions();
      if (!mounted) return;
      setState(() {
        _options = options;
        _configLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _configLoaded = true;
        _configError = '搜索设置读取失败，暂用开放地图；可打开设置重新保存。';
      });
    }
  }

  Future<void> _settings() async {
    _dismissSearch();
    final options = await Navigator.of(context).push<PlaceSearchOptions>(
      CupertinoPageRoute(
        builder: (_) => AndroidSearchSettings(options: _options),
      ),
    );
    if (!mounted || options == null) return;
    setState(() {
      _options = options;
      _configError = null;
    });
    if (_query.text.trim().isNotEmpty) await _find();
  }

  void _onQueryChanged() {
    final composing =
        _query.value.composing.isValid && !_query.value.composing.isCollapsed;
    if (_observedQuery == _query.text && composing == _composing) return;
    _observedQuery = _query.text;
    _composing = composing;
    _dismissSearch(unfocus: false);
    if (!_configLoaded || composing || _query.text.trim().length < 2) return;
    final minInterval = _options.useAmap ? 700 : 1100;
    final elapsed = _lastSearch == null
        ? minInterval
        : DateTime.now().difference(_lastSearch!).inMilliseconds;
    final delay = (minInterval - elapsed).clamp(650, minInterval);
    _debounce = Timer(
      Duration(milliseconds: delay),
      () => unawaited(_find(suggestions: true)),
    );
  }

  LatLng _viewPoint(LatLng point) {
    final display = Coordinates.display(point, _amap);
    return LatLng(display.latitude.clamp(-85.0511, 85.0511), display.longitude);
  }

  void _pick(
    LatLng point,
    String name, {
    bool move = false,
    String address = '',
  }) {
    _debounce?.cancel();
    ++_generation;
    _search.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _point = point;
      _name = name;
      _address = address;
      _hasSelection = true;
      _showResults = false;
      _searching = false;
      _resolving = false;
    });
    if (move && _ready) _map.move(_viewPoint(point), 16);
  }

  void _changeSource(bool amap) {
    if (!_ready || amap == _amap) return;
    // Preserve the viewed WGS84 center as well as the selected target on source changes.
    final center = Coordinates.picked(_map.camera.center, _amap);
    final zoom = _map.camera.zoom.clamp(2.0, amap ? 18.0 : 19.0);
    setState(() {
      _amap = amap;
      _tileWarning = null;
    });
    _map.move(_viewPoint(center), zoom);
  }

  void _zoom(double delta) {
    if (!_ready) return;
    _map.move(
      _map.camera.center,
      (_map.camera.zoom + delta).clamp(2.0, _amap ? 18.0 : 19.0),
    );
  }

  Future<void> _find({bool suggestions = false}) async {
    _debounce?.cancel();
    final query = _query.text.trim();
    if (query.isEmpty || !_configLoaded || _composing) return;
    _lastSearch = DateTime.now();
    final generation = ++_generation;
    _search.cancel();
    if (!suggestions) FocusManager.instance.primaryFocus?.unfocus();
    final center = _ready
        ? Coordinates.picked(_map.camera.center, _amap)
        : _point;
    setState(() {
      _searching = true;
      _resolving = false;
      _suggestions = suggestions;
      _showResults = true;
      _results = [];
      _searchMessage = null;
      _searchNotice = null;
      _resultCenter = center;
      _resultQuery = query;
      _resultSource = _options.useAmap ? '高德搜索' : '开放地图 · © OpenStreetMap';
    });
    try {
      final found = await _search.search(
        query,
        options: _options,
        center: center,
        suggestions: suggestions,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = found.places;
        _resultSource = found.source;
        _searchNotice = found.notice;
        _searchMessage = found.places.isEmpty
            ? (suggestions ? '暂无联想结果，可补全关键词后点“搜索”。' : '未找到地点，试试城市加地名，或直接在地图选点。')
            : null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _searchMessage = searchErrorText(error);
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _searching = false);
      }
    }
  }

  void _dismissSearch({bool unfocus = true}) {
    _debounce?.cancel();
    ++_generation;
    _search.cancel();
    if (unfocus) FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _searching = false;
      _showResults = false;
      _resolving = false;
    });
  }

  Future<void> _selectPlace(AndroidPlace place) async {
    if (_resolving) return;
    if (place.point != null) {
      _pickPlace(place);
      return;
    }
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _resolving = true;
      _searching = false;
      _searchNotice = null;
      _searchMessage = '正在查找这个地点的坐标…';
    });
    try {
      final resolved = await _search.resolve(
        place,
        options: _options,
        center: _resultCenter,
      );
      if (!mounted || generation != _generation) return;
      if (resolved.places.length == 1 && !resolved.needsConfirmation) {
        _pickPlace(resolved.places.single);
        return;
      }
      setState(() {
        _results = resolved.places;
        _resultSource = resolved.source;
        _suggestions = false;
        _searchNotice = resolved.notice;
        _searchMessage = resolved.places.isEmpty
            ? '未找到可用坐标，可在地图上选择具体位置。'
            : '请选择与你要去的位置相符的结果。';
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _searchMessage = searchErrorText(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _resolving = false);
      }
    }
  }

  void _pickPlace(AndroidPlace place) {
    if (place.point == null) return;
    _pick(
      place.point!,
      place.name,
      move: true,
      address: [
        if (place.source == '高德地址解析') place.category,
        if (place.address.isNotEmpty) place.address,
      ].join(' · '),
    );
  }

  String _distance(AndroidPlace place) {
    if (place.point == null || _resultCenter == null) return '选择后查找具体位置';
    final meters = const Distance()(_resultCenter!, place.point!);
    return meters < 1000
        ? '距地图中心 ${meters.round()} 米'
        : '距地图中心 ${(meters / 1000).toStringAsFixed(meters < 10000 ? 1 : 0)} 公里';
  }

  void _tileError() {
    if (_tileWarning != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _tileWarning == null) {
        setState(() => _tileWarning = '部分地图未加载，请检查网络或切换底图。');
      }
    });
  }

  @override
  void dispose() {
    ++_generation;
    _debounce?.cancel();
    _search.cancel();
    _query.removeListener(_onQueryChanged);
    _query.dispose();
    _searchFocus.dispose();
    _map.dispose();
    super.dispose();
  }

  Widget _small(String text) => Text(
    text,
    style: const TextStyle(fontSize: 12, color: _secondary, height: 1.4),
  );

  Widget _mapButton(IconData icon, String label, VoidCallback? onPressed) =>
      Semantics(
        label: label,
        child: CupertinoButton(
          padding: const EdgeInsets.all(12),
          color: const Color(0xF5FFFFFF),
          borderRadius: BorderRadius.circular(13),
          onPressed: onPressed,
          child: Icon(icon, size: 22),
        ),
      );

  Widget _searchBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
    child: Row(
      children: [
        Expanded(
          child: CupertinoTextField(
            controller: _query,
            focusNode: _searchFocus,
            placeholder: '地名、地址或纬度,经度',
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _find(),
            onTap: () {
              if (!_showResults &&
                  _results.isNotEmpty &&
                  _resultQuery == _query.text.trim()) {
                setState(() => _showResults = true);
              }
            },
            clearButtonMode: OverlayVisibilityMode.editing,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
            prefix: const Padding(
              padding: EdgeInsets.only(left: 12),
              child: Icon(CupertinoIcons.search, size: 18, color: _secondary),
            ),
            decoration: BoxDecoration(
              color: CupertinoColors.white,
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          onPressed: _searching || _resolving ? _dismissSearch : _find,
          child: Text(
            _searching || _resolving ? '取消' : '搜索',
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ],
    ),
  );

  Widget _resultPanel(double maxHeight) => Positioned(
    top: 8,
    left: 12,
    right: 12,
    child: Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: const Color(0xFCFFFFFF),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Color(0x18000000), blurRadius: 16)],
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 4, 8, 12),
        shrinkWrap: true,
        children: [
          Row(
            children: [
              Expanded(
                child: _small(
                  '${_suggestions ? '输入联想' : '搜索结果'} · $_resultSource',
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.all(10),
                onPressed: _dismissSearch,
                child: const Icon(CupertinoIcons.xmark, size: 16),
              ),
            ],
          ),
          if (_searching || _resolving)
            const Padding(
              padding: EdgeInsets.all(18),
              child: CupertinoActivityIndicator(),
            ),
          if (_searchMessage != null) _small(_searchMessage!),
          if (_searchNotice != null) _small(_searchNotice!),
          ..._results.map(
            (place) => CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
              alignment: Alignment.centerLeft,
              onPressed: _resolving ? null : () => _selectPlace(place),
              child: Row(
                children: [
                  const Icon(CupertinoIcons.map_pin, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            color: Color(0xFF1D1D1F),
                          ),
                        ),
                        if (place.address.isNotEmpty) _small(place.address),
                        const SizedBox(height: 3),
                        _small(
                          [
                            if (place.category.isNotEmpty) place.category,
                            _distance(place),
                          ].join(' · '),
                        ),
                      ],
                    ),
                  ),
                  const Icon(CupertinoIcons.chevron_right, size: 13),
                ],
              ),
            ),
          ),
          if (!_searching && !_resolving && _searchMessage != null)
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: _dismissSearch,
              child: const Text('关闭结果，在地图上选点', style: TextStyle(fontSize: 14)),
            ),
        ],
      ),
    ),
  );

  Widget _mapArea() => LayoutBuilder(
    builder: (context, constraints) => Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _viewPoint(_point),
            initialZoom: 13,
            minZoom: 2,
            maxZoom: _amap ? 18 : 19,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () {
              if (mounted) setState(() => _ready = true);
            },
            onTap: (_, p) => _pick(Coordinates.picked(p, _amap), '地图选点'),
            onLongPress: (_, p) => _pick(Coordinates.picked(p, _amap), '地图选点'),
          ),
          children: [
            TileLayer(
              key: ValueKey('$_amap-$_tileRevision'),
              urlTemplate: _amap
                  ? 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}'
                  : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              subdomains: _amap ? const ['1', '2', '3', '4'] : const [],
              userAgentPackageName: 'cn.suixing.suixing_loc',
              maxZoom: _amap ? 18 : 19,
              errorTileCallback: (_, _, _) => _tileError(),
            ),
            if (_hasSelection)
              MarkerLayer(
                markers: [
                  Marker(
                    point: Coordinates.display(_point, _amap),
                    width: 48,
                    height: 48,
                    alignment: Alignment.topCenter,
                    child: const IgnorePointer(
                      child: Icon(
                        CupertinoIcons.map_pin,
                        color: Color(0xFFFF3B30),
                        size: 46,
                        shadows: [
                          Shadow(
                            color: Color(0x50000000),
                            blurRadius: 6,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
        Positioned(
          top: 12,
          right: 12,
          child: Column(
            children: [
              _mapButton(
                CupertinoIcons.plus,
                '放大地图',
                _ready ? () => _zoom(1) : null,
              ),
              const SizedBox(height: 8),
              _mapButton(
                CupertinoIcons.minus,
                '缩小地图',
                _ready ? () => _zoom(-1) : null,
              ),
              const SizedBox(height: 8),
              _mapButton(
                CupertinoIcons.scope,
                '回到所选位置',
                _ready && _hasSelection
                    ? () => _map.move(_viewPoint(_point), _map.camera.zoom)
                    : null,
              ),
            ],
          ),
        ),
        if (_tileWarning != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 32,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              decoration: BoxDecoration(
                color: const Color(0xF5FFFFFF),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Row(
                children: [
                  Expanded(child: _small(_tileWarning!)),
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    onPressed: () => setState(() {
                      ++_tileRevision;
                      _tileWarning = null;
                    }),
                    child: const Text('重试', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
          ),
        Positioned(
          bottom: 5,
          left: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            color: const Color(0xE6FFFFFF),
            child: Text(
              _amap ? '© 高德地图' : '© OpenStreetMap 贡献者',
              style: const TextStyle(fontSize: 10, color: Color(0xFF48484A)),
            ),
          ),
        ),
        if (_showResults) _resultPanel(constraints.maxHeight * .95),
      ],
    ),
  );

  Widget _selection() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              CupertinoIcons.location_circle_fill,
              size: 26,
              color: _blue,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _hasSelection ? _name : '轻点地图选择位置',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  _small(
                    _hasSelection
                        ? '${_point.latitude.toStringAsFixed(6)}, ${_point.longitude.toStringAsFixed(6)} · WGS-84'
                        : '双指缩放，可搜索地名或输入经纬度',
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_address.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              _address,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: _secondary),
            ),
          ),
        CupertinoButton.filled(
          borderRadius: BorderRadius.circular(14),
          onPressed: _hasSelection && !_resolving
              ? () => Navigator.pop(context, _point)
              : null,
          child: const Text(
            '选好并填入坐标',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final landscapeKeyboard = MediaQuery.sizeOf(context).height < 500;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('地图选点'),
        previousPageTitle: '返回',
        backgroundColor: const Color(0xF5F2F3F7),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 36),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(fontSize: 14)),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _searchBar(),
            if (!keyboard)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 10, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: _small(
                        _configError ??
                            '${_options.useAmap ? '高德搜索' : '开放地图搜索'} · ${_options.city.isEmpty ? '跟随地图区域' : _options.city}',
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: const Size(44, 32),
                      onPressed: _configLoaded ? _settings : null,
                      child: const Text('搜索设置', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            if (!landscapeKeyboard)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: CupertinoSlidingSegmentedControl<bool>(
                        groupValue: _amap,
                        children: const {
                          true: Padding(
                            padding: EdgeInsets.symmetric(vertical: 6),
                            child: Text('高德地图', style: TextStyle(fontSize: 13)),
                          ),
                          false: Text('开放地图', style: TextStyle(fontSize: 13)),
                        },
                        onValueChanged: (value) {
                          if (value != null) _changeSource(value);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(child: ClipRect(child: _mapArea())),
            if (!keyboard) _selection(),
          ],
        ),
      ),
    );
  }
}
