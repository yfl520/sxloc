import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suixing_loc/about_page.dart';
import 'package:suixing_loc/app_info.dart';
import 'package:suixing_loc/main_android.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const control = MethodChannel('suixing/android/control');
  const events = EventChannel('suixing/android/events');

  Future<void> openApp(
    WidgetTester tester,
    List<MethodCall> calls, {
    bool active = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    binding.defaultBinaryMessenger.setMockMethodCallHandler(control, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'configuration') {
        return {
          'local': 'AA:BB:CC:DD:EE:FF',
          'lat': '31.2304',
          'lon': '121.4737',
          'altitude': '0',
          'android': '17',
        };
      }
      return null;
    });
    binding.defaultBinaryMessenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (_, sink) => sink.success({
          'active': active,
          'phase': active ? 'streaming' : 'idle',
          'reports': 9,
        }),
      ),
    );
    addTearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(control, null);
      binding.defaultBinaryMessenger.setMockStreamHandler(events, null);
    });
    await tester.pumpWidget(const BluetoothTestApp());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'home and settings preserve draft and active session without reconnecting',
    (tester) async {
      final calls = <MethodCall>[];
      await openApp(tester, calls, active: true);
      expect(find.text('正在持续发送'), findsOneWidget);
      expect(find.text('地图选点与搜索'), findsOneWidget);
      final latitude = find.byWidgetPredicate(
        (widget) =>
            widget is CupertinoTextField &&
            widget.controller?.text == '31.2304',
      );
      tester.widget<CupertinoTextField>(latitude).controller!.text =
          '32.123456';
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      expect(find.text('地图选点与搜索'), findsNothing);
      expect(find.text('搜索设置'), findsOneWidget);
      expect(find.textContaining('诊断'), findsNothing);
      expect(find.text('最近日志'), findsNothing);
      final local = find.byWidgetPredicate(
        (widget) =>
            widget is CupertinoTextField &&
            widget.controller?.text == 'AA:BB:CC:DD:EE:FF',
      );
      expect(tester.widget<CupertinoTextField>(local).enabled, isFalse);
      await tester.tap(find.text('首页'));
      await tester.pumpAndSettle();
      expect(find.text('正在持续发送'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CupertinoTextField &&
              widget.controller?.text == '32.123456',
        ),
        findsOneWidget,
      );
      expect(
        calls.where(
          (c) => ['connect', 'disconnect', 'apply'].contains(c.method),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings saves local address without applying a location', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    await openApp(tester, calls);
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    final local = find.byWidgetPredicate(
      (widget) =>
          widget is CupertinoTextField &&
          widget.controller?.text == 'AA:BB:CC:DD:EE:FF',
    );
    tester.widget<CupertinoTextField>(local).controller!.text =
        'aa:bb:cc:dd:ee:01';
    await tester.ensureVisible(find.text('保存本机地址'));
    await tester.tap(find.text('保存本机地址'));
    await tester.pumpAndSettle();
    expect(
      calls.singleWhere((c) => c.method == 'configuration.saveLocal').arguments,
      {'local': 'AA:BB:CC:DD:EE:01'},
    );
    expect(
      calls.where((c) => ['connect', 'disconnect', 'apply'].contains(c.method)),
      isEmpty,
    );
    expect(find.text('本机蓝牙地址已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shared about page attributes upstream without inventing own repository',
    (tester) async {
      final opened = <String>[];
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        CupertinoApp(
          home: AboutPage(
            version: AppInfo.androidVersion,
            platform: 'Android 蓝牙版',
            onOpenLink: (url) async {
              opened.add(url);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('项目仓库 · ios定位'), findsOneWidget);
      expect(find.textContaining('GitHub 仓库尚未发布'), findsOneWidget);
      await tester.ensureVisible(find.text(AppInfo.upstreamGithub));
      final button = find.text('打开 GitHub').first;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(opened, [AppInfo.upstreamGithub]);
      expect(tester.takeException(), isNull);
    },
  );

  test('repository configuration accepts GitHub repository URLs only', () {
    expect(AppInfo.isGithubRepository(AppInfo.upstreamGithub), isTrue);
    for (final url in [
      '',
      'https://github.com',
      'https://example.com/name/repo',
      'https://user@github.com/name/repo',
      'http://github.com/name/repo',
      'https://github.com/name/repo?token=value',
    ]) {
      expect(AppInfo.isGithubRepository(url), isFalse);
    }
  });
}
