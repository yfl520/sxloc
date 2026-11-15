import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_info.dart';

enum UpdatePlatform {
  windows('windows', 'windows-x64', 'sxloc-windows-x64.zip'),
  android('android', 'android', 'sxloc-android.apk');

  const UpdatePlatform(this.tagPrefix, this.id, this.fileName);
  final String tagPrefix, id, fileName;
}

class UpdateVersion implements Comparable<UpdateVersion> {
  const UpdateVersion(this.name, this.build);
  final String name;
  final int build;
  static bool valid(String name) => RegExp(r'^\d+\.\d+\.\d+$').hasMatch(name);
  @override
  int compareTo(UpdateVersion other) {
    final a = name.split('.').map(int.parse).toList();
    final b = other.name.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final comparison = a[i].compareTo(b[i]);
      if (comparison != 0) return comparison;
    }
    return build.compareTo(other.build);
  }

  String get label => '$name（$build）';
}

class UpdateFailure implements Exception {
  const UpdateFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class UpdatePackage {
  const UpdatePackage({
    required this.version,
    required this.platform,
    required this.url,
    required this.sha256Hex,
    required this.size,
    required this.notes,
  });
  final UpdateVersion version;
  final UpdatePlatform platform;
  final Uri url;
  final String sha256Hex, notes;
  final int size;

  static Map<String, dynamic>? candidate(
    List<dynamic> releases,
    UpdatePlatform platform,
    UpdateVersion current,
  ) {
    final pattern = RegExp(
      '^${platform.tagPrefix}-v(\\d+\\.\\d+\\.\\d+)\\+(\\d+)\$',
    );
    Map<String, dynamic>? selected;
    var selectedVersion = current;
    for (final item in releases) {
      if (item is! Map ||
          item['draft'] != false ||
          item['prerelease'] != false) {
        continue;
      }
      final match = pattern.firstMatch(item['tag_name']?.toString() ?? '');
      if (match == null) continue;
      final version = UpdateVersion(match[1]!, int.parse(match[2]!));
      if (version.compareTo(selectedVersion) > 0) {
        selected = Map<String, dynamic>.from(item);
        selectedVersion = version;
      }
    }
    return selected;
  }

  static Map<String, dynamic> asset(Map<String, dynamic> release, String name) {
    final assets = release['assets'];
    final matches = assets is List
        ? assets
              .whereType<Map>()
              .where((a) => a['name'] == name && a['state'] == 'uploaded')
              .toList()
        : <Map>[];
    if (matches.length != 1) throw const UpdateFailure('此版本的更新文件尚未准备完整，请稍后重试。');
    return Map<String, dynamic>.from(matches.single);
  }

  static Uri assetUrl(
    Map<String, dynamic> release,
    Map<String, dynamic> asset,
    String repo,
  ) {
    final uri = Uri.tryParse(asset['browser_download_url']?.toString() ?? '');
    final repository = Uri.parse(repo).pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    final tag = release['tag_name']?.toString();
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasQuery ||
        uri.hasFragment ||
        !listEquals(uri.pathSegments, [
          ...repository,
          'releases',
          'download',
          tag,
          asset['name'],
        ])) {
      throw const UpdateFailure('更新文件地址不属于当前项目，已停止下载。');
    }
    return uri;
  }

  factory UpdatePackage.fromManifest(
    Map<String, dynamic> manifest,
    Map<String, dynamic> release,
    UpdatePlatform platform,
    String repo,
  ) {
    final version = manifest['version'];
    final build = manifest['buildNumber'];
    final size = manifest['size'];
    final hash = manifest['sha256'];
    final maxSize = platform == UpdatePlatform.android
        ? 512 * 1024 * 1024
        : 2 * 1024 * 1024 * 1024;
    if (manifest['schemaVersion'] != 1 ||
        manifest['platform'] != platform.id ||
        version is! String ||
        !UpdateVersion.valid(version) ||
        build is! int ||
        build <= 0 ||
        manifest['fileName'] != platform.fileName ||
        size is! int ||
        size <= 0 ||
        size > maxSize ||
        hash is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash) ||
        release['tag_name'] != '${platform.tagPrefix}-v$version+$build') {
      throw const UpdateFailure('更新说明不完整或版本不匹配，已停止更新。');
    }
    final packageAsset = asset(release, platform.fileName);
    if (packageAsset['size'] != size ||
        (packageAsset['digest'] != null &&
            packageAsset['digest'] != 'sha256:${hash.toLowerCase()}')) {
      throw const UpdateFailure('更新文件的校验信息不一致，已停止更新。');
    }
    final body = release['body']?.toString() ?? '';
    return UpdatePackage(
      version: UpdateVersion(version, build),
      platform: platform,
      url: assetUrl(release, packageAsset, repo),
      sha256Hex: hash.toLowerCase(),
      size: size,
      notes: body.length > 12000 ? '${body.substring(0, 12000)}…' : body,
    );
  }
}

