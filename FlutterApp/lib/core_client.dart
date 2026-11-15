import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

typedef JsonMap = Map<String, dynamic>;

class CoreClient extends ChangeNotifier {
  Process? _process;
  Timer? _timer;
  int _next = 0;
  bool _polling = false;
  bool _closing = false;
  final _pending = <int, Completer<dynamic>>{};
  JsonMap state = {};
  List<JsonMap> devices = [];
  String? failure;
  String? deviceFailure;
  List<JsonMap> usbDevices = [];
  String? usbDeviceFailure;

  JsonMap get target => map(state['target']);
  JsonMap get settings => map(state['settings']);
  JsonMap get identity => map(state['identity']);
  List<JsonMap> get favorites => list(state['favorites']);
  List<JsonMap> get sessions => list(state['sessions']);
  JsonMap get usb => map(state['usb']);
  bool get ready => state.isNotEmpty && failure == null;
  static JsonMap map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  static List<JsonMap> list(dynamic value) =>
      value is List ? value.map(map).toList() : [];

  Future<void> start() async {
    try {
      final executable =
          Platform.environment['SUIXING_CORE'] ??
          p.join(
            p.dirname(Platform.resolvedExecutable),
            'core',
            'SuixingLoc.Core.exe',
          );
      if (!File(executable).existsSync()) {
        throw const CoreError('未找到定位组件，请完整解压应用文件夹，或重新安装。');
      }
      _process = await Process.start(
        executable,
        [],
        workingDirectory: p.dirname(executable),
      );
      _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_receive, onError: (_) => _failed('定位组件通信中断，请重新启动应用。'));
      _process!.stderr.transform(utf8.decoder).listen((_) {});
      unawaited(
        _process!.exitCode.then((code) {
          if (!_closing) _failed('定位组件已退出，请重新启动应用。');
        }),
      );
      state = map(await call('init'));
      notifyListeners();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
      try {
        await refreshDevices();
      } catch (_) {
        // Map search and saved places remain available without a Bluetooth radio.
      }
    } catch (error) {
      _failed(error is CoreError ? error.message : '定位组件无法启动，请检查应用是否解压完整。');
    }
  }

  void _receive(String line) {
    try {
      final value = map(jsonDecode(line));
      if (value['eventName'] == 'fatal') {
        _failed(value['error']?.toString() ?? '定位组件启动失败');
        return;
      }
      final completer = _pending.remove(value['id']);
      if (completer == null || completer.isCompleted) return;
      if (value['error'] != null) {
        completer.completeError(CoreError(value['error'].toString()));
      } else {
        completer.complete(value['result']);
      }
    } catch (_) {
      _failed('定位组件返回了无法读取的数据，请重新启动应用。');
    }
  }

  void _failed(String message) {
    failure = message;
    _timer?.cancel();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(CoreError(message));
    }
    _pending.clear();
    if (!_closing) notifyListeners();
  }

  Future<dynamic> call(String method, [JsonMap args = const {}]) async {
    if (_process == null || (_closing && method != 'shutdown')) {
      throw const CoreError('定位组件尚未就绪');
    }
    final id = ++_next;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      _process!.stdin.writeln(
        jsonEncode({'id': id, 'method': method, 'args': args}),
      );
      await _process!.stdin.flush();
      return await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const CoreError('操作超时，请稍后重试。');
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _poll() async {
    if (_polling || _closing || failure != null) return;
    _polling = true;
    try {
      await refresh();
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  Future<void> refresh() async {
    state = map(await call('snapshot'));
    if (!_closing) notifyListeners();
  }

  Future<void> refreshDevices() async {
    try {
      devices = list(await call('devices'));
      deviceFailure = null;
    } catch (error) {
      devices = [];
      deviceFailure = error.toString();
      rethrow;
    } finally {
      if (!_closing) notifyListeners();
    }
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    try {
      if (_process != null) {
        await call('shutdown').timeout(const Duration(seconds: 25));
        await _process!.stdin.close();
        await _process!.exitCode.timeout(const Duration(seconds: 18));
      }
    } catch (_) {
      _process?.kill();
    }
  }

  Future<void> refreshUsbDevices() async {
    try {
      usbDevices = list(await call('usb.devices'));
      usbDeviceFailure = null;
    } catch (error) {
      usbDevices = [];
      usbDeviceFailure = error.toString();
      rethrow;
    } finally {
      if (!_closing) notifyListeners();
    }
  }
}

class CoreError implements Exception {
  const CoreError(this.message);
  final String message;
  @override
  String toString() => message;
}
