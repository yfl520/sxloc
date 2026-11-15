import 'dart:convert';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const agreementVersion = '2026-11-15.1';
const _agreementControl = MethodChannel('suixing/android/control');

abstract class AgreementStore {
  Future<bool> isAccepted();
  Future<void> accept();
}

class LocalAgreementStore implements AgreementStore {
  File get _file => File(
    p.join(
      Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
      'SuixingLoc',
      'consent.json',
    ),
  );

  @override
  Future<bool> isAccepted() async {
    if (Platform.isAndroid) {
      return await _agreementControl.invokeMethod<String>('agreement.read') ==
          agreementVersion;
    }
    try {
      final data = jsonDecode(await _file.readAsString());
      return data is Map && data['version'] == agreementVersion;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> accept() async {
    if (Platform.isAndroid) {
      await _agreementControl.invokeMethod<void>('agreement.accept', {
        'version': agreementVersion,
      });
    } else {
      final file = _file;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'version': agreementVersion,
          'acceptedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
    }
  }
}

class AgreementGate extends StatefulWidget {
  const AgreementGate({
    super.key,
    required this.builder,
    required this.onDecline,
    this.store,
  });
  final WidgetBuilder builder;
  final Future<void> Function() onDecline;
  final AgreementStore? store;

  @override
  State<AgreementGate> createState() => _AgreementGateState();
}

class _AgreementGateState extends State<AgreementGate> {
  late final _store = widget.store ?? LocalAgreementStore();
  bool? _accepted;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final accepted = await _store.isAccepted();
      if (mounted) {
        setState(() {
          _accepted = accepted;
          _failure = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _accepted = false;
          _failure = '无法读取同意记录，请重新确认。';
        });
      }
    }
  }

  Future<void> _accept() async {
    try {
      await _store.accept();
      if (mounted) {
        setState(() {
          _accepted = true;
          _failure = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failure = '同意记录保存失败，请检查存储空间后重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_accepted == true) return widget.builder(context);
    if (_accepted == null) {
      return const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    return PopScope(
      canPop: false,
      child: AgreementPage(
        onAccept: _accept,
        onDecline: widget.onDecline,
        error: _failure,
      ),
    );
  }
}

class AgreementPage extends StatefulWidget {
  const AgreementPage({super.key, this.onAccept, this.onDecline, this.error});
  final Future<void> Function()? onAccept, onDecline;
  final String? error;

  @override
  State<AgreementPage> createState() => _AgreementPageState();
}

class _AgreementPageState extends State<AgreementPage> {
  late final _text = rootBundle.loadString('assets/service_agreement.md');
  bool _checked = false, _saving = false;

  Future<void> _submit() async {
    if (!_checked || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.onAccept?.call();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    backgroundColor: const Color(0xFFF6F6F8),
    navigationBar: const CupertinoNavigationBar(middle: Text('使用协议与免责声明')),
    child: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: FutureBuilder<String>(
                  future: _text,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const Center(child: Text('协议加载失败，请完整安装应用后重试。'));
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CupertinoActivityIndicator());
                    }
                    return ListView(
                      padding: const EdgeInsets.all(24),
                      children: [
                        for (final paragraph in snapshot.data!.split(
                          RegExp(r'\n\s*\n'),
                        ))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(
                              paragraph
                                  .replaceAll(RegExp(r'^#+\s*'), '')
                                  .replaceAll('**', '')
                                  .trim(),
                              style: TextStyle(
                                fontSize: paragraph.startsWith('#') ? 17 : 14,
                                fontWeight:
                                    paragraph.startsWith('#') ||
                                        paragraph.startsWith('**')
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: const Color(0xFF25252B),
                                height: 1.65,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              if (widget.onAccept != null)
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  decoration: const BoxDecoration(
                    color: CupertinoColors.white,
                    border: Border(top: BorderSide(color: Color(0xFFE5E5EA))),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.error != null)
                        Text(
                          widget.error!,
                          style: const TextStyle(
                            fontSize: 13,
                            color: CupertinoColors.destructiveRed,
                          ),
                        ),
                      FutureBuilder<String>(
                        future: _text,
                        builder: (context, snapshot) => CupertinoButton(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          onPressed: _saving || !snapshot.hasData
                              ? null
                              : () => setState(() => _checked = !_checked),
                          child: Row(
                            children: [
                              Icon(
                                _checked
                                    ? CupertinoIcons.check_mark_circled_solid
                                    : CupertinoIcons.circle,
                                size: 22,
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  '我已阅读并同意使用协议、免责声明与隐私告知',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      CupertinoButton.filled(
                        onPressed: _checked && !_saving ? _submit : null,
                        child: Text(_saving ? '正在保存…' : '同意并继续'),
                      ),
                      CupertinoButton(
                        onPressed: _saving ? null : widget.onDecline,
                        child: const Text(
                          '不同意并退出',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
