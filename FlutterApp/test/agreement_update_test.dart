import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suixing_loc/app_updates.dart';
import 'package:suixing_loc/service_agreement.dart';

class MemoryAgreement implements AgreementStore {
  MemoryAgreement({this.accepted = false, this.fail = false});
  bool accepted, fail;
  int writes = 0;
  @override
  Future<bool> isAccepted() async => accepted;
  @override
  Future<void> accept() async {
    writes++;
    if (fail) throw const FileSystemException('no space');
    accepted = true;
  }
}

class FakeUpdateNetwork implements UpdateNetwork {
  final bytes = Uint8List.fromList(utf8.encode('test package bytes'));
  bool corrupt = false;
  int reads = 0;
  List<dynamic> releases = [];
  Map<String, dynamic> manifest = {};
  Completer<Uint8List>? delayed;
  @override
  Future<Uint8List> read(Uri uri, int limit) async {
    reads++;
    if (delayed != null) return delayed!.future;
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(uri.host == 'api.github.com' ? releases : manifest),
      ),
    );
  }

  @override
  Future<void> download(
    Uri uri,
    File destination,
    int size,
    void Function(int) progress,
  ) async {
    await destination.writeAsBytes(corrupt ? [1, 2] : bytes);
    progress(bytes.length);
  }

  @override
  void close() {}

  void prepare() {
    const tag = 'android-v1.2.9+16';
    Map<String, Object> asset(String name, int size) => {
      'name': name,
      'state': 'uploaded',
      'size': size,
      'browser_download_url':
          'https://github.com/yfl520/sxloc/releases/download/$tag/$name',
    };
    releases = [
      {
        'tag_name': tag,
        'draft': false,
        'prerelease': false,
        'body': '修复与改进',
        'assets': [
          asset('sxloc-update.json', 400),
          asset('sxloc-android.apk', bytes.length),
        ],
      },
    ];
    manifest = {
      'schemaVersion': 1,
      'platform': 'android',
      'version': '1.2.9',
      'buildNumber': 16,
      'fileName': 'sxloc-android.apk',
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => rootBundle.evict('assets/service_agreement.md'));
  testWidgets(
    'agreement prevents feature construction until checked and saved',
    (tester) async {
      final store = MemoryAgreement();
      var builds = 0, exits = 0;
      await tester.pumpWidget(
        CupertinoApp(
          home: AgreementGate(
            store: store,
            onDecline: () async {
              exits++;
            },
            builder: (_) {
              builds++;
              return const Text('features');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(builds, 0);
      expect(
        tester
            .widget<CupertinoButton>(
              find.widgetWithText(CupertinoButton, '同意并继续'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('不同意并退出'));
      expect(exits, 1);
      expect(builds, 0);
      await tester.tap(find.text('我已阅读并同意使用协议、免责声明与隐私告知'));
      await tester.pump();
      await tester.tap(find.text('同意并继续'));
      await tester.pumpAndSettle();
      expect(store.writes, 1);
      expect(builds, 1);
      expect(find.text('features'), findsOneWidget);
    },
  );

  testWidgets('failed consent write keeps gate closed', (tester) async {
    final store = MemoryAgreement(fail: true);
    await tester.pumpWidget(
      CupertinoApp(
        home: AgreementGate(
          store: store,
          onDecline: () async {},
          builder: (_) => const Text('features'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已阅读并同意使用协议、免责声明与隐私告知'));
    await tester.pump();
    await tester.tap(find.text('同意并继续'));
    await tester.pumpAndSettle();
    expect(find.text('features'), findsNothing);
    expect(find.textContaining('同意记录保存失败'), findsOneWidget);
    expect(store.accepted, isFalse);
  });

  testWidgets('saved current agreement enters features without rewriting', (
    tester,
  ) async {
    final store = MemoryAgreement(accepted: true);
    await tester.pumpWidget(
      CupertinoApp(
        home: AgreementGate(
          store: store,
          onDecline: () async {},
          builder: (_) => const Text('features'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('features'), findsOneWidget);
    expect(store.writes, 0);
  });

  test('versions compare semantically, including build and platform tags', () {
    expect(
      const UpdateVersion(
        '1.10.0',
        1,
      ).compareTo(const UpdateVersion('1.9.9', 99)),
      greaterThan(0),
    );
    final releases = [
      {'tag_name': 'android-v1.2.9+16', 'draft': false, 'prerelease': false},
      {'tag_name': 'windows-v9.0.0+100', 'draft': false, 'prerelease': false},
      {'tag_name': 'android-v9.0.0+100', 'draft': false, 'prerelease': true},
      {'tag_name': 'android-v8.0.0+90', 'draft': true, 'prerelease': false},
      {'tag_name': 'android-v1.2.8+15', 'draft': false, 'prerelease': false},
    ];
    expect(
      UpdatePackage.candidate(
        releases,
        UpdatePlatform.android,
        const UpdateVersion('1.2.8', 15),
      )?['tag_name'],
      'android-v1.2.9+16',
    );
    expect(
      UpdatePackage.candidate(
        releases,
        UpdatePlatform.android,
        const UpdateVersion('1.2.9', 16),
      ),
      isNull,
    );
  });

  test('manifest rejects foreign URL, mismatched tag, hash and size', () {
    final network = FakeUpdateNetwork()..prepare();
    final release = Map<String, dynamic>.from(network.releases.single as Map);
    expect(
      UpdatePackage.fromManifest(
        network.manifest,
        release,
        UpdatePlatform.android,
        'https://github.com/yfl520/sxloc',
      ).version.build,
      16,
    );
    for (final override in [
      {'platform': 'windows-x64'},
      {'size': 999},
      {'sha256': ''},
      {'version': '1.2.10'},
      {'fileName': '../bad.apk'},
      {'buildNumber': -1},
    ]) {
      expect(
        () => UpdatePackage.fromManifest(
          {...network.manifest, ...override},
          release,
          UpdatePlatform.android,
          'https://github.com/yfl520/sxloc',
        ),
        throwsA(isA<UpdateFailure>()),
      );
    }
    final asset = Map<String, dynamic>.from(
      (release['assets'] as List).last as Map,
    );
    for (final url in [
      'https://github.com/other/repo/releases/download/android-v1.2.9+16/sxloc-android.apk',
      'http://github.com/yfl520/sxloc/releases/download/android-v1.2.9+16/sxloc-android.apk',
      'https://example.com/update.apk',
    ]) {
      expect(
        () => UpdatePackage.assetUrl(release, {
          ...asset,
          'browser_download_url': url,
        }, 'https://github.com/yfl520/sxloc'),
        throwsA(isA<UpdateFailure>()),
      );
    }
  });

  test(
    'download requires explicit action and verification before installation',
    () async {
      final root = await Directory.systemTemp.createTemp('sxloc-update-test-');
      addTearDown(() => root.delete(recursive: true));
      final network = FakeUpdateNetwork()..prepare();
      var installs = 0;
      final updater = AppUpdateController(
        platform: UpdatePlatform.android,
        current: const UpdateVersion('1.2.8', 15),
        networkFactory: () => network,
        directory: () async => root.path,
        install: (_, _) async {
          installs++;
          return 'installer';
        },
      );
      addTearDown(updater.dispose);
      expect(network.reads, 0);
      await updater.check();
      expect(updater.stage, UpdateStage.available);
      expect(installs, 0);
      await updater.installDownloaded();
      expect(installs, 0);
      network.corrupt = true;
      await updater.download();
      expect(updater.stage, UpdateStage.error);
      expect(updater.downloaded, isNull);
      await updater.installDownloaded();
      expect(installs, 0);
      network.corrupt = false;
      await updater.download();
      expect(updater.stage, UpdateStage.ready);
      expect(await updater.downloaded!.readAsBytes(), network.bytes);
      await updater.installDownloaded();
      expect(installs, 1);
    },
  );

  test(
    'empty releases are handled and cancelled stale response cannot win',
    () async {
      final network = FakeUpdateNetwork();
      final updater = AppUpdateController(
        platform: UpdatePlatform.android,
        current: const UpdateVersion('1.2.8', 15),
        networkFactory: () => network,
        directory: () async => '',
        install: (_, _) async => 'installer',
      );
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.stage, UpdateStage.none);
      network.delayed = Completer<Uint8List>();
      final checking = updater.check();
      await Future<void>.delayed(Duration.zero);
      updater.cancel();
      network.delayed!.complete(Uint8List.fromList(utf8.encode('[]')));
      await checking;
      expect(updater.stage, UpdateStage.idle);
      expect(updater.message, contains('已取消'));
    },
  );
}