abstract class UpdateNetwork {
  Future<Uint8List> read(Uri uri, int limit);
  Future<void> download(
    Uri uri,
    File destination,
    int size,
    void Function(int) progress,
  );
  void close();
}

class GitHubUpdateNetwork implements UpdateNetwork {
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  static bool allowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      (uri.host == 'api.github.com' ||
          uri.host == 'github.com' ||
          uri.host.endsWith('.githubusercontent.com'));

  Future<HttpClientResponse> _response(Uri uri) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      if (!allowed(uri)) throw const UpdateFailure('更新服务返回了不受支持的下载地址。');
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'sxloc-updater');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(
        HttpHeaders.acceptHeader,
        uri.host == 'api.github.com' ? 'application/vnd.github+json' : '*/*',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(const Duration(seconds: 20));
        if (location == null) break;
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode == 200) return response;
      final code = response.statusCode;
      await response.drain<void>().timeout(const Duration(seconds: 20));
      if (code == 403 || code == 429) {
        throw const UpdateFailure('GitHub 暂时限制了请求次数，请稍后重试。');
      }
      if (code == 404) throw const UpdateFailure('此更新暂时不可用，请稍后重新检查。');
      throw UpdateFailure('更新服务暂时不可用（$code），请稍后重试。');
    }
    throw const UpdateFailure('更新下载重定向次数过多，请稍后重试。');
  }

  @override
  Future<Uint8List> read(Uri uri, int limit) async {
    final response = await _response(uri);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > limit) {
        throw const UpdateFailure('更新说明超出大小限制。');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @override
  Future<void> download(
    Uri uri,
    File destination,
    int size,
    void Function(int) progress,
  ) async {
    final response = await _response(uri);
    if (response.contentLength >= 0 && response.contentLength != size) {
      throw const UpdateFailure('更新文件大小不匹配，请重新检查更新。');
    }
    final sink = destination.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        received += chunk.length;
        if (received > size) throw const UpdateFailure('更新文件大小超出预期，已停止下载。');
        sink.add(chunk);
        await sink.flush();
        progress(received);
      }
    } finally {
      await sink.close();
    }
    if (received != size) throw const UpdateFailure('下载不完整，请重试。');
  }

  @override
  void close() => _client.close(force: true);
}

enum UpdateStage {
  idle,
  checking,
  available,
  downloading,
  ready,
  installing,
  current,
  none,
  error,
}

