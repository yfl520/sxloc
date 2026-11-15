import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:window_manager/window_manager.dart';

import 'core_client.dart';
import 'coordinates.dart';
import 'settings_sheet.dart';
import 'ui.dart';
import 'desktop_about.dart';

class Workspace extends StatefulWidget {
  const Workspace({super.key});
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> with WindowListener {
  final core = CoreClient();
  final mapController = MapController();
  final search = TextEditingController();
  final searchFocus = FocusNode();
  final inspectorScroll = ScrollController();
  final removingSessions = <String>{};
  final fields = <String, TextEditingController>{};
  final labels = const {
    'latitude': '纬度',
    'longitude': '经度',
    'altitude': '高度（米）',
    'accuracy': '精度（米）',
    'rate': '周期（毫秒）',
    'speed': '速度（米/秒）',
    'bearing': '航向（度）',
    'quality': '定位质量',
    'satellites': '卫星数',
    'jitterMeters': '偏移半径（米）',
    'accuracyMin': '精度下限（米）',
    'accuracyMax': '精度上限（米）',
  };
  int page = 0, searchGeneration = 0, inspectorTab = 0, deviceMode = 0;
  bool usbRefreshing = false, usbBusy = false, usbRevealing = false;
  String? selectedUsb, developerModeHint;
  bool developerModeError = false;
  bool inspector = true,
      devicesCollapsed = false,
      searchCollapsed = false,
      favoritesCollapsed = false,
      applySuccess = false,
      showAppliedNotice = false,
      loading = true,
      searching = false,
      applying = false,
      connecting = false,
      refreshing = false,
      dirty = false,
      mapReady = false,
      amap = true,
      jitterPosition = false,
      jitterAccuracy = false,
      closing = false;
  String destination = '上海 · 人民广场',
      status = '正在准备定位组件…',
      searchHint = '搜索地名、地址，或输入经纬度';
  String? selectedMac, tileWarning;
  List<JsonMap> results = [];
  LatLng draft = const LatLng(31.2304, 121.4737);
  DateTime? lastTileError;
  DateTime? lastAppliedAt;
  String? applyError;
  String appliedName = '';
  LatLng? noticePoint;
  int applyAnimation = 0;
  Timer? successTimer, noticeTimer, searchDebounce;
  String lastSearchText = '';
  TextRange lastSearchComposing = TextRange.empty;

  void expandPanel() {
    if (page == 0) searchCollapsed = false;
    if (page == 1) favoritesCollapsed = false;
    if (page == 2) devicesCollapsed = false;
  }

  String get deliveryStatus {
    if (applying) return '正在更新目标…';
    if (!core.ready) return core.failure ?? '定位组件准备中';
    if (deviceMode == 1 || usbActive) {
      final usb = core.usb;
      if (usb['restoreWarning'] != null) {
        return usb['restoreWarning'].toString();
      }
      if (usb['error'] != null) return usb['error'].toString();
      if (usb['phase'] == 'connecting' || usb['phase'] == 'stopping') {
        return usb['status']?.toString() ?? '正在准备 USB 通道…';
      }
      if (usb['phase'] == 'simulating') {
        if (usb['lastRevision'] != core.target['revision']) {
          return '目标已更新 · 等待 USB 提交本次坐标';
        }
        return 'USB 已提交本次目标 · 手机结果待确认';
      }
      return usb['clearRequested'] == true
          ? '已发送停止模拟指令 · 手机结果待确认'
          : 'USB 未连接 · 目标仅保存在本机';
    }
    final active = core.sessions
        .where((s) => sessionActive(s) && s['error'] == null)
        .toList();
    if (active.isEmpty) return '未连接设备 · 目标仅保存在本机';
    final errors = active.where((s) => s['sendError'] != null).toList();
    if (errors.isNotEmpty) return '发送异常：${errors.first['sendError']}';
    final subscribed = active
        .where((s) => s['subscribed'] == true && s['authenticated'] == true)
        .toList();
    if (subscribed.isEmpty) {
      return active.any((s) => s['authenticated'] == true)
          ? '已认证 · 等待手机订阅定位'
          : '正在连接、识别或认证设备';
    }
    final current = subscribed
        .where(
          (s) =>
              CoreClient.map(s['report'])['revision'] ==
              core.target['revision'],
        )
        .toList();
    if (current.isEmpty) return '目标已更新 · 等待本次定位数据发送';
    final fresh = current.where((s) {
      final time = DateTime.tryParse(
        CoreClient.map(s['report'])['queuedAt']?.toString() ?? '',
      );
      final period = number(core.state['rate'], 1000).round();
      return time != null &&
          DateTime.now().toUtc().difference(time).inMilliseconds <=
              (period * 3).clamp(15000, 180000);
    }).length;
    if (fresh == 0) return '本次目标已提交发送 · 正在等待后续数据';
    return '正在发送本次目标 · $fresh/${active.length} 台 · 手机结果待确认';
  }

  String get updateAge {
    if (lastAppliedAt == null) return '当前保存的目标';
    final seconds = DateTime.now().difference(lastAppliedAt!).inSeconds;
    if (seconds < 5) return '刚刚更新';
    if (seconds < 60) return '$seconds 秒前更新';
    if (seconds < 3600) return '${seconds ~/ 60} 分钟前更新';
    return '${seconds ~/ 3600} 小时前更新';
  }

  double number(dynamic value, [double fallback = 0]) =>
      value is num ? value.toDouble() : fallback;
  String format(dynamic value, String key) => value is num
      ? (key == 'latitude' || key == 'longitude'
            ? value.toStringAsFixed(6)
            : value == value.roundToDouble()
            ? value.toInt().toString()
            : value.toString())
      : '';
  String coordinates(LatLng p) =>
      '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}';
  LatLng get applied => LatLng(
    number(core.target['latitude'], 31.2304),
    number(core.target['longitude'], 121.4737),
  );
  bool sessionActive(JsonMap session) =>
      session['running'] == true || session['starting'] == true;
  bool sessionRemovable(JsonMap session) =>
      session['error'] != null || !sessionActive(session);
  bool get selectedDeviceActive => core.sessions.any(
    (session) => session['mac'] == selectedMac && sessionActive(session),
  );
  bool get selectedDeviceStarting => core.sessions.any(
    (session) => session['mac'] == selectedMac && session['starting'] == true,
  );
  bool get usbActive => const [
    'connecting',
    'simulating',
    'stopping',
  ].contains(core.usb['phase']);
  int get connectedDevices =>
      core.sessions
          .where((s) => s['running'] == true && s['error'] == null)
          .length +
      (core.usb['phase'] == 'simulating' ? 1 : 0);

  Future<void> removeSessions(List<JsonMap> sessions) async {
    final ids = sessions
        .map((s) => s['id'].toString())
        .where((id) => !removingSessions.contains(id))
        .toSet();
    if (ids.isEmpty) return;
    setState(() => removingSessions.addAll(ids));
    await perform(() async {
      for (final id in ids) {
        await core.call('disconnect', {'id': id});
      }
      await core.refresh();
    });
    if (mounted) setState(() => removingSessions.removeAll(ids));
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
    for (final key in labels.keys) {
      fields[key] = TextEditingController();
    }
    core.addListener(changed);
    search.addListener(searchEdited);
    unawaited(start());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> start() async {
    await core.start();
    if (!mounted) return;
    if (core.ready) {
      for (final key in fields.keys) {
        fields[key]!.text = format(
          key == 'rate' ? core.state['rate'] : core.target[key],
          key,
        );
      }
      draft = applied;
      destination = '上次应用的位置';
      amap = core.settings['datum'] != 'wgs';
      jitterPosition = core.target['jitterPosition'] == true;
      jitterAccuracy = core.target['jitterAccuracy'] == true;
      selectedMac =
          core.devices
                  .where((d) => d['likelyApple'] == true)
                  .firstOrNull?['address']
              as String?;
      status = '已就绪，选择位置后应用到已连接的设备';
      if (mapReady) recenter();
    }
    setState(() => loading = false);
  }

  Future<void> perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) await showMessage(context, e.toString());
    }
  }

  void pick(LatLng p, String name, {bool pan = true}) {
    if (!p.latitude.isFinite ||
        !p.longitude.isFinite ||
        p.latitude.abs() > 90 ||
        p.longitude.abs() > 180) {
      return;
    }
    stopSearch();
    setState(() {
      results = [];
      searchHint = '已选择$name · ${coordinates(p)}';
      draft = p;
      destination = name;
      dirty = true;
      applySuccess = false;
      applyError = null;
      showAppliedNotice = false;
      fields['latitude']!.text = p.latitude.toStringAsFixed(6);
      fields['longitude']!.text = p.longitude.toStringAsFixed(6);
      status = '位置已选择，点击“应用定位”后开始使用';
    });
    if (pan && mapReady) mapController.move(Coordinates.display(p, amap), 15);
  }

  void edited(String key) {
    setState(() {
      dirty = true;
      applySuccess = false;
      applyError = null;
      showAppliedNotice = false;
      destination = '手动输入的位置';
    });
    if (key == 'latitude' || key == 'longitude') {
      final lat = double.tryParse(fields['latitude']!.text),
          lon = double.tryParse(fields['longitude']!.text);
      if (lat != null &&
          lon != null &&
          lat.isFinite &&
          lon.isFinite &&
          lat.abs() <= 90 &&
          lon.abs() <= 180) {
        setState(() => draft = LatLng(lat, lon));
      }
    }
  }

  // Ignore caret movement, but wait until Chinese IME composition finishes.
  void searchEdited() {
    final value = search.value;
    if (value.text == lastSearchText &&
        value.composing == lastSearchComposing) {
      return;
    }
    lastSearchText = value.text;
    lastSearchComposing = value.composing;
    stopSearch();
    setState(() {
      results = [];
      searchHint = '搜索地名、完整地址，或输入经纬度';
    });
    if (value.text.trim().length < 2 ||
        (value.composing.isValid && !value.composing.isCollapsed) ||
        !core.ready ||
        searchCollapsed ||
        page != 0) {
      return;
    }
    searchDebounce = Timer(const Duration(milliseconds: 850), () {
      if (mounted) unawaited(findPlaces(suggestions: true));
    });
  }

  void stopSearch() {
    searchDebounce?.cancel();
    final previous = searchGeneration++;
    if (searching && core.ready) {
      unawaited(
        core
            .call('cancelSearch', {'searchId': previous})
            .catchError((_) => null),
      );
    }
    searching = false;
  }

  LatLng? placePoint(JsonMap place) => Coordinates.searchPoint(place);

  String searchResultHint(JsonMap result, List<JsonMap> found) {
    final notice = result['notice']?.toString();
    if (notice != null && notice.isNotEmpty) return notice;
    if (found.isEmpty) return '未找到地点，可补充乡镇、街道，或直接在地图上选点';
    if (result['needsConfirmation'] == true || found.length > 1) {
      return '找到 ${found.length} 个地点，请核对地址后选择';
    }
    return placePoint(found.first) == null
        ? '点击地点继续查找坐标，或按回车搜索完整地址'
        : '找到地点，点击选择';
  }

  Future<void> findPlaces({bool suggestions = false}) async {
    final query = search.text.trim();
    searchDebounce?.cancel();
    if (query.isEmpty || !core.ready) {
      searchFocus.requestFocus();
      return;
    }
    final generation = ++searchGeneration;
    setState(() {
      searching = true;
      searchHint = suggestions ? '正在查找相关地点…' : '正在搜索地点与完整地址…';
      results = [];
      page = 0;
      searchCollapsed = false;
    });
    try {
      final result = CoreClient.map(
        await core.call('search.places', {
          'query': query,
          'suggestions': suggestions,
          'searchId': generation,
        }),
      );
      if (!mounted || generation != searchGeneration) return;
      final found = CoreClient.list(result['places']);
      setState(() {
        results = found;
        searchHint = searchResultHint(result, found);
      });
      if (!suggestions) await core.refresh();
    } catch (e) {
      if (mounted && generation == searchGeneration) {
        setState(() {
          searchHint = e.toString();
          results = [];
        });
      }
    } finally {
      if (mounted && generation == searchGeneration) {
        setState(() => searching = false);
      }
    }
  }

  void cancelSearch() {
    stopSearch();
    setState(() {
      searching = false;
      searchHint = '搜索已取消';
    });
  }

  Future<void> selectPlace(JsonMap place) async {
    final point = placePoint(place);
    if (point != null) {
      pick(point, place['name']?.toString() ?? '选择的位置');
      return;
    }
    if (!core.ready) return;
    searchDebounce?.cancel();
    final generation = ++searchGeneration;
    setState(() {
      searching = true;
      searchHint = '正在按地区和完整地址查找“${place['name']}”的坐标…';
    });
    try {
      final result = CoreClient.map(
        await core.call('search.resolve', {
          'place': place,
          'searchId': generation,
        }),
      );
      if (!mounted || generation != searchGeneration) return;
      final found = CoreClient.list(result['places']);
      if (found.length == 1 && result['needsConfirmation'] != true) {
        final resolved = placePoint(found.first);
        if (resolved != null) {
          pick(resolved, found.first['name']?.toString() ?? '选择的位置');
          return;
        }
      }
      setState(() {
        results = found;
        searchHint = searchResultHint(result, found);
      });
    } catch (e) {
      if (mounted && generation == searchGeneration) {
        setState(() => searchHint = '$e 可重试或直接在地图上选点。');
      }
    } finally {
      if (mounted && generation == searchGeneration) {
        setState(() => searching = false);
      }
    }
  }

  Future<void> apply() async {
    if (!core.ready || applying) return;
    successTimer?.cancel();
    noticeTimer?.cancel();
    final submitted = {for (final e in fields.entries) e.key: e.value.text};
    final submittedJitter = (jitterPosition, jitterAccuracy);
    final submittedName = destination;
    setState(() {
      applying = true;
      applySuccess = false;
      applyError = null;
      showAppliedNotice = false;
    });
    try {
      final args = <String, dynamic>{};
      for (final entry in fields.entries) {
        final value = double.tryParse(submitted[entry.key]!.trim());
        if (value == null || !value.isFinite) {
          throw CoreError('请输入有效的${labels[entry.key]}');
        }
        args[entry.key] = value;
      }
      args['jitterPosition'] = submittedJitter.$1;
      args['jitterAccuracy'] = submittedJitter.$2;
      await core.call('apply', args);
      // Refresh failure must not turn a completed apply into a false failure.
      try {
        await core.refresh();
      } catch (_) {}
      if (mounted) {
        setState(() {
          dirty =
              fields.entries.any((e) => e.value.text != submitted[e.key]) ||
              (jitterPosition, jitterAccuracy) != submittedJitter;
          lastAppliedAt = DateTime.now();
          appliedName = submittedName;
          noticePoint = LatLng(
            args['latitude'] as double,
            args['longitude'] as double,
          );
          applySuccess = !dirty;
          showAppliedNotice = true;
          if (!dirty) applyAnimation++;
          status = '目标已更新，手机是否采用请查看手机地图';
        });
        successTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => applySuccess = false);
        });
        noticeTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => showAppliedNotice = false);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          applyError = e.toString();
          status = '目标更新失败，请检查参数后重试';
        });
      }
    } finally {
      if (mounted) setState(() => applying = false);
    }
  }

  Future<void> connect() async {
    if (selectedMac == null || connecting || selectedDeviceActive) return;
    final d = core.devices
        .where((d) => d['address'] == selectedMac)
        .firstOrNull;
    if (d == null) return;
    if (dirty) {
      await apply();
      if (dirty) return;
    }
    setState(() {
      connecting = true;
      status = '正在连接 ${d['name']}，最长等待 20 秒…';
    });
    await perform(() async {
      if (usbActive) await core.call('usb.stop');
      await core.call('connect', {'mac': selectedMac, 'name': d['name']});
      await core.refresh();
      if (mounted) setState(() => status = '蓝牙已连接，正在等待设备识别与认证');
    });
    if (mounted) setState(() => connecting = false);
  }

  Future<void> refreshDevices() async {
    setState(() => refreshing = true);
    await perform(() async {
      await core.refreshDevices();
      if (!core.devices.any((d) => d['address'] == selectedMac)) {
        selectedMac =
            core.devices
                    .where((d) => d['likelyApple'] == true)
                    .firstOrNull?['address']
                as String?;
      }
    });
    if (mounted) setState(() => refreshing = false);
  }

  Future<void> refreshUsbDevices() async {
    if (usbRefreshing) return;
    setState(() => usbRefreshing = true);
    await perform(() async {
      await core.refreshUsbDevices();
      if (!core.usbDevices.any((d) => d['udid'] == selectedUsb)) {
        selectedUsb = core.usbDevices.firstOrNull?['udid'] as String?;
      }
    });
    if (mounted) setState(() => usbRefreshing = false);
  }

  Future<void> connectUsb() async {
    if (selectedUsb == null || usbBusy || usbActive) return;
    if (dirty) {
      await apply();
      if (dirty || !mounted) return;
    }
    setState(() => usbBusy = true);
    await perform(() async {
      // Avoid two location sources competing for the same phone.
      if (core.sessions.any(sessionActive)) {
        await core.call('stopAll');
      }
      await core.call('usb.connect', {'udid': selectedUsb});
      await core.refresh();
      if (mounted) setState(() => status = '正在准备 USB 开发者定位');
    });
    if (mounted) setState(() => usbBusy = false);
  }

  Future<void> stopUsb() async {
    if (usbBusy) return;
    setState(() => usbBusy = true);
    await perform(() async {
      await core.call('usb.stop');
      await core.refresh();
      if (mounted) setState(() => status = 'USB 连接已结束');
    });
    if (mounted) setState(() => usbBusy = false);
  }

  Future<void> revealDeveloperMode() async {
    if (selectedUsb == null || usbBusy || usbActive || usbRefreshing) return;
    setState(() {
      usbBusy = true;
      usbRevealing = true;
      developerModeError = false;
      developerModeHint = '正在请求显示入口，请保持手机解锁；出现信任提示时选择“信任”。';
    });
    try {
      final result = CoreClient.map(
        await core.call('usb.revealDeveloperMode', {'udid': selectedUsb}),
      );
      if (mounted) {
        setState(() => developerModeHint = result['message']?.toString());
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          developerModeHint = error.toString();
          developerModeError = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          usbBusy = false;
          usbRevealing = false;
        });
      }
    }
  }

  Future<void> favorite() async {
    final name = TextEditingController(text: destination);
    final save = await showMacSheet<bool>(
      context,
      title: '收藏位置',
      width: 390,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(coordinates(draft), style: textStyle(12, muted)),
            const SizedBox(height: 14),
            MacField(controller: name, label: '位置名称'),
            const SizedBox(height: 20),
            Builder(
              builder: (sheet) => Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MacButton('取消', onPressed: () => Navigator.pop(sheet)),
                  const SizedBox(width: 8),
                  MacButton(
                    '保存收藏',
                    primary: true,
                    onPressed: () {
                      if (name.text.trim().isNotEmpty) {
                        Navigator.pop(sheet, true);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      await perform(() async {
        final altitude = double.tryParse(fields['altitude']!.text),
            accuracy = double.tryParse(fields['accuracy']!.text);
        if (altitude == null ||
            accuracy == null ||
            !altitude.isFinite ||
            !accuracy.isFinite ||
            accuracy < .1) {
          throw const CoreError('请检查高度和精度');
        }
        await core.call('favorites.add', {
          'name': name.text.trim(),
          'latitude': draft.latitude,
          'longitude': draft.longitude,
          'altitude': altitude,
          'accuracy': accuracy,
        });
        await core.refresh();
        if (mounted) setState(() => status = '已保存到收藏位置');
      });
    }
    name.dispose();
  }

  void pickFavorite(JsonMap f) {
    fields['altitude']!.text = format(f['altitude'] ?? 10, 'altitude');
    fields['accuracy']!.text = format(f['accuracy'] ?? 5, 'accuracy');
    pick(
      LatLng(number(f['latitude']), number(f['longitude'])),
      f['name'].toString(),
    );
  }

  Future<void> removeFavorite(JsonMap f) async {
    final remove = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('移除收藏位置？'),
        content: Text(f['name'].toString()),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (remove == true) {
      await perform(() async {
        await core.call('favorites.remove', {'id': f['id']});
        await core.refresh();
      });
    }
  }

  void recenter() {
    if (mapReady) mapController.move(Coordinates.display(draft, amap), 15);
  }

  Future<void> settings() async {
    if (!core.ready) return;
    stopSearch();
    setState(() {
      results = [];
      searchHint = '设置返回后可重新搜索';
    });
    await showMacSheet<void>(
      context,
      title: '设置',
      child: SettingsSheet(core: core),
    );
    if (!mounted) return;
    final next = core.settings['datum'] != 'wgs',
        moved = amap != (core.settings['datum'] != 'wgs');
    setState(() => amap = next);
    if (moved) recenter();
  }

  Future<void> close() async {
    if (closing) return;
    closing = true;
    stopSearch();
    await core.close();
    await windowManager.destroy();
  }

  @override
  void onWindowClose() => unawaited(close());
  @override
  void dispose() {
    windowManager.removeListener(this);
    core.removeListener(changed);
    search.removeListener(searchEdited);
    searchDebounce?.cancel();
    searchGeneration++;
    for (final c in fields.values) {
      c.dispose();
    }
    search.dispose();
    searchFocus.dispose();
    inspectorScroll.dispose();
    successTimer?.cancel();
    noticeTimer?.cancel();
    mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
        setState(() {
          page = 0;
          searchCollapsed = false;
        });
        searchFocus.requestFocus();
      },
      const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
          unawaited(apply()),
      const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
          unawaited(settings()),
      const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
          unawaited(close()),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0x26000000)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      sidebar(),
                      Expanded(
                        child: Column(
                          children: [
                            toolbar(),
                            Expanded(
                              child: Row(
                                children: [
                                  Expanded(child: mapArea()),
                                  if (inspector) inspectorPane(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                statusBar(),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget sidebar() => Container(
    width: 208,
    decoration: const BoxDecoration(
      color: Color(0xFFF0F1F5),
      border: Border(right: BorderSide(color: line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DragToMoveArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 19, 16, 18),
            child: Row(
              children: [
                TrafficLight(
                  color: const Color(0xFFFF5F57),
                  icon: CupertinoIcons.xmark,
                  label: '关闭窗口',
                  action: () => unawaited(close()),
                ),
                const SizedBox(width: 8),
                TrafficLight(
                  color: const Color(0xFFFEBC2E),
                  icon: CupertinoIcons.minus,
                  label: '最小化',
                  action: () => windowManager.minimize(),
                ),
                const SizedBox(width: 8),
                TrafficLight(
                  color: const Color(0xFF28C840),
                  icon: CupertinoIcons.arrow_up_left_arrow_down_right,
                  label: '最大化或还原',
                  action: () async {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  },
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 17, 12, 22),
          child: Row(
            children: [
              Container(
                width: 35,
                height: 35,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF57B0FF), blue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x30007AFF),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(
                  CupertinoIcons.location_fill,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('随行定位', style: textStyle(16, ink, FontWeight.w700)),
                  Text('位置，随心而行', style: textStyle(10, muted)),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text('工作空间', style: textStyle(10, muted, FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        nav(0, CupertinoIcons.map, '地图选点'),
        nav(1, CupertinoIcons.star, '收藏位置', core.favorites.length),
        nav(
          2,
          CupertinoIcons.device_phone_portrait,
          '我的设备',
          core.sessions.where((s) => s['running'] == true).length,
        ),
        const SizedBox(height: 26),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text('快速前往', style: textStyle(10, muted, FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: core.favorites.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text('收藏常用地点\n下次一键找到', style: textStyle(11, muted)),
                )
              : ListView(
                  children: core.favorites
                      .take(8)
                      .map(
                        (f) => CupertinoButton(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          minimumSize: Size.zero,
                          onPressed: () {
                            setState(() => page = 0);
                            pickFavorite(f);
                          },
                          child: Row(
                            children: [
                              const Icon(
                                CupertinoIcons.location,
                                size: 13,
                                color: muted,
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  f['name'].toString(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textStyle(11, const Color(0xFF61636B)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .65),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  CupertinoIcons.lock_shield,
                  color: core.identity['valid'] == true
                      ? const Color(0xFF34A366)
                      : muted,
                  size: 17,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        core.identity['valid'] == true ? '身份材料已就绪' : '等待身份材料',
                        style: textStyle(11, ink, FontWeight.w500),
                      ),
                      Text('本地连接 · 本地保存', style: textStyle(9, muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: line),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ToolButton(
                CupertinoIcons.settings,
                '设置  Ctrl+,',
                core.ready ? settings : null,
              ),
              ToolButton(CupertinoIcons.question_circle, '使用说明', help),
              ToolButton(
                CupertinoIcons.info_circle,
                '关于随行定位',
                () => showDesktopAbout(context, core),
              ),
              const Spacer(),
              Text('1.1.3 · Flutter', style: textStyle(9, muted)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget nav(int index, IconData icon, String label, [int count = 0]) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          minimumSize: Size.zero,
          color: page == index ? const Color(0xFFDDE8F8) : null,
          borderRadius: BorderRadius.circular(8),
          onPressed: () {
            stopSearch();
            setState(() {
              page = index;
              expandPanel();
              searchHint = results.isEmpty
                  ? '搜索地名、完整地址，或直接在地图上选点'
                  : '请核对地址后选择地点';
            });
          },
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: page == index ? blue : const Color(0xFF6B7280),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: textStyle(
                    12,
                    page == index ? const Color(0xFF0867CB) : ink,
                    page == index ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (count > 0) Text('$count', style: textStyle(11, muted)),
            ],
          ),
        ),
      );

  Widget toolbar() => Container(
    height: 60,
    decoration: const BoxDecoration(
      color: Color(0xFFF9F9FB),
      border: Border(bottom: BorderSide(color: line)),
    ),
    child: Row(
      children: [
        Expanded(
          child: DragToMoveArea(
            child: Padding(
              padding: const EdgeInsets.only(left: 22),
              child: Row(
                children: [
                  Text(
                    ['地图选点', '收藏位置', '我的设备'][page],
                    style: textStyle(15, ink, FontWeight.w600),
                  ),
                  const SizedBox(width: 12),
                  Text('选择你想去的地方', style: textStyle(11, muted)),
                ],
              ),
            ),
          ),
        ),
        if (core.ready)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: StatusPill(
              core.sessions.any(
                    (s) =>
                        s['running'] == true &&
                        s['error'] == null &&
                        s['authenticated'] == true,
                  )
                  ? '蓝牙设备已认证'
                  : core.usb['phase'] == 'simulating'
                  ? 'USB 定位已连接'
                  : core.usb['phase'] == 'connecting'
                  ? 'USB 正在连接'
                  : '尚未连接设备',
              active:
                  core.usb['phase'] == 'simulating' ||
                  core.sessions.any(
                    (s) =>
                        s['running'] == true &&
                        s['error'] == null &&
                        s['authenticated'] == true,
                  ),
            ),
          ),
        ToolButton(CupertinoIcons.scope, '回到目标位置', mapReady ? recenter : null),
        ToolButton(
          CupertinoIcons.sidebar_right,
          inspector ? '隐藏位置详情' : '显示位置详情',
          () => setState(() => inspector = !inspector),
          selected: inspector,
        ),
        const SizedBox(width: 12),
      ],
    ),
  );

  Widget mapArea() => Stack(
    children: [
      Positioned.fill(
        child: FlutterMap(
          mapController: mapController,
          options: MapOptions(
            initialCenter: Coordinates.display(draft, amap),
            initialZoom: 13,
            minZoom: 3,
            maxZoom: amap ? 18 : 19,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () {
              mapReady = true;
              if (!loading) recenter();
            },
            onTap: (_, p) {
              if (core.ready) {
                pick(Coordinates.picked(p, amap), '地图选点', pan: false);
              }
            },
          ),
          children: [
            TileLayer(
              key: ValueKey(amap),
              urlTemplate: amap
                  ? 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}'
                  : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              subdomains: amap ? const ['1', '2', '3', '4'] : const [],
              userAgentPackageName: 'io.suixing.location',
              maxZoom: amap ? 18 : 19,
              errorTileCallback: (_, _, _) {
                final now = DateTime.now();
                if (lastTileError == null ||
                    now.difference(lastTileError!) >
                        const Duration(seconds: 10)) {
                  lastTileError = now;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() => tileWarning = '部分地图未加载，请检查网络或切换底图');
                    }
                  });
                }
              },
            ),
            CircleLayer(
              circles: [
                CircleMarker(
                  point: Coordinates.display(applied, amap),
                  radius: 10,
                  color: blue.withValues(alpha: .18),
                  borderColor: Colors.white,
                  borderStrokeWidth: 2,
                ),
              ],
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: Coordinates.display(draft, amap),
                  width: 48,
                  height: 60,
                  alignment: const Alignment(0, -.6),
                  child: Tooltip(
                    message: '目标位置 · ${coordinates(draft)}',
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey(applyAnimation),
                      tween: Tween(begin: 0, end: 1),
                      duration: Duration(
                        milliseconds: applyAnimation == 0 ? 0 : 750,
                      ),
                      builder: (_, value, child) => Transform.translate(
                        offset: Offset(
                          0,
                          value < .45
                              ? -10 * (value / .45)
                              : -10 * (1 - value) / .55,
                        ),
                        child: child,
                      ),
                      child: const MapPin(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      Positioned(
        top: 18,
        left: 18,
        width: page == 2 ? (devicesCollapsed ? 276 : 365) : 308,
        child: Glass(
          padding: const EdgeInsets.all(14),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(context).height - 220).clamp(
                200,
                640,
              ),
            ),
            child: SingleChildScrollView(
              primary: false,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 160),
                alignment: Alignment.topCenter,
                child: page == 0
                    ? searchPanel()
                    : page == 1
                    ? favoritesPanel()
                    : devicesPanel(),
              ),
            ),
          ),
        ),
      ),
      if (showAppliedNotice && noticePoint != null)
        Positioned(
          bottom: 103,
          right: 18,
          child: IgnorePointer(
            child: Glass(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: SizedBox(
                width: 222,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '✓ 目标已更新',
                      style: textStyle(
                        13,
                        const Color(0xFF25985C),
                        FontWeight.w600,
                      ),
                    ),
                    Text(
                      appliedName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle(11),
                    ),
                    Text(
                      coordinates(noticePoint!),
                      style: textStyle(10, muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      Positioned(
        right: 18,
        bottom: 52,
        child: Glass(
          radius: 10,
          child: Column(
            children: [
              ToolButton(CupertinoIcons.plus, '放大地图', () {
                if (mapReady) {
                  mapController.move(
                    mapController.camera.center,
                    (mapController.camera.zoom + 1).clamp(3, amap ? 18 : 19),
                  );
                }
              }),
              const SizedBox(width: 22, child: Divider(height: 1, color: line)),
              ToolButton(CupertinoIcons.minus, '缩小地图', () {
                if (mapReady) {
                  mapController.move(
                    mapController.camera.center,
                    (mapController.camera.zoom - 1).clamp(3, 19),
                  );
                }
              }),
            ],
          ),
        ),
      ),
      Positioned(
        bottom: 18,
        left: 18,
        child: Glass(
          radius: 9,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(CupertinoIcons.location, size: 12, color: muted),
              const SizedBox(width: 6),
              Text('点击地图选择位置', style: textStyle(10, const Color(0xFF62636A))),
            ],
          ),
        ),
      ),
      Positioned(
        right: 13,
        bottom: 10,
        child: Text(
          amap ? '© 高德地图' : '© OpenStreetMap 贡献者',
          style: textStyle(9, const Color(0xFF555C66)),
        ),
      ),
      if (tileWarning != null)
        Positioned(
          left: 18,
          right: 70,
          bottom: 65,
          child: Glass(
            radius: 9,
            padding: const EdgeInsets.fromLTRB(12, 5, 6, 5),
            child: Row(
              children: [
                const Icon(
                  CupertinoIcons.exclamationmark_triangle,
                  size: 14,
                  color: muted,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(tileWarning!, style: textStyle(11, muted)),
                ),
                ToolButton(
                  CupertinoIcons.xmark,
                  '关闭提示',
                  () => setState(() => tileWarning = null),
                ),
              ],
            ),
          ),
        ),
      if (loading || core.failure != null)
        Positioned.fill(
          child: ColoredBox(
            color: Colors.white.withValues(alpha: .87),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    const CupertinoActivityIndicator(radius: 14)
                  else
                    const Icon(
                      CupertinoIcons.exclamationmark_circle,
                      color: muted,
                      size: 36,
                    ),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      core.failure ?? '正在准备你的工作空间…',
                      textAlign: TextAlign.center,
                      style: textStyle(13, muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  Widget panelHeading(String title, bool collapsed, VoidCallback toggle) => Row(
    children: [
      Expanded(child: Text(title, style: textStyle(14, ink, FontWeight.w600))),
      ToolButton(
        collapsed ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_up,
        '${collapsed ? '展开' : '收起'}$title',
        toggle,
      ),
    ],
  );

  Widget searchPanel() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      panelHeading('地图选点', searchCollapsed, () {
        stopSearch();
        setState(() {
          searchCollapsed = !searchCollapsed;
          searchHint = results.isEmpty ? '搜索地名、完整地址，或直接在地图上选点' : '请核对地址后选择地点';
        });
      }),
      if (!searchCollapsed) ...[
        const SizedBox(height: 7),
        MacField(
          controller: search,
          focusNode: searchFocus,
          hint: '搜索地点或地址',
          prefix: const Padding(
            padding: EdgeInsets.only(left: 10),
            child: Icon(CupertinoIcons.search, size: 16, color: muted),
          ),
          suffix: ToolButton(
            searching
                ? CupertinoIcons.xmark_circle_fill
                : CupertinoIcons.arrow_right_circle_fill,
            searching ? '取消搜索' : '搜索',
            core.ready
                ? () {
                    if (searching) {
                      cancelSearch();
                    } else {
                      unawaited(findPlaces());
                    }
                  }
                : null,
          ),
          onSubmitted: (_) => findPlaces(),
        ),
        const SizedBox(height: 9),
        Row(
          children: [
            if (searching) ...[
              const CupertinoActivityIndicator(radius: 6),
              const SizedBox(width: 7),
            ],
            Expanded(child: Text(searchHint, style: textStyle(10, muted))),
          ],
        ),
        if (results.isEmpty &&
            !searching &&
            core.settings['searchHistory'] is List &&
            (core.settings['searchHistory'] as List).isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('最近搜索', style: textStyle(10, muted)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: (core.settings['searchHistory'] as List)
                .take(4)
                .map(
                  (q) => CupertinoButton(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    minimumSize: Size.zero,
                    color: const Color(0xFFF0F2F5),
                    borderRadius: BorderRadius.circular(6),
                    onPressed: () {
                      search.text = q.toString();
                      unawaited(findPlaces());
                    },
                    child: Text(
                      q.toString(),
                      style: textStyle(10, const Color(0xFF686B73)),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
        if (results.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Divider(height: 1, color: line),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 330),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: results.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 35, color: line),
              itemBuilder: (_, index) {
                final p = results[index];
                return CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  minimumSize: Size.zero,
                  onPressed: () => unawaited(selectPlace(p)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF2FF),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          CupertinoIcons.location,
                          size: 15,
                          color: blue,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p['name'].toString(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textStyle(12, ink, FontWeight.w600),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              p['address']?.toString() ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textStyle(10, muted),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              [
                                p['category']?.toString() ?? '',
                                p['source']?.toString() ?? '',
                                if (placePoint(p) == null) '点击查找坐标',
                              ].where((s) => s.isNotEmpty).join(' · '),
                              style: textStyle(9, muted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ],
    ],
  );

  Widget favoritesPanel() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      panelHeading(
        '收藏位置',
        favoritesCollapsed,
        () => setState(() => favoritesCollapsed = !favoritesCollapsed),
      ),
      if (!favoritesCollapsed) ...[
        const SizedBox(height: 5),
        Text('熟悉的地方，随时前往', style: textStyle(11, muted)),
        const SizedBox(height: 14),
        if (core.favorites.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 25),
            child: Center(
              child: Column(
                children: [
                  const Icon(
                    CupertinoIcons.star,
                    size: 30,
                    color: Color(0xFFB8C3D0),
                  ),
                  const SizedBox(height: 10),
                  Text('还没有收藏位置', style: textStyle(12, muted)),
                  const SizedBox(height: 12),
                  MacButton(
                    '收藏当前坐标',
                    icon: CupertinoIcons.plus,
                    onPressed: core.ready ? favorite : null,
                  ),
                ],
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 390),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: core.favorites.length,
              itemBuilder: (_, i) {
                final f = core.favorites[i];
                return Row(
                  children: [
                    Expanded(
                      child: CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        minimumSize: Size.zero,
                        onPressed: () => pickFavorite(f),
                        child: Row(
                          children: [
                            const Icon(
                              CupertinoIcons.star_fill,
                              size: 16,
                              color: Color(0xFFEAA82A),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    f['name'].toString(),
                                    style: textStyle(12, ink, FontWeight.w500),
                                  ),
                                  Text(
                                    '${number(f['latitude']).toStringAsFixed(5)}, ${number(f['longitude']).toStringAsFixed(5)}',
                                    style: textStyle(10, muted),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ToolButton(
                      CupertinoIcons.trash,
                      '删除收藏',
                      () => removeFavorite(f),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    ],
  );

  Widget devicesPanel() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              devicesCollapsed ? '我的设备 · 已连接 $connectedDevices 台' : '我的设备',
              style: textStyle(14, ink, FontWeight.w600),
            ),
          ),
          if (!devicesCollapsed)
            ToolButton(
              CupertinoIcons.refresh,
              '刷新设备',
              !core.ready || (deviceMode == 0 ? refreshing : usbRefreshing)
                  ? null
                  : deviceMode == 0
                  ? refreshDevices
                  : refreshUsbDevices,
            ),
          ToolButton(
            devicesCollapsed
                ? CupertinoIcons.chevron_down
                : CupertinoIcons.chevron_up,
            devicesCollapsed ? '展开我的设备' : '收起我的设备',
            () => setState(() => devicesCollapsed = !devicesCollapsed),
          ),
        ],
      ),
      if (!devicesCollapsed) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: CupertinoSlidingSegmentedControl<int>(
            groupValue: deviceMode,
            children: {
              0: Text('蓝牙', style: textStyle(11)),
              1: Text('USB 开发者', style: textStyle(11)),
            },
            onValueChanged: (value) {
              if (value != null) setState(() => deviceMode = value);
            },
          ),
        ),
        const SizedBox(height: 12),
        if (deviceMode == 1)
          usbDevicesBody()
        else ...[
          Text('先在 Windows 蓝牙设置中完成配对', style: textStyle(11, muted)),
          if (usbActive) Text('连接蓝牙前会先停止 USB 模拟', style: textStyle(10, muted)),
          const SizedBox(height: 12),
          if (refreshing)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: CupertinoActivityIndicator(),
              ),
            )
          else if (core.devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(
                core.deviceFailure ?? '暂无已配对设备，请先完成配对后刷新。',
                style: textStyle(12, muted),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 210),
              child: ListView(
                shrinkWrap: true,
                children: core.devices
                    .map(
                      (d) => CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        minimumSize: Size.zero,
                        onPressed: () => setState(
                          () => selectedMac = d['address'] as String,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              CupertinoIcons.device_phone_portrait,
                              size: 23,
                              color: selectedMac == d['address'] ? blue : muted,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    d['name'].toString(),
                                    style: textStyle(12, ink, FontWeight.w500),
                                  ),
                                  Text(
                                    d['address'].toString(),
                                    style: textStyle(10, muted),
                                  ),
                                ],
                              ),
                            ),
                            if (selectedMac == d['address'])
                              const Icon(
                                CupertinoIcons.checkmark_circle_fill,
                                size: 17,
                                color: blue,
                              ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: MacButton(
                  connecting || selectedDeviceStarting
                      ? '正在连接…'
                      : selectedDeviceActive
                      ? '设备已连接'
                      : '连接设备',
                  primary: true,
                  busy: connecting || selectedDeviceStarting,
                  onPressed:
                      selectedMac != null &&
                          core.ready &&
                          !connecting &&
                          !selectedDeviceActive
                      ? connect
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              MacButton(
                '蓝牙设置',
                onPressed: core.ready
                    ? () => perform(() async {
                        await core.call('openBluetooth');
                      })
                    : null,
              ),
            ],
          ),
          if (core.sessions.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(height: 1, color: line),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '连接记录',
                    style: textStyle(11, muted, FontWeight.w600),
                  ),
                ),
                if (core.sessions.any((session) => session['error'] != null))
                  MacButton(
                    '清除失败记录',
                    compact: true,
                    onPressed: removingSessions.isNotEmpty || !core.ready
                        ? null
                        : () => removeSessions(
                            core.sessions
                                .where((session) => session['error'] != null)
                                .toList(),
                          ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView(
                shrinkWrap: true,
                children: core.sessions
                    .map(
                      (s) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s['label'].toString(),
                                    style: textStyle(12, ink, FontWeight.w600),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    s['error']?.toString() ??
                                        '${s['status']} · 已发送 ${s['sent']} 条',
                                    style: textStyle(
                                      10,
                                      s['error'] == null
                                          ? muted
                                          : const Color(0xFFCC5146),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (sessionRemovable(s))
                              ToolButton(
                                CupertinoIcons.xmark,
                                '移除失败或已停止的连接记录',
                                core.ready &&
                                        !removingSessions.contains(s['id'])
                                    ? () => removeSessions([s])
                                    : null,
                              )
                            else
                              MacButton(
                                s['starting'] == true ? '取消' : '断开',
                                compact: true,
                                busy: removingSessions.contains(s['id']),
                                onPressed:
                                    core.ready &&
                                        !removingSessions.contains(s['id'])
                                    ? () => removeSessions([s])
                                    : null,
                              ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: MacButton(
                '停止全部设备',
                destructive: true,
                compact: true,
                onPressed: () => perform(() async {
                  await core.call('stopAll');
                  await core.refresh();
                }),
              ),
            ),
          ],
        ],
      ],
    ],
  );

  Widget usbDevicesBody() {
    final usb = core.usb;
    final phase = usb['phase'];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('数据线连接，解锁并信任此电脑。iOS 16 及以后需开启开发者模式。', style: textStyle(11, muted)),
        const SizedBox(height: 8),
        Text('按系统自动适配 · iOS 17.0–17.3 还需同一局域网', style: textStyle(10, muted)),
        const SizedBox(height: 8),
        if (usbRefreshing)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CupertinoActivityIndicator()),
          )
        else if (core.usbDevices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
              core.usbDeviceFailure ?? '插入设备后，点击右上角刷新。',
              style: textStyle(12, muted),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView(
              shrinkWrap: true,
              children: core.usbDevices
                  .map(
                    (d) => CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      minimumSize: Size.zero,
                      onPressed: usbActive || usbBusy
                          ? null
                          : () => setState(() {
                              selectedUsb = d['udid'] as String;
                              developerModeHint = null;
                            }),
                      child: Row(
                        children: [
                          Icon(
                            CupertinoIcons.device_phone_portrait,
                            size: 23,
                            color: selectedUsb == d['udid'] ? blue : muted,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${d['name']}${d['ios'] == '' ? '' : ' · iOS ${d['ios']}'}',
                                  style: textStyle(12, ink, FontWeight.w500),
                                ),
                                Text(
                                  d['detail'].toString(),
                                  style: textStyle(10, muted),
                                ),
                              ],
                            ),
                          ),
                          if (selectedUsb == d['udid'])
                            const Icon(
                              CupertinoIcons.checkmark_circle_fill,
                              size: 17,
                              color: blue,
                            ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        const SizedBox(height: 10),
        MacButton(
          phase == 'connecting'
              ? '正在连接…'
              : phase == 'stopping'
              ? '正在停止…'
              : phase == 'simulating'
              ? 'USB 定位已连接'
              : '连接并使用当前目标',
          primary: true,
          busy:
              (usbBusy && !usbRevealing) ||
              phase == 'connecting' ||
              phase == 'stopping',
          onPressed: core.ready && selectedUsb != null && !usbActive && !usbBusy
              ? connectUsb
              : null,
        ),
        const SizedBox(height: 8),
        MacButton(
          usbRevealing ? '正在显示入口…' : '显示开发者模式入口',
          compact: true,
          busy: usbRevealing,
          onPressed:
              core.ready &&
                  selectedUsb != null &&
                  !usbActive &&
                  !usbBusy &&
                  !usbRefreshing
              ? revealDeveloperMode
              : null,
        ),
        if (developerModeHint != null)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Text(
              developerModeHint!,
              style: textStyle(
                11,
                developerModeError ? const Color(0xFFCC5146) : muted,
              ),
            ),
          ),
        if (core.sessions.any(sessionActive))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '连接 USB 会先停止蓝牙会话，避免定位源冲突。',
              style: textStyle(10, muted),
            ),
          ),
        if (usbActive ||
            usb['error'] != null ||
            usb['clearRequested'] == true ||
            usb['restoreWarning'] != null) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1, color: line),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${usb['label'] ?? 'Apple 设备'}${usb['ios'] == null || usb['ios'] == '' ? '' : ' · iOS ${usb['ios']}'}',
                      style: textStyle(12, ink, FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      usb['error']?.toString() ??
                          usb['status']?.toString() ??
                          '',
                      style: textStyle(
                        11,
                        usb['error'] == null ? muted : const Color(0xFFCC5146),
                      ),
                    ),
                    if (usb['transport'] != null)
                      Text(
                        usb['transport'].toString(),
                        style: textStyle(10, muted),
                      ),
                    if (phase == 'simulating')
                      Text(
                        '已提交 ${usb['updates'] ?? 0} 次 · 手机结果待确认',
                        style: textStyle(10, muted),
                      ),
                  ],
                ),
              ),
              if (!usbActive)
                ToolButton(
                  CupertinoIcons.xmark,
                  '移除连接记录',
                  !core.ready || usbBusy
                      ? null
                      : () => perform(() async {
                          await core.call('usb.clearError');
                          await core.refresh();
                        }),
                ),
            ],
          ),
          if (usb['restoreWarning'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                usb['restoreWarning'].toString(),
                style: textStyle(11, const Color(0xFFCC5146)),
              ),
            ),
          if (usbActive) ...[
            const SizedBox(height: 10),
            MacButton(
              phase == 'connecting' ? '取消连接' : '停止模拟',
              destructive: true,
              busy: usbBusy,
              onPressed: core.ready && !usbBusy && phase != 'stopping'
                  ? stopUsb
                  : null,
            ),
          ],
        ],
        const SizedBox(height: 10),
        Text(
          'USB 模式发送经纬度（含固定随机偏移）；高度、速度、精度等参数用于蓝牙模式。',
          style: textStyle(10, muted),
        ),
      ],
    );
  }

  Widget inspectorPane() => Container(
    width: 282,
    decoration: const BoxDecoration(
      color: Color(0xFFFAFAFC),
      border: Border(left: BorderSide(color: line)),
    ),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('位置详情', style: textStyle(13, ink, FontWeight.w600)),
              ),
              StatusPill(dirty ? '待应用' : '已应用', active: !dirty),
              const SizedBox(width: 4),
              ToolButton(
                CupertinoIcons.xmark,
                '收起位置详情',
                () => setState(() => inspector = false),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<int>(
              groupValue: inspectorTab,
              children: {
                0: Text('坐标', style: textStyle(11)),
                1: Text('参数', style: textStyle(11)),
                2: Text('地图', style: textStyle(11)),
              },
              onValueChanged: (value) {
                if (value == null) return;
                if (inspectorScroll.hasClients) inspectorScroll.jumpTo(0);
                setState(() => inspectorTab = value);
              },
            ),
          ),
        ),
        const Divider(height: 1, color: line),
        Expanded(
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context)
                .copyWith(scrollbars: false),
            child: CupertinoScrollbar(
              controller: inspectorScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: inspectorScroll,
                primary: false,
                padding: const EdgeInsets.fromLTRB(16, 12, 20, 14),
                child: switch (inspectorTab) {
                  1 => parameterDetails(),
                  2 => mapDetails(),
                  _ => coordinateDetails(),
                },
              ),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
          decoration: const BoxDecoration(
            color: Color(0xFFF9F9FB),
            border: Border(top: BorderSide(color: line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('当前目标', style: textStyle(9, muted)),
                  const SizedBox(width: 7),
                  Expanded(
                    child: SelectableText(
                      coordinates(applied),
                      maxLines: 1,
                      style: textStyle(10, const Color(0xFF60636D)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              MacButton(
                applying
                    ? '正在更新目标…'
                    : applySuccess
                    ? '目标已更新'
                    : applyError != null
                    ? '重试应用定位'
                    : '应用定位',
                primary: true,
                success: applySuccess,
                icon: applySuccess
                    ? CupertinoIcons.checkmark
                    : CupertinoIcons.location_fill,
                busy: applying,
                onPressed: core.ready && !applying ? apply : null,
              ),
              const SizedBox(height: 5),
              if (applyError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    applyError!,
                    style: textStyle(11, const Color(0xFFD3453E)),
                  ),
                ),
              Text(
                '$updateAge · ${dirty ? '另有待应用的修改' : '目标已保存'}',
                style: textStyle(10, muted),
              ),
              const SizedBox(height: 4),
              Text(deliveryStatus, style: textStyle(11, ink, FontWeight.w500)),
              Text(
                '发送状态表示本机已提交数据，实际位置请在手机确认',
                textAlign: TextAlign.center,
                style: textStyle(9, muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget coordinateDetails() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFFE8F1FF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              CupertinoIcons.location_fill,
              color: blue,
              size: 16,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              destination,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textStyle(13, ink, FontWeight.w600),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text('WGS-84 地理坐标', style: textStyle(10, muted)),
      const SizedBox(height: 10),
      inputPair('latitude', 'longitude'),
      const SizedBox(height: 10),
      inputPair('altitude', 'accuracy'),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: MacButton(
              '收藏位置',
              icon: CupertinoIcons.star,
              compact: true,
              onPressed: core.ready ? favorite : null,
            ),
          ),
          const SizedBox(width: 7),
          ToolButton(CupertinoIcons.doc_on_doc, '复制 WGS-84 坐标', () async {
            await Clipboard.setData(ClipboardData(text: coordinates(draft)));
            if (mounted) setState(() => status = '坐标已复制');
          }),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        '选择位置后点击“应用定位”。发送周期与随机偏移在“参数”中设置，底图在“地图”中切换。',
        style: textStyle(10, muted),
      ),
    ],
  );

  Widget parameterDetails() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      input('rate'),
      const SizedBox(height: 10),
      inputPair('speed', 'bearing'),
      const SizedBox(height: 10),
      inputPair('quality', 'satellites'),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Divider(height: 1, color: line),
      ),
      toggle(
        '位置随机偏移',
        jitterPosition,
        (value) => setState(() {
          jitterPosition = value;
          dirty = true;
          applySuccess = false;
          applyError = null;
        }),
      ),
      if (jitterPosition) ...[input('jitterMeters'), const SizedBox(height: 8)],
      toggle(
        '随机精度',
        jitterAccuracy,
        (value) => setState(() {
          jitterAccuracy = value;
          dirty = true;
          applySuccess = false;
          applyError = null;
        }),
      ),
      if (jitterAccuracy) ...[
        inputPair('accuracyMin', 'accuracyMax'),
        const SizedBox(height: 8),
      ],
      Text('设备指定的订阅周期优先。速度与航向不会自动生成移动路线。', style: textStyle(10, muted)),
    ],
  );

  Widget mapDetails() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionLabel('地图显示'),
      SizedBox(
        width: double.infinity,
        child: CupertinoSlidingSegmentedControl<bool>(
          groupValue: amap,
          children: {
            true: Text('高德地图', style: textStyle(11)),
            false: Text('开放地图', style: textStyle(11)),
          },
          onValueChanged: (value) {
            if (core.ready && value != null) setMap(value);
          },
        ),
      ),
      const SizedBox(height: 10),
      Text(
        '底图坐标自动转换，发送坐标始终为 WGS-84。切换底图不会改变实际目标。',
        style: textStyle(10, muted),
      ),
      const SizedBox(height: 12),
      MacButton(
        '回到目标位置',
        icon: CupertinoIcons.scope,
        compact: true,
        onPressed: mapReady ? recenter : null,
      ),
    ],
  );

  Widget input(String key) => MacField(
    controller: fields[key]!,
    label: labels[key],
    dense: true,
    onChanged: (_) => edited(key),
  );
  Widget inputPair(String first, String second) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: input(first)),
      const SizedBox(width: 8),
      Expanded(child: input(second)),
    ],
  );
  Widget toggle(String label, bool value, ValueChanged<bool> change) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(child: Text(label, style: textStyle(11))),
        SizedBox(
          height: 28,
          width: 38,
          child: Transform.scale(
            scale: .7,
            alignment: Alignment.centerRight,
            child: CupertinoSwitch(value: value, onChanged: change),
          ),
        ),
      ],
    ),
  );
  Future<void> setMap(bool value) async {
    setState(() {
      amap = value;
      tileWarning = null;
    });
    recenter();
    await perform(() async {
      await core.call('settings.save', {'datum': value ? 'gcj' : 'wgs'});
      await core.refresh();
    });
  }

  Widget statusBar() => Container(
    height: 28,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: const BoxDecoration(
      color: Color(0xFFF4F4F7),
      border: Border(top: BorderSide(color: line)),
    ),
    child: Row(
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: core.failure != null
                ? const Color(0xFFE15D50)
                : const Color(0xFF70A78A),
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            core.failure ?? '$deliveryStatus · $status',
            overflow: TextOverflow.ellipsis,
            style: textStyle(10, muted),
          ),
        ),
        const SizedBox(width: 10),
        Text('WGS-84', style: textStyle(9, muted)),
        const SizedBox(width: 14),
        Text('中文桌面版', style: textStyle(9, muted)),
      ],
    ),
  );

  void help() => unawaited(
    showMacSheet<void>(
      context,
      title: '使用说明',
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('让位置，随心而行。', style: textStyle(24, ink, FontWeight.w700)),
            const SizedBox(height: 20),
            ...const [
              (
                '01  配对设备',
                '先在 Windows 蓝牙设置中与 iPhone 配对，保持手机唤醒。在“我的设备”中刷新并选择设备。',
              ),
              (
                '02  选择位置',
                '输入地点或地址后按回车搜索，也可以直接点击地图。搜索结果、收藏和手动输入会形成待应用位置，点击“应用定位”后才生效。',
              ),
              (
                '03  连接与认证',
                '连接后依次进行协议握手、配件识别和认证，设备订阅后开始发送。发送条数不代表 iOS 已采用该位置，请以手机地图为准。',
              ),
              (
                'USB 开发者定位',
                '在“我的设备”切换 USB 开发者，插入数据线、解锁并信任此电脑后刷新。iOS 16 及以后需开发者模式；17.0–17.3 还需手机与电脑同一局域网。连接后改点并应用，使用“停止模拟”结束。各系统版本的实际效果待手机验证。',
              ),
              (
                '搜索与坐标',
                '默认使用免 Key 的 Photon 搜索，覆盖随地区变化；国内地址可在设置中使用高德 Web 服务 Key。输入坐标默认“纬度,经度”，高德坐标可加 gcj: 前缀。',
              ),
              (
                '本地数据与身份',
                '收藏、搜索历史与参数保存在当前用户的应用数据目录。导入身份和高德 Key 按当前 Windows 用户加密保存。内置实验身份来自 DiPlay v0.2.22 公开 APK，证书匹配不代表设备认证一定通过。',
              ),
              (
                '快捷操作',
                'Ctrl+F 搜索 · Ctrl+Enter 应用定位 · Ctrl+, 设置 · Ctrl+W 关闭。关闭应用会结束蓝牙会话，并请求停止 USB 模拟。',
              ),
              (
                '网络与开源',
                '地图和搜索需要联网，搜索词会发送给所选服务。应用基于 D1ngtalk/iap2loc，遵循 GPL-3.0。Flutter 地图由 flutter_map 绘制。详细来源及许可证见发布文件。',
              ),
            ].expand(
              (i) => [
                Text(i.$1, style: textStyle(13, ink, FontWeight.w600)),
                const SizedBox(height: 7),
                Text(i.$2, style: textStyle(12, const Color(0xFF6B6D76))),
                const SizedBox(height: 20),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class TrafficLight extends StatefulWidget {
  const TrafficLight({
    super.key,
    required this.color,
    required this.icon,
    required this.label,
    required this.action,
  });
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback action;
  @override
  State<TrafficLight> createState() => _TrafficLightState();
}

class _TrafficLightState extends State<TrafficLight> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.label,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.action,
        child: Semantics(
          button: true,
          label: widget.label,
          child: Container(
            width: 13,
            height: 13,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.black.withValues(alpha: .09),
                width: .6,
              ),
            ),
            child: hover
                ? Icon(widget.icon, size: 8, color: const Color(0xA0000000))
                : null,
          ),
        ),
      ),
    ),
  );
}

class MapPin extends StatelessWidget {
  const MapPin({super.key});
  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.topCenter,
    children: [
      Positioned(
        bottom: 3,
        child: Container(
          width: 15,
          height: 4,
          decoration: const BoxDecoration(
            color: Color(0x24000000),
            borderRadius: BorderRadius.all(Radius.elliptical(15, 4)),
          ),
        ),
      ),
      Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: blue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(
              color: Color(0x480050AA),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: const Icon(
          CupertinoIcons.location_fill,
          size: 18,
          color: Colors.white,
        ),
      ),
      const Positioned(
        top: 33,
        child: Icon(
          CupertinoIcons.arrowtriangle_down_fill,
          size: 15,
          color: blue,
        ),
      ),
    ],
  );
}
