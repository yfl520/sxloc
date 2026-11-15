import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
// Exercise the Android settings page's explicit SDK-field compatibility path.
// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart' as sdk;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart' as sdk_l10n;
import 'package:flutter_test/flutter_test.dart';
import 'package:suixing_loc/android_place_search.dart';
import 'package:suixing_loc/android_search_settings.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final keyField = find.byKey(const ValueKey('amap-key-input'));
  final cityField = find.byKey(const ValueKey('search-city-input'));

  Future<void> openSettings(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      CupertinoApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: const [
          ...GlobalCupertinoLocalizations.delegates,
          // ignore: deprecated_member_use
          sdk_l10n.GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => CupertinoPageScaffold(
            child: Center(
              child: CupertinoButton(
                onPressed: () => Navigator.push(
                  context,
                  CupertinoPageRoute<void>(
                    builder: (_) => const AndroidSearchSettings(
                      options: PlaceSearchOptions(),
                    ),
                  ),
                ),
                child: const Text('打开搜索设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开搜索设置'));
    await tester.pumpAndSettle();
  }

  void mockEditor(Future<Object?> Function(MethodCall) handler) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      androidSearchControl,
      handler,
    );
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        androidSearchControl,
        null,
      ),
    );
  }

  testWidgets(
    'direct field taps use native editor without creating a Flutter input client',
    (tester) async {
      final fields = <String>[];
      final values = <String>[];
      mockEditor((call) async {
        if (call.method == 'mapSearch.edit') {
          final args = call.arguments as Map;
          fields.add(args['field'] as String);
          values.add(args['value'] as String);
          return args['field'] == 'key' ? 'fixture-value' : '上海';
        }
        return null;
      });
      await openSettings(tester);
      for (final field in [keyField, cityField, cityField]) {
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        // A real native edit takes longer than the text field's double-tap
        // interval; its completion is immediate only in this channel mock.
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.testTextInput.isVisible, isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        expect(
          tester.widget<sdk.CupertinoTextField>(field).focusNode!.hasFocus,
          isFalse,
        );
      }
      expect(fields, ['key', 'city', 'city']);
      expect(values, ['', '', '上海']);
      expect(
        tester.widget<sdk.CupertinoTextField>(cityField).controller!.text,
        '上海',
      );
      await tester.ensureVisible(find.text('显示'));
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<sdk.CupertinoTextField>(keyField).obscureText,
        isFalse,
      );
      expect(
        tester.widget<sdk.CupertinoTextField>(keyField).controller!.text,
        'fixture-value',
      );
      expect(fields.length, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('save failure retains draft and permits another direct edit', (
    tester,
  ) async {
    var edits = 0;
    mockEditor((call) async {
      if (call.method == 'mapSearch.edit') {
        edits++;
        return '杭州';
      }
      if (call.method == 'mapSearch.save') {
        throw PlatformException(code: 'TEST', message: '测试保存失败');
      }
      return null;
    });
    await openSettings(tester);
    await tester.ensureVisible(cityField);
    await tester.tap(cityField);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.text('测试保存失败'), findsOneWidget);
    await tester.ensureVisible(cityField);
    await tester.tap(cityField);
    await tester.pumpAndSettle();
    expect(edits, 2);
    expect(
      tester.widget<sdk.CupertinoTextField>(cityField).controller!.text,
      '杭州',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'IME inset changes do not attach Flutter input or open duplicate native editors',
    (tester) async {
      final pending = Completer<String?>();
      var opens = 0;
      mockEditor((call) async {
        if (call.method == 'mapSearch.edit') {
          opens++;
          return pending.future;
        }
        return null;
      });
      await openSettings(tester);
      addTearDown(tester.view.resetViewInsets);
      await tester.ensureVisible(cityField);
      await tester.tap(cityField);
      await tester.pumpAndSettle();
      await tester.tap(cityField);
      await tester.pumpAndSettle();
      for (final bottom in [4.0, 336.0, 4.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(
          bottom: bottom * tester.view.devicePixelRatio,
        );
        await tester.pumpAndSettle();
        expect(tester.testTextInput.hasAnyClients, isFalse);
        expect(
          tester.widget<sdk.CupertinoTextField>(cityField).focusNode!.hasFocus,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      }
      expect(opens, 1);
      pending.complete('上海');
      await tester.pumpAndSettle();
      expect(
        tester.widget<sdk.CupertinoTextField>(cityField).controller!.text,
        '上海',
      );
    },
  );
  testWidgets('native compatibility edits return to the unsaved form', (
    tester,
  ) async {
    Map<Object?, Object?>? saved;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      androidSearchControl,
      (call) async {
        if (call.method == 'mapSearch.edit') {
          final args = call.arguments as Map;
          return args['field'] == 'key' ? 'a' * 32 : '上海';
        }
        if (call.method == 'mapSearch.save') saved = call.arguments as Map;
        return null;
      },
    );
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        androidSearchControl,
        null,
      ),
    );
    await openSettings(tester);
    for (final field in ['key', 'city']) {
      final compat = find.byKey(ValueKey('compat-$field'));
      await tester.ensureVisible(compat);
      await tester.tap(compat);
      await tester.pumpAndSettle();
    }
    expect(
      saved,
      isNull,
    ); // Filling the form must not save or apply a location.
    expect(
      tester.widget<sdk.CupertinoTextField>(keyField).controller!.text,
      'a' * 32,
    );
    expect(
      tester.widget<sdk.CupertinoTextField>(cityField).controller!.text,
      '上海',
    );
    await tester.ensureVisible(find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(saved?['key'], 'a' * 32);
    expect(saved?['city'], '上海');
    expect(tester.takeException(), isNull);
  });

  testWidgets('native cancel or failure retains draft without diagnostic UI', (
    tester,
  ) async {
    var fail = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      androidSearchControl,
      (call) async {
        if (call.method == 'mapSearch.edit' && fail) {
          throw PlatformException(
            code: 'TEST',
            message: 'sensitive-platform-detail',
          );
        }
        return null;
      },
    );
    addTearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        androidSearchControl,
        null,
      );
    });
    await openSettings(tester);
    tester.widget<sdk.CupertinoTextField>(keyField).controller!.text =
        'private-fixture-key';
    tester.widget<sdk.CupertinoTextField>(cityField).controller!.text =
        'private-fixture-city';
    for (final shouldFail in [false, true]) {
      fail = shouldFail;
      await tester.ensureVisible(find.byKey(const ValueKey('compat-key')));
      await tester.tap(find.byKey(const ValueKey('compat-key')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<sdk.CupertinoTextField>(keyField).controller!.text,
        'private-fixture-key',
      );
      expect(
        tester.widget<sdk.CupertinoTextField>(cityField).controller!.text,
        'private-fixture-city',
      );
    }
    expect(find.textContaining('诊断'), findsNothing);
    expect(find.textContaining('无需发给我'), findsNothing);
    expect(find.textContaining('sensitive-platform-detail'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
