import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'local_app_store.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.tag,
    required this.name,
    required this.releaseUrl,
    required this.apkUrl,
    required this.notes,
    required this.isPrerelease,
  });

  final String tag;
  final String name;
  final String releaseUrl;
  final String apkUrl;
  final String notes;
  final bool isPrerelease;
}

class AppUpdateDownloadProgress {
  const AppUpdateDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int? totalBytes;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (receivedBytes / total).clamp(0.0, 1.0).toDouble();
  }
}

class AppUpdateCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class AppUpdateCancelledException implements Exception {
  const AppUpdateCancelledException();

  @override
  String toString() => '更新下载已取消。';
}

enum AppUpdateSource { github, githubMirror }

extension AppUpdateSourceDetails on AppUpdateSource {
  String get title => switch (this) {
    AppUpdateSource.github => 'GitHub 官方',
    AppUpdateSource.githubMirror => 'GitHub 镜像站',
  };

  String get subtitle => switch (this) {
    AppUpdateSource.github => '直接从 GitHub Releases 检查并下载。',
    AppUpdateSource.githubMirror => '通过 gh-proxy.com 代理 GitHub 发行版和 APK 下载。',
  };

  Uri releaseEndpoint(String repository) {
    final official =
        'https://api.github.com/repos/$repository/releases?per_page=40';
    return switch (this) {
      AppUpdateSource.github => Uri.parse(official),
      AppUpdateSource.githubMirror => Uri.parse(
        'https://gh-proxy.com/$official',
      ),
    };
  }

  String downloadUrl(String officialUrl) => switch (this) {
    AppUpdateSource.github => officialUrl,
    AppUpdateSource.githubMirror => 'https://gh-proxy.com/$officialUrl',
  };
}

class AppUpdateService {
  AppUpdateService._();

  static const currentReleaseTag = '2.2Alpha4';
  static const _repository = 'Ranlin114514/band-novel-reader';
  static const _timeout = Duration(seconds: 20);
  static const _maximumApkBytes = 250 * 1024 * 1024;

