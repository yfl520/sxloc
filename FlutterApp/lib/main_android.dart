import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_localizations/flutter_localizations.dart' as sdk;

import 'android_map_picker.dart';
import 'android_search_settings.dart';
import 'about_page.dart';
import 'app_info.dart';
import 'service_agreement.dart';
import 'platform_updates.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BluetoothTestApp());
}

class BluetoothTestApp extends StatelessWidget {
  const BluetoothTestApp({super.key, this.agreementStore});
  final AgreementStore? agreementStore;

  @override
  Widget build(BuildContext context) => CupertinoApp(
    debugShowCheckedModeBanner: false,
    title: '随行定位',
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: const [
      ...GlobalCupertinoLocalizations.delegates,
      // Required by the SDK input fields used in the Android settings page.
      // ignore: deprecated_member_use
      sdk.GlobalCupertinoLocalizations.delegate,
    ],
    theme: const CupertinoThemeData(
      brightness: Brightness.light,
      primaryColor: Color(0xFF007AFF),
      scaffoldBackgroundColor: Color(0xFFF2F3F7),
      textTheme: CupertinoTextThemeData(
        textStyle: TextStyle(
          fontFamily: 'sans-serif',
          color: Color(0xFF1D1D1F),
          fontSize: 15,
          height: 1.4,
        ),
      ),
    ),
    home: AgreementGate(
      store: agreementStore,
      onDecline: () => SystemNavigator.pop(),
      builder: (_) => const BluetoothTestPage(),
    ),
  );
}

class BluetoothTestPage extends StatefulWidget {
  const BluetoothTestPage({super.key});

  @override
  State<BluetoothTestPage> createState() => _BluetoothTestPageState();
}

