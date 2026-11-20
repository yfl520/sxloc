import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_localizations/flutter_localizations.dart' as sdk;
import 'package:flutter_test/flutter_test.dart';
import 'package:suixing_loc/android_map_link.dart';
import 'package:suixing_loc/android_map_link_import.dart';

void main() {
  Future<void> open(
    WidgetTester tester, {
    String text = 'https://maps.apple.com/?ll=37.3346,-122.009&q=Apple+Park',
    AndroidMapLink? resolver,
    ValueChanged<MapLinkSelection?>? onReturn,
    bool settle = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      CupertinoApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: const [
          ...GlobalCupertinoLocalizations.delegates,
          // ignore: deprecated_member_use
          sdk.GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => CupertinoPageScaffold(
            child: Center(
              child: CupertinoButton(
                onPressed: () async {
                  final result = await Navigator.of(context)
                      .push<MapLinkSelection>(
                        CupertinoPageRoute(
                          builder: (_) => AndroidMapLinkImport(
                            initialText: text,
                            resolver: resolver,
                          ),
                        ),
                      );
                  onReturn?.call(result);
                },
                child: const Text('打开分享'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开分享'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  testWidgets('直接显示分享地点，无输入和粘贴，确认前不返回坐标', (tester) async {
    MapLinkSelection? returned;
    await open(tester, onReturn: (value) => returned = value);
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(find.text('从剪贴板粘贴'), findsNothing);
    expect(find.text('解析位置'), findsNothing);
    expect(find.text('Apple Park'), findsOneWidget);
    expect(find.text('37.334600, -122.009000'), findsOneWidget);
    expect(returned, isNull);
    await tester.tap(find.text('查看地图'));
    await tester.pumpAndSettle();
    expect(returned?.place.name, 'Apple Park');
    expect(tester.takeException(), isNull);
  });

  testWidgets('解析失败可以重试原分享，不需要输入或剪贴板', (tester) async {
    final resolver = _RetryResolver();
    await open(tester, resolver: resolver);
    expect(find.text('地图分享页暂时无法访问'), findsOneWidget);
    expect(find.text('查看地图'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(resolver.inputs.length, 2);
    expect(resolver.inputs[0], resolver.inputs[1]);
    expect(find.text('Apple Park'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消后忽略迟到结果', (tester) async {
    final resolver = _DelayedResolver();
    MapLinkSelection? returned;
    await open(
      tester,
      resolver: resolver,
      settle: false,
      onReturn: (value) => returned = value,
    );
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    resolver.result.complete(AndroidMapLink.parse('0,0'));
    await tester.pumpAndSettle();
    expect(returned, isNull);
    expect(find.byType(AndroidMapLinkImport), findsNothing);
    expect(find.text('打开分享'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('坐标系默认折叠，展开仍能调整并返回所选坐标系', (tester) async {
    MapLinkSelection? returned;
    await open(
      tester,
      text: 'https://uri.amap.com/marker?position=120.15,30.25&name=公园',
      onReturn: (value) => returned = value,
    );
    expect(find.text('WGS-84'), findsNothing);
    await tester.tap(find.text('坐标系'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WGS-84'));
    await tester.pumpAndSettle();
    expect(find.text('30.250000, 120.150000'), findsOneWidget);
    await tester.tap(find.text('查看地图'));
    await tester.pumpAndSettle();
    expect(returned?.datum, MapLinkDatum.wgs84);
    expect(tester.takeException(), isNull);
  });
}

class _DelayedResolver extends AndroidMapLink {
  final result = Completer<MapLinkPlace>();
  @override
  Future<MapLinkPlace> resolve(String input) => result.future;
}

class _RetryResolver extends AndroidMapLink {
  final inputs = <String>[];
  @override
  Future<MapLinkPlace> resolve(String input) async {
    inputs.add(input);
    if (inputs.length == 1) throw const MapLinkException('地图分享页暂时无法访问');
    return AndroidMapLink.parse(input)!;
  }
}