class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required this.platform,
    required this.current,
    required this.directory,
    required this.install,
    this.repository = AppInfo.projectGithub,
    UpdateNetwork Function()? networkFactory,
  }) : networkFactory = networkFactory ?? GitHubUpdateNetwork.new;
  final UpdatePlatform platform;
  final UpdateVersion current;
  final String repository;
  final Future<String> Function() directory;
  final Future<String> Function(File, UpdatePackage) install;
  final UpdateNetwork Function() networkFactory;
  UpdateStage stage = UpdateStage.idle;
  UpdatePackage? package;
  File? downloaded;
  String message = '手动检查 GitHub 上的正式版本。';
  int received = 0;
  int _generation = 0;
  bool _disposed = false;
  UpdateNetwork? _network;
  bool get busy => [
    UpdateStage.checking,
    UpdateStage.downloading,
    UpdateStage.installing,
  ].contains(stage);
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> check() async {
    if (busy || _disposed) return;
    final generation = ++_generation;
    stage = UpdateStage.checking;
    message = '正在检查更新…';
    package = null;
    downloaded = null;
    received = 0;
    _changed();
    final network = _network = networkFactory();
    try {
      if (!AppInfo.isGithubRepository(repository)) {
        throw const UpdateFailure('项目仓库地址尚未配置。');
      }
      final path = Uri.parse(repository).path;
      final releases = <dynamic>[];
      for (var page = 1; page <= 5; page++) {
        final bytes = await network.read(
          Uri.parse(
            'https://api.github.com/repos$path/releases?per_page=100&page=$page',
          ),
          2 * 1024 * 1024,
        );
        final list = jsonDecode(utf8.decode(bytes));
        if (list is! List) throw const UpdateFailure('无法读取版本列表。');
        releases.addAll(list);
        if (list.length < 100) break;
      }
      if (_disposed || generation != _generation) return;
      final release = UpdatePackage.candidate(releases, platform, current);
      if (release == null) {
        final any = releases.whereType<Map>().any(
          (r) =>
              r['draft'] == false &&
              r['prerelease'] == false &&
              (r['tag_name']?.toString() ?? '').startsWith(
                '${platform.tagPrefix}-v',
              ),
        );
        stage = any ? UpdateStage.current : UpdateStage.none;
        message = any ? '当前已是最新正式版本。' : '暂未发布此平台的正式更新，当前版本可继续使用。';
      } else {
        final manifestAsset = UpdatePackage.asset(release, 'sxloc-update.json');
        final url = UpdatePackage.assetUrl(release, manifestAsset, repository);
        final value = jsonDecode(
          utf8.decode(await network.read(url, 64 * 1024)),
        );
        if (value is! Map) throw const UpdateFailure('无法读取更新说明。');
        final update = UpdatePackage.fromManifest(
          Map<String, dynamic>.from(value),
          release,
          platform,
          repository,
        );
        if (_disposed || generation != _generation) return;
        package = update;
        stage = UpdateStage.available;
        message = '发现新版本 ${update.version.label}';
      }
    } catch (error) {
      if (!_disposed && generation == _generation) {
        stage = UpdateStage.error;
        message = _error(error);
      }
    } finally {
      network.close();
      if (identical(_network, network)) _network = null;
      _changed();
    }
  }

  Future<void> download() async {
    final update = package;
    if (busy || _disposed || update == null) return;
    final generation = ++_generation;
    final network = _network = networkFactory();
    File? partial;
    stage = UpdateStage.downloading;
    received = 0;
    message = '正在下载更新…';
    _changed();
    try {
      final root = await directory();
      if (_disposed || generation != _generation) return;
      final folder = await Directory(
        p.join(root, 'download-${DateTime.now().microsecondsSinceEpoch}'),
      ).create(recursive: true);
      partial = File(p.join(folder.path, '${platform.fileName}.part'));
      if (_disposed || generation != _generation) return;
      await network.download(update.url, partial, update.size, (value) {
        if (_disposed || generation != _generation) return;
        received = value;
        _changed();
      });
      final hash = (await sha256.bind(partial.openRead()).first).toString();
      if (hash != update.sha256Hex) {
        throw const UpdateFailure('更新文件校验失败，请重新下载。');
      }
      if (_disposed || generation != _generation) return;
      downloaded = await partial.rename(p.join(folder.path, platform.fileName));
      stage = UpdateStage.ready;
      message = '下载完成，校验通过。';
    } catch (error) {
      if (!_disposed && generation == _generation) {
        stage = UpdateStage.error;
        message = _error(error);
      }
    } finally {
      network.close();
      if (identical(_network, network)) _network = null;
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } on FileSystemException {
        // A locked partial file remains in the update cache and is never installed.
      }
      _changed();
    }
  }

  Future<void> installDownloaded() async {
    if (busy || _disposed || downloaded == null || package == null) return;
    stage = UpdateStage.installing;
    message = '正在准备安装…';
    _changed();
    try {
      final status = await install(downloaded!, package!);
      if (_disposed) return;
      stage = UpdateStage.ready;
      message = status == 'permission'
          ? '请允许安装此来源的应用，返回后点击“安装更新”。'
          : '已打开系统安装界面，请按提示完成更新。';
    } catch (error) {
      if (_disposed) return;
      stage = UpdateStage.ready;
      message = error is UpdateFailure ? error.message : '安装准备失败：$error';
    }
    _changed();
  }

  void cancel() {
    if (stage == UpdateStage.installing) return;
    ++_generation;
    _network?.close();
    _network = null;
    stage = package == null ? UpdateStage.idle : UpdateStage.available;
    message = '已取消，可稍后重试。';
    _changed();
  }

  String _error(Object error) => error is UpdateFailure
      ? error.message
      : error is FileSystemException
      ? '无法保存更新文件，请检查存储空间与目录权限。'
      : '无法连接更新服务，请检查网络后重试。';

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _network?.close();
    super.dispose();
  }
}
