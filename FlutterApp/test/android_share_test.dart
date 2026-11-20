import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suixing_loc/android_map_link_import.dart';
import 'package:suixing_loc/android_map_picker.dart';
import 'package:suixing_loc/main_android.dart';
import 'package:suixing_loc/service_agreement.dart';

class _Consent implements AgreementStore {
  _Consent(this.accepted);
  bool accepted;
  @override
  Future<bool> isAccepted() async => accepted;
  @override
  Future<void> accept() async {
    accepted = true;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const control = MethodChannel('suixing/android/control');
  const shares = MethodChannel('suixing/android/share');
  const events = EventChannel('suixing/android/events');
  Map<String, String>? pending;
  final calls = <String>[];

  Future<void> open(WidgetTester tester, {bool accepted = true}) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(control, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'configuration') {
        return {'lat': '1', 'lon': '2', 'android': '17'};
      }
      if (call.method == 'mapSearch.configuration') return {'provider': 'auto'};
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(shares, (
      call,
    ) async {
      calls.add('share.${call.method}');
      final value = pending;
      pending = null;
      return value;
    });
    binding.defaultBinaryMessenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (_, sink) =>
            sink.success({'active': true, 'phase': 'streaming', 'reports': 7}),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      binding.defaultBinaryMessenger.setMockMethodCallHandler(control, null);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(shares, null);
      binding.defaultBinaryMessenger.setMockStreamHandler(events, null);
      await tester.binding.setSurfaceSize(null);
      pending = null;
    });
    await tester.pumpWidget(
      BluetoothTestApp(agreementStore: _Consent(accepted)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> deliver(WidgetTester tester, String text) async {
    pending = {'text': text};
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      shares.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('available'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  void expectNoDeviceCommands() => expect(
    calls.where(
      (method) => ['connect', 'disconnect', 'apply'].contains(method),
    ),
    isEmpty,
  );

  testWidgets('冷启动分享自动带入并解析，不请求键盘或发送定位', (tester) async {
    pending = {
      'text': 'https://uri.amap.com/marker?position=120.15,30.25&name=测试地点',
    };
    await open(tester);
    expect(find.byType(AndroidMapLinkImport), findsOneWidget);
    expect(find.text('测试地点'), findsOneWidget);
    expect(find.text('查看地图'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    expectNoDeviceCommands();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('正在持续发送'), findsOneWidget);
    expectNoDeviceCommands();
    expect(tester.takeException(), isNull);
  });

  testWidgets('后台收到分享复用当前页面，新分享替换旧分享，返回不重复导入', (tester) async {
    pending = null;
    await open(tester);
    await deliver(
      tester,
      'https://uri.amap.com/marker?position=120.15,30.25&name=第一个地点',
    );
    expect(find.text('第一个地点'), findsOneWidget);
    await deliver(
      tester,
      'https://uri.amap.com/marker?position=121.47,31.23&name=第二个地点',
    );
    expect(find.byType(AndroidMapLinkImport), findsOneWidget);
    expect(find.text('第一个地点'), findsNothing);
    expect(find.text('第二个地点'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(AndroidMapLinkImport), findsNothing);
    expect(find.text('正在持续发送'), findsOneWidget);
    expectNoDeviceCommands();
    expect(tester.takeException(), isNull);
  });

  testWidgets('未同意协议时分享内容保持待处理', (tester) async {
    pending = {'text': '0,0'};
    await open(tester, accepted: false);
    expect(find.byType(AgreementPage), findsOneWidget);
    expect(find.byType(AndroidMapLinkImport), findsNothing);
    expect(calls, isEmpty);
    expect(pending?['text'], '0,0');
  });

  testWidgets('五种地图分享共用预览与确认流程，不需要输入或操作设备', (tester) async {
    pending = null;
    await open(tester);
    final samples = {
      '高德地点': 'https://uri.amap.com/marker?position=120.15,30.25&name=高德地点',
      '腾讯地点': 'https://apis.map.qq.com/uri/v1/marker?marker=coord:30.25,120.15;title:腾讯地点',
      '百度地点':
          'https://api.map.baidu.com/marker?location=30.25,120.15&title=百度地点',
      '苹果地点':
          'https://maps.apple.com/place?coordinate=37.3346,-122.009&name=苹果地点',
      'Google 地点': 'https://www.google.com/maps/place/Google+地点/data=!3d37.3346!4d-122.009',
    };
    for (final sample in samples.entries) {
      await deliver(tester, sample.value);
      expect(find.text(sample.key), findsOneWidget);
      expect(find.byType(AndroidMapLinkImport), findsOneWidget);
      expect(find.text('查看地图'), findsOneWidget);
      expect(find.byType(CupertinoTextField), findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
      expectNoDeviceCommands();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('分享点位经地图确认才填入首页，整个流程不会自动应用', (tester) async {
    pending = {
      'text': 'https://uri.amap.com/marker?position=120.15,30.25&name=确认地点',
    };
    await open(tester);
    await tester.tap(find.text('查看地图'));
    await tester.pumpAndSettle();
    expect(find.byType(AndroidMapPicker), findsOneWidget);
    expect(find.text('导入链接'), findsNothing);
    final map = tester.widget<AndroidMapPicker>(find.byType(AndroidMapPicker));
    expect(map.imported?.place.name, '确认地点');
    final expected = map.imported!.place.point(map.imported!.datum);
    expectNoDeviceCommands();
    await tester.ensureVisible(find.text('选好并填入坐标'));
    await tester.tap(find.text('选好并填入坐标'));
    await tester.pumpAndSettle();
    expect(find.byType(AndroidMapPicker), findsNothing);
    expect(find.text('地图坐标已填入，点击下方按钮应用。'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CupertinoTextField &&
            widget.controller?.text == expected.latitude.toStringAsFixed(6),
      ),
      findsOneWidget,
    );
    expectNoDeviceCommands();
    expect(tester.takeException(), isNull);
  });

  testWidgets('无法解析的分享只显示错误和重试，不调用设备操作', (tester) async {
    pending = {'text': '只有地点名称没有链接'};
    await open(tester);
    expect(find.text('分享内容不包含支持的地图链接'), findsOneWidget);
    expect(find.text('查看地图'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsNothing);
    expectNoDeviceCommands();
    expect(tester.takeException(), isNull);
  });
}
