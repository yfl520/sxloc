import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:file_selector/file_selector.dart';

import 'core_client.dart';
import 'ui.dart';
import 'desktop_about.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key, required this.core});
  final CoreClient core;
  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  final keyField = TextEditingController();
  late final TextEditingController city, endpoint;
  late String provider;
  bool saving = false, importing = false, clearKey = false, custom = false;
  String? message;
  CoreClient get core => widget.core;

  @override
  void initState() {
    super.initState();
    city = TextEditingController(
      text: core.settings['searchCity']?.toString() ?? '',
    );
    endpoint = TextEditingController(
      text:
          core.settings['photonEndpoint']?.toString() ??
          'https://photon.komoot.io/api/',
    );
    provider = core.settings['searchProvider']?.toString() ?? 'auto';
  }

  @override
  void dispose() {
    keyField.dispose();
    city.dispose();
    endpoint.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      message = null;
    });
    try {
      await core.call('settings.save', {
        'searchProvider': provider,
        'searchCity': city.text.trim(),
        'photonEndpoint': endpoint.text.trim(),
        'amapKey': keyField.text.trim(),
        'clearAmapKey': clearKey,
      });
      await core.refresh();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> identityAction(String method, [JsonMap args = const {}]) async {
    setState(() {
      importing = true;
      message = null;
    });
    try {
      await core.call(method, args);
      await core.refresh();
      if (mounted) setState(() => message = '身份材料已更新，对之后的新连接生效。');
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> importIdentity() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'DiPlay APK 或 PKCS#8 私钥',
          extensions: ['apk', 'pk8'],
        ),
      ],
      confirmButtonText: '导入身份',
    );
    if (file != null) {
      await identityAction('identity.import', {'path': file.path});
    }
  }

  Widget group(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 3, bottom: 8),
          child: Text(title, style: textStyle(11, muted, FontWeight.w600)),
        ),
        Container(
          padding: const EdgeInsets.all(17),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              group('地点搜索', [
                CupertinoSlidingSegmentedControl<String>(
                  groupValue: provider,
                  children: {
                    'auto': Text('自动选择', style: textStyle(12)),
                    'amap': Text('高德搜索', style: textStyle(12)),
                    'photon': Text('免 Key 搜索', style: textStyle(12)),
                  },
                  onValueChanged: (v) {
                    if (v != null) setState(() => provider = v);
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  '自动选择：已配置 Key 时优先高德，失败或无可用坐标时补查开放地图。',
                  style: textStyle(10, muted),
                ),
                const SizedBox(height: 18),
                MacField(
                  controller: keyField,
                  label: '高德 Web 服务 Key',
                  obscure: true,
                  hint: core.settings['hasAmapKey'] == true
                      ? '已保存，留空保持当前 Key'
                      : '填写 Web 服务类型的 Key',
                ),
                const SizedBox(height: 7),
                Text(
                  '按当前 Windows 用户加密保存。国内详细地址建议使用高德搜索。',
                  style: textStyle(10, muted),
                ),
                if (core.settings['hasAmapKey'] == true)
                  Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 32,
                        child: CupertinoCheckbox(
                          value: clearKey,
                          onChanged: (v) =>
                              setState(() => clearKey = v ?? false),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text('保存时清除已存的 Key', style: textStyle(10, muted)),
                    ],
                  ),
                const SizedBox(height: 14),
                MacField(controller: city, label: '优先搜索城市', hint: '可留空，例如：上海'),
                const SizedBox(height: 15),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  alignment: Alignment.centerLeft,
                  onPressed: () => setState(() => custom = !custom),
                  child: Row(
                    children: [
                      Icon(
                        custom
                            ? CupertinoIcons.chevron_down
                            : CupertinoIcons.chevron_right,
                        size: 10,
                        color: muted,
                      ),
                      const SizedBox(width: 6),
                      Text('自定义开放地图服务', style: textStyle(11, muted)),
                    ],
                  ),
                ),
                if (custom) ...[
                  const SizedBox(height: 10),
                  MacField(
                    controller: endpoint,
                    hint: '兼容 Photon API 的 HTTPS 地址',
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '可使用默认公共服务或自建 Photon；仅本机服务允许 HTTP。',
                    style: textStyle(10, muted),
                  ),
                ],
              ]),
              group('配件认证身份', [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      CupertinoIcons.lock_shield,
                      size: 24,
                      color: core.identity['valid'] == true
                          ? const Color(0xFF34A366)
                          : muted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        core.identity['detail']?.toString() ?? '尚未检查身份材料',
                        style: textStyle(12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '这里只检查证书与私钥是否匹配；认证是否通过，以设备连接后的状态为准。',
                  style: textStyle(10, muted),
                ),
                const SizedBox(height: 15),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    MacButton(
                      '导入 APK / 私钥',
                      compact: true,
                      icon: CupertinoIcons.square_arrow_down,
                      onPressed: importing ? null : importIdentity,
                    ),
                    MacButton(
                      '使用内置身份',
                      compact: true,
                      onPressed: importing
                          ? null
                          : () => identityAction('identity.builtin'),
                    ),
                    MacButton(
                      '重新检查',
                      compact: true,
                      onPressed: importing
                          ? null
                          : () => identityAction('identity.check'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '导入 PK8 时同目录需有 certificate.p7b。APK 支持包含 offline-mfi 材料的 DiPlay 安装包。',
                  style: textStyle(10, muted),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 13),
                  child: Divider(height: 1, color: line),
                ),
                Text(
                  '配件序列号  ${core.identity['serial'] ?? '—'}',
                  style: textStyle(10, muted),
                ),
                const SizedBox(height: 5),
                Text(
                  '报告地址  ${core.identity['adapterAddress'] ?? '本机地址'}',
                  style: textStyle(10, muted),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: MacButton(
                    '更新配件信息',
                    compact: true,
                    onPressed: importing
                        ? null
                        : () => identityAction('identity.rotate'),
                  ),
                ),
                const SizedBox(height: 7),
                Text('更新名称、序列号和报告地址，对新连接生效。', style: textStyle(10, muted)),
              ]),
              group('本地数据', [
                Align(
                  alignment: Alignment.centerLeft,
                  child: MacButton(
                    '打开应用数据目录',
                    icon: CupertinoIcons.folder,
                    compact: true,
                    onPressed: () async {
                      try {
                        await core.call('openData');
                      } catch (e) {
                        if (mounted) setState(() => message = e.toString());
                      }
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '收藏、搜索历史和参数保存在当前用户下，升级应用后继续保留。',
                  style: textStyle(10, muted),
                ),
              ]),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Text(
                    message!,
                    style: textStyle(11, const Color(0xFFAA6550)),
                  ),
                ),
              MacButton(
                '关于随行定位',
                icon: CupertinoIcons.info_circle,
                onPressed: () => showDesktopAbout(context, core),
              ),
              const SizedBox(height: 6),
              Text(
                '参考 Apple Human Interface Guidelines。地图和地点搜索需要网络，搜索内容会发送给所选服务。',
                style: textStyle(10, muted),
              ),
              const SizedBox(height: 22),
            ],
          ),
        ),
      ),
      const Divider(height: 1, color: line),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
        child: Row(
          children: [
            Expanded(child: Text('身份导入和切换会立即保存', style: textStyle(10, muted))),
            MacButton(
              '取消',
              onPressed: saving ? null : () => Navigator.pop(context),
            ),
            const SizedBox(width: 8),
            MacButton(
              '保存设置',
              primary: true,
              busy: saving,
              onPressed: saving ? null : save,
            ),
          ],
        ),
      ),
    ],
  );
}
