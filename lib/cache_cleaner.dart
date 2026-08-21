import 'dart:io';

import 'package:path_provider/path_provider.dart';

class CacheCleaner {
  CacheCleaner._();

  /// 清理应用临时缓存；小说正文、设置和断点进度存储于偏好数据，不受影响。
  static Future<int> clearTemporaryCache() async {
    final directory = await getTemporaryDirectory();
    if (!await directory.exists()) {
      return 0;
    }

    var deletedBytes = 0;
    final entities = await directory.list(recursive: false).toList();
    for (final entity in entities) {
      deletedBytes += await _sizeOf(entity);
      await entity.delete(recursive: true);
    }
    return deletedBytes;
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static Future<int> _sizeOf(FileSystemEntity entity) async {
    if (entity is File) {
      return entity.length();
    }
    if (entity is Directory) {
      var total = 0;
      await for (final child in entity.list(
        recursive: true,
        followLinks: false,
      )) {
        if (child is File) {
          total += await child.length();
        }
      }
      return total;
    }
    return 0;
  }
}
