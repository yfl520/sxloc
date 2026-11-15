import 'dart:io';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'app_info.dart';
import 'app_updates.dart';
import 'core_client.dart';

const _control = MethodChannel('suixing/android/control');

AppUpdateController androidUpdates() => AppUpdateController(
  platform: UpdatePlatform.android,
  current: const UpdateVersion(
    AppInfo.androidVersionName,
    AppInfo.androidBuild,
  ),
  directory: () async =>
      (await _control.invokeMethod<String>('update.directory'))!,
  install: (file, package) async {
    try {
      return (await _control.invokeMethod<String>('update.install', {
        'path': file.path,
        'sha256': package.sha256Hex,
        'version': package.version.name,
        'buildNumber': package.version.build,
      }))!;
    } on PlatformException catch (error) {
      throw UpdateFailure(error.message ?? '无法打开系统安装界面，请重试。');
    }
  },
);

AppUpdateController desktopUpdates(CoreClient core) => AppUpdateController(
  platform: UpdatePlatform.windows,
  current: const UpdateVersion(
    AppInfo.desktopVersionName,
    AppInfo.desktopBuild,
  ),
  directory: () async => (await core.call('update.directory')).toString(),
  install: (file, package) async {
    await core.call('update.install', {
      'path': file.path,
      'sha256': package.sha256Hex,
      'appPid': pid,
      'version': package.version.name,
      'buildNumber': package.version.build,
    }, const Duration(minutes: 4));
    await core.close();
    await windowManager.destroy();
    exit(0);
  },
);