class _BluetoothTestPageState extends State<BluetoothTestPage>
    with WidgetsBindingObserver {
  static const _control = MethodChannel('suixing/android/control');
  static const _events = EventChannel('suixing/android/events');
  final _local = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final _altitude = TextEditingController(text: '0');
  final _tabs = CupertinoTabController();
  final _collapsed = <String>{};
  StreamSubscription<dynamic>? _subscription;
  Map<String, dynamic> _state = {};
  List<Map<String, dynamic>> _devices = [];
  String? _selected;
  String? _error;
  String _android = '';
  String? _notice;
  bool _busy = false;
  bool _reading = false;
  bool _readOnce = false;
  String? _pickedNotice;
  String? _settingsNotice;
  bool get _active => _state['active'] == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = _events.receiveBroadcastStream().listen((dynamic event) {
      if (mounted && event is Map) {
        setState(() => _state = Map<String, dynamic>.from(event));
      }
    }, onError: (Object error) => _showError(error));
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final config = await _control.invokeMapMethod<String, dynamic>(
        'configuration',
      );
      if (!mounted || config == null) return;
      setState(() {
        _local.text = config['local'] as String? ?? '';
        _lat.text = config['lat'] as String? ?? '';
        _lon.text = config['lon'] as String? ?? '';
        _altitude.text = config['altitude'] as String? ?? '0';
        final saved = config['remote'] as String?;
        _selected = saved == null || saved.isEmpty ? null : saved;
        _android = 'Android ${config['android']}';
      });
    } catch (error) {
      _showError(error);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _readOnce && !_reading) {
      unawaited(_refresh());
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() {
      _error = error is PlatformException
          ? error.message ?? '操作失败，请重试'
          : error.toString().replaceFirst('FormatException: ', '');
    });
  }

  Future<void> _refresh() async {
    if (_reading) return;
    setState(() => _reading = true);
    try {
      final data = await _control.invokeMapMethod<String, dynamic>('devices');
      if (!mounted || data == null) return;
      setState(() {
        _readOnce = true;
        _error = null;
        _devices = (data['devices'] as List<dynamic>? ?? [])
            .map((dynamic item) => Map<String, dynamic>.from(item as Map))
            .toList();
        if (_selected != null &&
            !_devices.any((item) => item['address'] == _selected)) {
          _selected = null;
        }
        if (_local.text.isEmpty && data['detectedLocal'] is String) {
          _local.text = data['detectedLocal'] as String;
        }
        _notice = data['enabled'] == true
            ? (_devices.isEmpty ? '没有已配对设备，请先在系统蓝牙设置中配对 iPhone。' : null)
            : '安卓蓝牙尚未开启，请先在系统设置中开启。';
      });
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _perform(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _control.invokeMethod<void>(method, arguments);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    final local = _local.text.trim().toUpperCase();
    if (_selected == null) {
      _showError(const FormatException('请先读取设备并选择 iPhone'));
      return;
    }
    if (!RegExp(r'^[0-9A-F]{2}(:[0-9A-F]{2}){5}$').hasMatch(local) ||
        {
          '02:00:00:00:00:00',
          '00:00:00:00:00:00',
          'FF:FF:FF:FF:FF:FF',
        }.contains(local)) {
      _showError(const FormatException('请填写安卓手机的真实蓝牙地址，如 AA:BB:CC:DD:EE:FF'));
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await _perform('connect', {'remote': _selected, 'local': local});
  }

  Future<void> _apply() async {
    double? number(TextEditingController c) => double.tryParse(c.text.trim());
    final lat = number(_lat);
    final lon = number(_lon);
    final altitude = number(_altitude);
    if (lat == null || !lat.isFinite || lat < -90 || lat > 90) {
      _showError(const FormatException('纬度需在 -90 至 90 之间'));
      return;
    }
    if (lon == null || !lon.isFinite || lon < -180 || lon > 180) {
      _showError(const FormatException('经度需在 -180 至 180 之间'));
      return;
    }
    if (altitude == null ||
        !altitude.isFinite ||
        altitude < -1000 ||
        altitude > 100000) {
      _showError(const FormatException('海拔需在 -1000 至 100000 米之间'));
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await _perform('apply', {'lat': lat, 'lon': lon, 'altitude': altitude});
    if (mounted && _error == null) setState(() => _pickedNotice = null);
  }

  Future<void> _pickOnMap() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final lat = double.tryParse(_lat.text.trim());
    final lon = double.tryParse(_lon.text.trim());
    final initial =
        lat != null &&
            lon != null &&
            lat.isFinite &&
            lon.isFinite &&
            lat.abs() <= 90 &&
            lon.abs() <= 180
        ? LatLng(lat, lon)
        : null;
    final point = await Navigator.of(context).push<LatLng>(
      CupertinoPageRoute(builder: (_) => AndroidMapPicker(initial: initial)),
    );
    if (!mounted || point == null) return;
    setState(() {
      _lat.text = point.latitude.toStringAsFixed(6);
      _lon.text = point.longitude.toStringAsFixed(6);
      _pickedNotice = '地图坐标已填入，点击下方按钮应用。';
    });
  }

  Future<void> _searchSettings() async {
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final options = await loadAndroidSearchOptions();
      if (!mounted) return;
      await Navigator.of(context).push<Object?>(
        CupertinoPageRoute(
          builder: (_) => AndroidSearchSettings(options: options),
        ),
      );
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _saveLocalAddress() async {
    await _perform('configuration.saveLocal', {
      'local': _local.text.trim().toUpperCase(),
    });
    if (mounted && _error == null) {
      setState(() => _settingsNotice = '本机蓝牙地址已保存');
    }
  }

  void _about() {
    FocusManager.instance.primaryFocus?.unfocus();
    final updates = androidUpdates();
    unawaited(
      Navigator.of(context).push<void>(
        CupertinoPageRoute(
          builder: (_) => AboutPage(
            version: AppInfo.androidVersion,
            platform: 'Android 蓝牙版',
            updates: updates,
            onOpenLink: (url) =>
                _control.invokeMethod<void>('openGithub', {'url': url}),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _tabs.dispose();
    for (final c in [_local, _lat, _lon, _altitude]) {
      c.dispose();
    }
    super.dispose();
  }

  static const _secondary = Color(0xFF71717A);
  static const _line = Color(0xFFECECF1);

  Widget _text(String text) => Text(
    text,
    style: const TextStyle(fontSize: 13, color: _secondary, height: 1.55),
  );

  Widget _section(String id, String title, List<Widget> children) {
    final hidden = _collapsed.contains(id);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: CupertinoColors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE9EAF0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(44, 36),
                onPressed: () => setState(() {
                  hidden ? _collapsed.remove(id) : _collapsed.add(id);
                }),
                child: Row(
                  children: [
                    Text(
                      hidden ? '展开' : '收起',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(width: 5),
                    Icon(
                      hidden
                          ? CupertinoIcons.chevron_down
                          : CupertinoIcons.chevron_up,
                      size: 13,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!hidden) ...[const SizedBox(height: 10), ...children],
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String placeholder, {
    bool numeric = true,
    bool enabled = true,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: CupertinoTextField(
      controller: controller,
      enabled: enabled,
      placeholder: placeholder,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: (_) {
        if (controller == _local) setState(() => _settingsNotice = null);
        if (controller != _local && _pickedNotice != null) {
          setState(() => _pickedNotice = null);
        }
      },
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      textCapitalization: numeric
          ? TextCapitalization.none
          : TextCapitalization.characters,
      prefix: Padding(
        padding: const EdgeInsets.only(left: 13),
        child: SizedBox(
          width: numeric ? 54 : 72,
          child: Text(label, style: const TextStyle(fontSize: 14)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      style: const TextStyle(fontSize: 15, color: Color(0xFF1D1D1F)),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _line),
      ),
    ),
  );

  Widget _statusChip(String title, bool done) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: done ? const Color(0xFFE9F7EF) : const Color(0xFFF2F3F7),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          done
              ? CupertinoIcons.check_mark_circled_solid
              : CupertinoIcons.circle,
          size: 13,
          color: done ? const Color(0xFF228A54) : _secondary,
        ),
        const SizedBox(width: 5),
        Text(title, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );

  String get _phaseTitle => switch (_state['phase']) {
    'connecting' => '正在连接 iPhone',
    'negotiating' => '正在协商 iAP2',
    'authenticating' => '等待 iPhone 认证',
    'subscribing' => '等待定位订阅',
    'ready' => '连接就绪',
    'pending' => '新坐标等待发送',
    'streaming' => '正在持续发送',
    'error' => '连接已停止',
    _ => '尚未连接',
  };

  Widget _status() => _section('status', '连接状态', [
    Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFECF4FF),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(
            _state['phase'] == 'streaming'
                ? CupertinoIcons.location_fill
                : CupertinoIcons.bluetooth,
            color: const Color(0xFF007AFF),
            size: 25,
          ),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _phaseTitle,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              _text('已提交 ${_state['reports'] ?? 0} 次定位报文'),
            ],
          ),
        ),
      ],
    ),
    const SizedBox(height: 14),
    Wrap(
      spacing: 6,
      runSpacing: 7,
      children: [
        _statusChip('蓝牙', _state['connected'] == true),
        _statusChip('识别', _state['identified'] == true),
        _statusChip('认证', _state['authenticated'] == true),
        _statusChip('订阅', _state['subscribed'] == true),
      ],
    ),
    const SizedBox(height: 12),
    _text(_state['detail'] as String? ?? '先在系统蓝牙设置中将安卓手机与 iPhone 配对。'),
    if (_state['queuedAt'] is String) ...[
      const SizedBox(height: 10),
      _text(
        '最近提交 ${DateTime.tryParse(_state['queuedAt'] as String)?.toLocal().toString().substring(11, 19) ?? '—'}'
        ' · 坐标版本 ${_state['queuedRevision'] ?? 0}/${_state['revision'] ?? 0}',
      ),
      if (_state['targetLat'] is num && _state['targetLon'] is num)
        _text(
          '当前目标  ${(_state['targetLat'] as num).toStringAsFixed(6)}, '
          '${(_state['targetLon'] as num).toStringAsFixed(6)}',
        ),
    ],
    const SizedBox(height: 7),
    _text('发送计数代表本机已提交报文，iPhone 的实际位置请在手机地图中确认。'),
    if (_active) ...[
      const SizedBox(height: 14),
      CupertinoButton(
        color: const Color(0xFFFFEFEF),
        borderRadius: BorderRadius.circular(12),
        onPressed: _busy ? null : () => _perform('disconnect'),
        child: Text(
          _state['connected'] == true ? '断开连接' : '取消连接',
          style: const TextStyle(
            color: Color(0xFFCC3434),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  ]);

  Widget _deviceSection() => _section('devices', '我的设备', [
    Row(
      children: [
        Expanded(
          child: CupertinoButton(
            color: const Color(0xFFF0F5FF),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            borderRadius: BorderRadius.circular(12),
            onPressed: _reading ? null : _refresh,
            child: _reading
                ? const CupertinoActivityIndicator()
                : const Text('读取已配对设备', style: TextStyle(fontSize: 14)),
          ),
        ),
        const SizedBox(width: 8),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          onPressed: () => _perform('settings'),
          child: const Text('蓝牙设置', style: TextStyle(fontSize: 14)),
        ),
      ],
    ),
    if (_notice != null) ...[const SizedBox(height: 10), _text(_notice!)],
    if (_devices.isNotEmpty) ...[
      const SizedBox(height: 10),
      ..._devices.map((device) {
        final selected = device['address'] == _selected;
        return CupertinoButton(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
          onPressed: _active
              ? null
              : () => setState(() => _selected = device['address'] as String),
          child: Row(
            children: [
              Icon(
                CupertinoIcons.device_phone_portrait,
                size: 22,
                color: selected ? const Color(0xFF007AFF) : _secondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device['name'] as String,
                      style: const TextStyle(
                        fontSize: 15,
                        color: Color(0xFF1D1D1F),
                      ),
                    ),
                    _text(device['address'] as String),
                  ],
                ),
              ),
              Icon(
                selected
                    ? CupertinoIcons.check_mark_circled_solid
                    : CupertinoIcons.circle,
                size: 21,
                color: selected
                    ? const Color(0xFF007AFF)
                    : const Color(0xFFCBCBD2),
              ),
            ],
          ),
        );
      }),
    ],
    const SizedBox(height: 8),
    _text(
      _local.text.trim().isEmpty
          ? '先在“设置”中填写安卓本机蓝牙地址。'
          : '本机地址  ${_local.text.trim().toUpperCase()}',
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(vertical: 8),
        onPressed: () {
          FocusManager.instance.primaryFocus?.unfocus();
          _tabs.index = 1;
        },
        child: const Text('管理本机地址', style: TextStyle(fontSize: 13)),
      ),
    ),
    const SizedBox(height: 4),
    CupertinoButton.filled(
      borderRadius: BorderRadius.circular(13),
      onPressed: _active || _busy ? null : _connect,
      child: Text(
        _active ? '蓝牙会话进行中' : '连接所选 iPhone',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
  ]);

  Widget _coordinates() => _section('coordinates', '目标位置', [
    CupertinoButton(
      color: const Color(0xFFECF4FF),
      borderRadius: BorderRadius.circular(13),
      onPressed: _busy ? null : _pickOnMap,
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(CupertinoIcons.map, size: 20),
          SizedBox(width: 9),
          Text('地图选点与搜索', style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(width: 8),
          Icon(CupertinoIcons.chevron_right, size: 14),
        ],
      ),
    ),
    const SizedBox(height: 14),
    if (_pickedNotice != null) ...[
      _text(_pickedNotice!),
      const SizedBox(height: 10),
    ],
    _field('纬度', _lat, '-90 ～ 90'),
    _field('经度', _lon, '-180 ～ 180'),
    _field('海拔', _altitude, '米'),
    _text('使用 WGS84 坐标。连接期间可以反复修改并应用，无需先断开蓝牙。'),
    const SizedBox(height: 14),
    CupertinoButton.filled(
      borderRadius: BorderRadius.circular(13),
      onPressed: !_active || _busy ? null : _apply,
      child: const Text(
        '应用并持续发送',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
  ]);

  Widget _errorBanner() => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
    decoration: BoxDecoration(
      color: const Color(0xFFFFEDED),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _error!,
            style: const TextStyle(color: Color(0xFFB52F37), fontSize: 13),
          ),
        ),
        CupertinoButton(
          onPressed: () => setState(() => _error = null),
          padding: const EdgeInsets.all(10),
          child: const Icon(
            CupertinoIcons.xmark,
            color: Color(0xFFB52F37),
            size: 16,
          ),
        ),
      ],
    ),
  );

  Widget _page(String title, String storageKey, List<Widget> children) =>
      CupertinoPageScaffold(
        child: SafeArea(
          top: false,
          child: CustomScrollView(
            key: PageStorageKey(storageKey),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              CupertinoSliverNavigationBar(
                largeTitle: Text(title),
                backgroundColor: const Color(0xF5F2F3F7),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
                sliver: SliverList.list(
                  children: [if (_error != null) _errorBanner(), ...children],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _home() => _page('随行定位', 'home-scroll', [
    Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 16),
      child: _text('安卓连接 iPhone · $_android'),
    ),
    _status(),
    _coordinates(),
    _deviceSection(),
  ]);

  Widget _settingsRow(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback onPressed,
  ) => CupertinoButton(
    padding: const EdgeInsets.symmetric(vertical: 10),
    onPressed: onPressed,
    child: Row(
      children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: const Color(0xFFECF4FF),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(color: Color(0xFF1D1D1F), fontSize: 15),
              ),
              const SizedBox(height: 3),
              _text(subtitle),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const Icon(CupertinoIcons.chevron_right, size: 14, color: _secondary),
      ],
    ),
  );

  Widget _settings() => _page('设置', 'settings-scroll', [
    _section('search-settings', '地图与搜索', [
      _settingsRow(
        '搜索设置',
        '搜索服务、Web 服务 Key 与优先城市',
        CupertinoIcons.map,
        _searchSettings,
      ),
    ]),
    _section('local-address', '本机蓝牙地址', [
      _field(
        '本机地址',
        _local,
        'AA:BB:CC:DD:EE:FF',
        numeric: false,
        enabled: !_active && !_busy,
      ),
      _text('填写安卓手机自己的真实蓝牙地址。若系统限制自动读取，可在“关于手机 → 状态信息”中查看。'),
      if (_active) ...[const SizedBox(height: 8), _text('断开当前连接后可修改本机地址。')],
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          CupertinoButton.filled(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            onPressed: _active || _busy ? null : _saveLocalAddress,
            child: const Text('保存本机地址', style: TextStyle(fontSize: 14)),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            onPressed: () => _perform('deviceInfo'),
            child: const Text('打开手机信息', style: TextStyle(fontSize: 14)),
          ),
        ],
      ),
      if (_settingsNotice != null) ...[
        const SizedBox(height: 8),
        _text(_settingsNotice!),
      ],
    ]),
    _section('application-settings', '应用', [
      _settingsRow(
        '连接通知',
        '允许系统显示当前蓝牙连接状态',
        CupertinoIcons.bell,
        () => _perform('notifications'),
      ),
      const SizedBox(height: 4),
      _settingsRow(
        '关于随行定位',
        '版本、GitHub 与开源说明',
        CupertinoIcons.info_circle,
        _about,
      ),
    ]),
  ]);

  @override
  Widget build(BuildContext context) => CupertinoTabScaffold(
    controller: _tabs,
    tabBar: CupertinoTabBar(
      height: 54,
      iconSize: 24,
      backgroundColor: const Color(0xF5FFFFFF),
      onTap: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      items: const [
        BottomNavigationBarItem(
          icon: Icon(CupertinoIcons.house),
          activeIcon: Icon(CupertinoIcons.house_fill),
          label: '首页',
        ),
        BottomNavigationBarItem(
          icon: Icon(CupertinoIcons.settings),
          label: '设置',
        ),
      ],
    ),
    tabBuilder: (_, index) => index == 0 ? _home() : _settings(),
  );
}
