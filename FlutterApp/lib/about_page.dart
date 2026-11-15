import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import 'app_info.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({
    super.key,
    required this.version,
    required this.platform,
    required this.onOpenLink,
  });
  final String version, platform;
  final Future<void> Function(String) onOpenLink;

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: const CupertinoNavigationBar(middle: Text('关于随行定位')),
    child: SafeArea(
      child: AboutContent(
        version: version,
        platform: platform,
        onOpenLink: onOpenLink,
      ),
    ),
  );
}

class AboutContent extends StatefulWidget {
  const AboutContent({
    super.key,
    required this.version,
    required this.platform,
    required this.onOpenLink,
  });
  final String version, platform;
  final Future<void> Function(String) onOpenLink;

  @override
  State<AboutContent> createState() => _AboutContentState();
}

class _AboutContentState extends State<AboutContent> {
  String? _message;
  bool _opening = false;
  static const _secondary = Color(0xFF71717A);

  Future<void> _open(String url) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _message = null;
    });
    try {
      await widget.onOpenLink(url);
    } catch (_) {
      if (mounted) setState(() => _message = '暂时无法打开 GitHub，可复制地址后在浏览器中打开。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _repository(
    String title,
    String description,
    String? url,
  ) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: CupertinoColors.white,
      border: Border.all(color: const Color(0xFFE9EAF0)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        Text(
          description,
          style: const TextStyle(fontSize: 12, color: _secondary, height: 1.5),
        ),
        if (url != null) ...[
          const SizedBox(height: 10),
          Text(
            url,
            style: const TextStyle(fontSize: 12, color: Color(0xFF007AFF)),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            children: [
              CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 6),
                minimumSize: const Size(44, 36),
                onPressed: _opening ? null : () => _open(url),
                child: const Text('打开 GitHub', style: TextStyle(fontSize: 13)),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 6),
                minimumSize: const Size(44, 36),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (mounted) setState(() => _message = 'GitHub 地址已复制');
                },
                child: const Text('复制地址', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: Icon(
            CupertinoIcons.location_circle_fill,
            size: 64,
            color: Color(0xFF007AFF),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          AppInfo.name,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        Text(
          '${widget.platform} · ${widget.version}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: _secondary),
        ),
        const SizedBox(height: 12),
        const Text(
          '地图搜索、自由选点，让位置选择更直观。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: _secondary, height: 1.5),
        ),
        const SizedBox(height: 26),
        _repository(
          '项目仓库 · ${AppInfo.projectName}',
          AppInfo.projectRepository == null
              ? 'GitHub 仓库尚未发布，发布后将提供源码地址。'
              : '查看源码、提交问题与参与项目。',
          AppInfo.projectRepository,
        ),
        _repository(
          '原项目 · iap2loc',
          '基于 D1ngtalk/iap2loc 开发，感谢原作者的协议实现。',
          AppInfo.upstreamGithub,
        ),
        _repository(
          '实验身份来源 · DiPlay',
          '内置实验身份来自 DiPlay 公开版本。',
          AppInfo.identityGithub,
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              _message!,
              style: const TextStyle(fontSize: 12, color: _secondary),
            ),
          ),
        const Text(
          '开源许可 · GPL-3.0',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        const Text(
          '保留原项目版权与许可证。感谢 Flutter、flutter_map、Photon、OpenStreetMap 和高德地图。第三方组件保留各自许可证及署名。',
          style: TextStyle(fontSize: 12, color: _secondary, height: 1.6),
        ),
      ],
    ),
  );
}
