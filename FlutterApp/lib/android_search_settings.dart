import 'package:cupertino_ui/cupertino_ui.dart';
// Read-only Cupertino fields display drafts; Android owns the editor connection.
// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart' as sdk;
import 'package:flutter/services.dart';

import 'android_place_search.dart';

const androidSearchControl = MethodChannel('suixing/android/control');

Future<PlaceSearchOptions> loadAndroidSearchOptions() async {
  final data = await androidSearchControl.invokeMapMethod<String, dynamic>(
    'mapSearch.configuration',
  );
  return PlaceSearchOptions(
    provider: data?['provider'] as String? ?? 'auto',
    key: data?['key'] as String? ?? '',
    city: data?['city'] as String? ?? '',
    nearby: data?['nearby'] != false,
  );
}

class AndroidSearchSettings extends StatefulWidget {
  const AndroidSearchSettings({super.key, required this.options});
  final PlaceSearchOptions options;

  @override
  State<AndroidSearchSettings> createState() => _AndroidSearchSettingsState();
}

class _AndroidSearchSettingsState extends State<AndroidSearchSettings> {
  late final TextEditingController _key;
  late final TextEditingController _city;
  final _keyFocus = FocusNode(debugLabel: '高德 Key', canRequestFocus: false);
  final _cityFocus = FocusNode(debugLabel: '优先城市', canRequestFocus: false);
  late String _provider;
  late bool _nearby;
  bool _reveal = false;
  bool _saving = false;
  bool _editingNative = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: widget.options.key);
    _city = TextEditingController(text: widget.options.city);
    _provider = widget.options.provider;
    _nearby = widget.options.nearby;
  }

  @override
  void dispose() {
    _key.dispose();
    _city.dispose();
    _keyFocus.dispose();
    _cityFocus.dispose();
    super.dispose();
  }

  Future<void> _compatInput(String field) async {
    if (_saving || _editingNative) return;
    FocusScope.of(context).unfocus();
    setState(() => _editingNative = true);
    try {
      final controller = field == 'key' ? _key : _city;
      final value = await androidSearchControl.invokeMethod<String>(
        'mapSearch.edit',
        {'field': field, 'value': controller.text},
      );
      if (!mounted) return;
      if (value != null) {
        controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '兼容输入暂时无法打开，请重试。');
      }
    } finally {
      if (mounted) setState(() => _editingNative = false);
    }
  }

  Widget _fieldTitle(String title, String field) => Row(
    children: [
      Expanded(
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      CupertinoButton(
        key: ValueKey('compat-$field'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        minimumSize: const Size(44, 36),
        onPressed: _saving || _editingNative ? null : () => _compatInput(field),
        child: const Text('编辑', style: TextStyle(fontSize: 13)),
      ),
    ],
  );

  Future<void> _save() async {
    if (_saving || _editingNative) return;
    final key = _key.text.trim(), city = _city.text.trim();
    if (_provider == 'amap' && key.isEmpty) {
      setState(() => _error = '请填写高德 Web 服务 Key，或选择自动／开放地图。');
      return;
    }
    if (key.isNotEmpty && !RegExp(r'^[A-Za-z0-9]{16,128}$').hasMatch(key)) {
      setState(() => _error = 'Key 格式无效，请填写高德 Web 服务 Key。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    try {
      await androidSearchControl.invokeMethod<void>('mapSearch.save', {
        'provider': _provider,
        'key': key,
        'city': city,
        'nearby': _nearby,
      });
      if (!mounted) return;
      Navigator.pop(
        context,
        PlaceSearchOptions(
          provider: _provider,
          key: key,
          city: city,
          nearby: _nearby,
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is PlatformException
              ? error.message ?? '保存失败，请重试'
              : '保存失败，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.only(top: 9, bottom: 20),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        color: Color(0xFF71717A),
        height: 1.5,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => sdk.CupertinoTheme(
    data: sdk.CupertinoThemeData(
      brightness: Brightness.light,
      primaryColor: const Color(0xFF007AFF),
      textTheme: sdk.CupertinoTextThemeData(
        textStyle: const TextStyle(
          fontFamily: 'sans-serif',
          fontSize: 15,
          color: Color(0xFF1D1D1F),
          height: 1.4,
        ),
      ),
    ),
    child: CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('搜索设置')),
      child: SafeArea(
        // Keep draft displays mounted when the native editor changes insets.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '搜索服务',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              CupertinoSlidingSegmentedControl<String>(
                groupValue: _provider,
                children: const {
                  'auto': Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('自动'),
                  ),
                  'amap': Text('高德'),
                  'photon': Text('开放地图'),
                },
                onValueChanged: (value) {
                  if (!_saving && value != null) {
                    setState(() => _provider = value);
                  }
                },
              ),
              _hint(
                '自动模式：配置 Key 后优先使用高德，服务失败时改用开放地图并提示原因。未配置 Key 时使用开放地图。搜索服务独立于底图。',
              ),
              _fieldTitle('高德 Web 服务 Key', 'key'),
              const SizedBox(height: 10),
              ExcludeFocus(
                child: sdk.CupertinoTextField(
                  key: const ValueKey('amap-key-input'),
                  controller: _key,
                  focusNode: _keyFocus,
                  readOnly: true,
                  showCursor: false,
                  enableInteractiveSelection: false,
                  onTap: () => _compatInput('key'),
                  scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 80),
                  obscureText: !_reveal,
                  enabled: !_saving,
                  autocorrect: false,
                  enableSuggestions: false,
                  placeholder: '点此填写 Web 服务 Key',
                  padding: const EdgeInsets.all(14),
                  suffix: CupertinoButton(
                    padding: const EdgeInsets.all(10),
                    onPressed: _saving
                        ? null
                        : () {
                            setState(() => _reveal = !_reveal);
                          },
                    child: Text(
                      _reveal ? '隐藏' : '显示',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              ),
              _hint('在高德开放平台控制台创建应用，添加“Web 服务”类型的 Key。Key 在本机加密保存；清空后保存可删除。'),
              _fieldTitle('优先城市', 'city'),
              const SizedBox(height: 10),
              ExcludeFocus(
                child: sdk.CupertinoTextField(
                  key: const ValueKey('search-city-input'),
                  controller: _city,
                  focusNode: _cityFocus,
                  readOnly: true,
                  showCursor: false,
                  enableInteractiveSelection: false,
                  onTap: () => _compatInput('city'),
                  scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 80),
                  enabled: !_saving,
                  maxLength: 80,
                  placeholder: '点此填写城市；留空跟随地图区域',
                  padding: const EdgeInsets.all(14),
                ),
              ),
              _hint('高德优先返回该城市的地点；开放地图会将城市加入关键词。搜索其他城市时，也可直接输入完整城市加地名。'),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '优先当前地图附近',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  CupertinoSwitch(
                    value: _nearby,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _nearby = value),
                  ),
                ],
              ),
              _hint('以地图中心为参考，兼顾关键词匹配和附近地点。距离也是相对地图中心，不读取安卓手机的真实位置。'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: CupertinoColors.systemRed,
                      fontSize: 13,
                    ),
                  ),
                ),
              CupertinoButton.filled(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const CupertinoActivityIndicator(
                        color: CupertinoColors.white,
                      )
                    : const Text('保存设置'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