  static Future<AppUpdateInfo?> checkForUpdate({
    String currentTag = currentReleaseTag,
    AppUpdateSource source = AppUpdateSource.github,
    Uri? endpoint,
  }) async {
    final client = http.Client();
    try {
      final response = await client
          .get(
            endpoint ?? source.releaseEndpoint(_repository),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'BandNovelReader/2.2 (Android; update-check)',
            },
          )
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw FormatException('更新检查返回 HTTP ${response.statusCode}。');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        throw const FormatException('更新服务返回格式异常。');
      }
      final current = _versionValue(currentTag);
      AppUpdateInfo? latest;
      for (final item in decoded) {
        if (item is! Map || item['draft'] == true) {
          continue;
        }
        final tag = item['tag_name'] as String?;
        if (tag == null || _versionValue(tag) <= current) {
          continue;
        }
        final assets = item['assets'];
        if (assets is! List) {
          continue;
        }
        Map? apk;
        for (final asset in assets) {
          if (asset is Map && asset['name'] == 'band-novel-reader.apk') {
            apk = asset;
            break;
          }
        }
        final apkUrl = apk?['browser_download_url'] as String?;
        if (apkUrl == null || apkUrl.isEmpty) {
          continue;
        }
        final candidate = AppUpdateInfo(
          tag: tag,
          name: (item['name'] as String?)?.trim().isEmpty ?? true
              ? tag
              : (item['name'] as String).trim(),
          releaseUrl: item['html_url'] as String? ?? '',
          apkUrl: source.downloadUrl(apkUrl),
          notes: (item['body'] as String? ?? '').trim(),
          isPrerelease: item['prerelease'] == true,
        );
        if (latest == null ||
            _versionValue(candidate.tag) > _versionValue(latest.tag)) {
          latest = candidate;
        }
      }
      return latest;
    } on SocketException {
      throw const FormatException('无法连接更新服务，请检查网络后重试。');
    } on HttpException {
      throw const FormatException('更新服务连接异常，请稍后重试。');
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('检查更新超时或响应异常，请稍后重试。');
    } finally {
      client.close();
    }
  }

  static Future<bool> shouldPrompt(
    AppUpdateInfo update, {
    required int appLaunchCount,
  }) async {
    final deferred = await LocalAppStore.instance.loadUpdateDeferral();
    if (deferred == null || deferred.tag != update.tag) {
      return true;
    }
    return appLaunchCount >= deferred.nextPromptLaunch;
  }

  static Future<void> defer(
    AppUpdateInfo update, {
    required int appLaunchCount,
  }) async {
    final previous = await LocalAppStore.instance.loadUpdateDeferral();
    final deferCount = previous?.tag == update.tag
        ? previous!.deferCount + 1
        : 1;
    await LocalAppStore.instance.saveUpdateDeferral(
      tag: update.tag,
      deferCount: deferCount,
      nextPromptLaunch: appLaunchCount + (deferCount * 5),
    );
  }

  static Future<void> clearDeferred() {
    return LocalAppStore.instance.clearDeferredUpdateTag();
  }

  static Future<File> downloadApk({
    required AppUpdateInfo update,
    required void Function(AppUpdateDownloadProgress progress) onProgress,
    AppUpdateCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled == true) {
      throw const AppUpdateCancelledException();
    }
    final client = http.Client();
    File? target;
    try {
      final request = http.Request('GET', Uri.parse(update.apkUrl))
        ..headers.addAll(const {
          'Accept': 'application/vnd.android.package-archive, application/octet-stream;q=0.9',
          'User-Agent': 'BandNovelReader/2.2 (Android; update-download)',
        });
      final response = await client.send(request).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException('更新下载返回 HTTP ${response.statusCode}。');
      }
      final expectedLength = response.contentLength;
      if (expectedLength != null && expectedLength > _maximumApkBytes) {
        throw const FormatException('更新包超过 250 MB 安全上限，已停止下载。');
      }
      final directory = await getTemporaryDirectory();
      target = File('${directory.path}/band-novel-reader-update.apk');
      if (await target.exists()) {
        await target.delete();
      }
      final sink = target.openWrite(mode: FileMode.writeOnly);
      var receivedBytes = 0;
      onProgress(
        AppUpdateDownloadProgress(receivedBytes: 0, totalBytes: expectedLength),
      );
      try {
        await for (final chunk in response.stream.timeout(_timeout)) {
          if (cancellationToken?.isCancelled == true) {
            throw const AppUpdateCancelledException();
          }
          receivedBytes += chunk.length;
          if (receivedBytes > _maximumApkBytes) {
            throw const FormatException('更新包超过 250 MB 安全上限，已停止下载。');
          }
          sink.add(chunk);
          onProgress(
            AppUpdateDownloadProgress(
              receivedBytes: receivedBytes,
              totalBytes: expectedLength,
            ),
          );
        }
      } finally {
        await sink.close();
      }
      if (cancellationToken?.isCancelled == true) {
        throw const AppUpdateCancelledException();
      }
      if (receivedBytes == 0) {
        throw const FormatException('更新包内容为空，无法安装。');
      }
      if (expectedLength != null && receivedBytes != expectedLength) {
        throw FormatException(
          '更新包下载不完整：已接收 $receivedBytes 字节，应为 $expectedLength 字节。',
        );
      }
      final header = await target.openRead(0, 4).fold<List<int>>(<int>[], (
        bytes,
        chunk,
      ) {
        bytes.addAll(chunk);
        return bytes.length > 4 ? bytes.sublist(0, 4) : bytes;
      });
      if (header.length < 2 || header[0] != 0x50 || header[1] != 0x4B) {
        throw const FormatException('更新包不是有效的 APK 压缩包，无法安装。');
      }
      return target;
    } on AppUpdateCancelledException {
      rethrow;
    } on TimeoutException {
      throw const FormatException('更新包下载超时，请检查网络后重试。');
    } finally {
      client.close();
      if (cancellationToken?.isCancelled == true &&
          target != null &&
          await target.exists()) {
        await target.delete();
      }
    }
  }

  static int _versionValue(String tag) {
    final normalized = tag.trim().replaceFirst(
      RegExp(r'^v', caseSensitive: false),
      '',
    );
    final match = RegExp(
      r'^(\d+)\.(\d+)(?:\.(\d+))?Alpha(\d+)?$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (match == null) {
      return -1;
    }
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    final patch = int.tryParse(match.group(3) ?? '') ?? 0;
    final alpha = int.tryParse(match.group(4) ?? '') ?? 0;
    return (((major * 1000) + minor) * 1000 + patch) * 1000 + alpha;
  }
}
