import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class DownloadProgress {
  const DownloadProgress({
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

class DownloadCancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => '下载已取消。';
}

class DownloadedNetworkBook {
  const DownloadedNetworkBook({
    required this.title,
    required this.text,
    required this.sourceUrl,
    required this.byteLength,
  });

  final String title;
  final String text;
  final String sourceUrl;
  final int byteLength;
}

class NetworkBookImporter {
  NetworkBookImporter._();

  static const _downloadTimeout = Duration(seconds: 30);
  static const _maximumDownloadBytes = 25 * 1024 * 1024;

  static Future<DownloadedNetworkBook> download({
    required String url,
    required String titleFallback,
    String? authorization,
  }) {
    return downloadWithProgress(
      url: url,
      titleFallback: titleFallback,
      authorization: authorization,
    );
  }

  static Future<DownloadedNetworkBook> downloadWithProgress({
    required String url,
    required String titleFallback,
    String? authorization,
    void Function(DownloadProgress progress)? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
      throw const FormatException('请输入以 http:// 或 https:// 开头的 API 地址。');
    }
    if (cancellationToken?.isCancelled == true) {
      throw const DownloadCancelledException();
    }

    final headers = <String, String>{
      'Accept': 'text/plain, text/*;q=0.9, application/json;q=0.5',
      'User-Agent': 'BandNovelReader/2.2 (Android; public-domain import)',
    };
    if (authorization != null && authorization.trim().isNotEmpty) {
      headers['Authorization'] = authorization.trim();
    }

    final client = http.Client();
    try {
      final request = http.Request('GET', uri)..headers.addAll(headers);
      final response = await client.send(request).timeout(_downloadTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException('接口返回 HTTP ${response.statusCode}。');
      }
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.contains('text/html')) {
        throw const FormatException('下载地址返回了网页而不是纯文本图书，请返回搜索结果后重试。');
      }

      final expectedLength = response.contentLength;
      if (expectedLength != null && expectedLength > _maximumDownloadBytes) {
        throw const FormatException('图书文件超过 25 MB 安全导入上限，未写入书库。');
      }
      final hasCompressedResponse = (response.headers['content-encoding'] ?? '')
          .trim()
          .isNotEmpty;
      final bytes = BytesBuilder(copy: false);
      var receivedBytes = 0;
      onProgress?.call(
        DownloadProgress(
          receivedBytes: receivedBytes,
          totalBytes: expectedLength,
        ),
      );
      await for (final chunk in response.stream.timeout(_downloadTimeout)) {
        if (cancellationToken?.isCancelled == true) {
          throw const DownloadCancelledException();
        }
        if (receivedBytes + chunk.length > _maximumDownloadBytes) {
          throw const FormatException('图书文件超过 25 MB 安全导入上限，下载已停止。');
        }
        bytes.add(chunk);
        receivedBytes += chunk.length;
        onProgress?.call(
          DownloadProgress(
            receivedBytes: receivedBytes,
            totalBytes: expectedLength,
          ),
        );
      }
      if (cancellationToken?.isCancelled == true) {
        throw const DownloadCancelledException();
      }
      final downloadedBytes = bytes.takeBytes();
      if (downloadedBytes.isEmpty) {
        throw const FormatException('下载内容为空，无法导入图书。');
      }
      if (expectedLength != null &&
          !hasCompressedResponse &&
          downloadedBytes.length != expectedLength) {
        throw FormatException(
          '下载不完整：已接收 ${downloadedBytes.length} 字节，应为 $expectedLength 字节。请重试。',
        );
      }

      final body = _decodeUtf8Text(downloadedBytes);
      final book = _parseBook(
        body: body,
        titleFallback: titleFallback,
        sourceUrl: response.request?.url.toString() ?? uri.toString(),
        byteLength: downloadedBytes.length,
      );
      onProgress?.call(
        DownloadProgress(
          receivedBytes: downloadedBytes.length,
          totalBytes: expectedLength ?? downloadedBytes.length,
        ),
      );
      return book;
    } on TimeoutException {
      throw const FormatException('下载超时，请检查网络后重试。');
    } finally {
      client.close();
    }
  }

  static String _decodeUtf8Text(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false).trim();
    } on FormatException {
      throw const FormatException('下载内容不是有效 UTF-8 纯文本，未导入到书库。');
    }
  }

  static DownloadedNetworkBook _parseBook({
    required String body,
    required String titleFallback,
    required String sourceUrl,
    required int byteLength,
  }) {
    if (body.isEmpty) {
      throw const FormatException('下载内容不含可导入正文，未写入书库。');
    }
    final parsed = _tryParseJson(body);
    final fallbackTitle = titleFallback.trim().isEmpty
        ? '网络导入图书'
        : titleFallback.trim();
    final title =
        _readText(parsed, const ['title', 'name', 'bookName']) ?? fallbackTitle;
    final text =
        _readText(parsed, const [
          'content',
          'text',
          'body',
          'bookText',
          'data',
        ]) ??
        body;
    final normalizedText = text.trim();
    if (normalizedText.isEmpty || normalizedText.runes.length < 20) {
      throw const FormatException('下载正文过短或为空，可能不完整，未写入书库。');
    }
    return DownloadedNetworkBook(
      title: title.trim().isEmpty ? fallbackTitle : title.trim(),
      text: normalizedText,
      sourceUrl: sourceUrl,
      byteLength: byteLength,
    );
  }

  static Object? _tryParseJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  static String? _readText(Object? value, List<String> keys) {
    if (value is Map) {
      for (final key in keys) {
        final candidate = value[key];
        if (candidate is String && candidate.trim().isNotEmpty) {
          return candidate;
        }
      }
      for (final nestedKey in const ['data', 'result', 'book']) {
        final nested = value[nestedKey];
        final found = _readText(nested, keys);
        if (found != null) {
          return found;
        }
      }
    }
    return null;
  }
}

/// A copyright-free text record returned by the Gutendex / Project Gutenberg
/// catalogue. Only records that expose a direct plain-text download are used.
class PublicDomainBookResult {
  const PublicDomainBookResult({
    required this.id,
    required this.title,
    required this.author,
    required this.language,
    required this.downloadCount,
    required this.summary,
    required this.subjects,
    required this.textUrl,
  });

  final int id;
  final String title;
  final String author;
  final String language;
  final int downloadCount;
  final String summary;
  final List<String> subjects;
  final String textUrl;
}

class PublicDomainBookCatalog {
  PublicDomainBookCatalog._();

  static Future<List<PublicDomainBookResult>> search(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final uri = Uri.https('gutendex.com', '/books', {'search': normalized});
    final response = await http
        .get(
          uri,
          headers: const {
            'Accept': 'application/json',
            'User-Agent': 'BandNovelReader/2.2 (Android; public-domain search)',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('开源图书目录返回 HTTP ${response.statusCode}。');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['results'] is! List) {
      throw const FormatException('开源图书目录返回了无法识别的搜索结果。');
    }
    final results = <PublicDomainBookResult>[];
    for (final raw in decoded['results'] as List) {
      if (raw is! Map ||
          raw['copyright'] != false ||
          raw['media_type'] != 'Text') {
        continue;
      }
      final id = raw['id'];
      final title = raw['title'];
      final formats = raw['formats'];
      if (id is! int || title is! String || formats is! Map) {
        continue;
      }
      final textUrl = _readPlainTextUrl(formats);
      if (textUrl == null) {
        continue;
      }
      final authors = raw['authors'];
      final author = authors is List
          ? authors
                .whereType<Map>()
                .map((entry) => entry['name'])
                .whereType<String>()
                .where((name) => name.trim().isNotEmpty)
                .join('、')
          : '';
      final languages = raw['languages'];
      final language = languages is List
          ? languages.whereType<String>().join(', ')
          : '';
      results.add(
        PublicDomainBookResult(
          id: id,
          title: title.trim().isEmpty ? '未命名图书' : title.trim(),
          author: author.isEmpty ? '未知作者' : author,
          language: language.isEmpty ? '未知语言' : language,
          downloadCount: raw['download_count'] is int
              ? raw['download_count'] as int
              : 0,
          summary: _readSummary(raw['summaries']),
          subjects: _readStrings(raw['subjects']),
          textUrl: textUrl,
        ),
      );
    }
    return results;
  }

  static Future<DownloadedNetworkBook> download(PublicDomainBookResult book) {
    return NetworkBookImporter.download(
      url: book.textUrl,
      titleFallback: book.title,
    );
  }

  static Future<DownloadedNetworkBook> downloadWithProgress(
    PublicDomainBookResult book, {
    void Function(DownloadProgress progress)? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) {
    return NetworkBookImporter.downloadWithProgress(
      url: book.textUrl,
      titleFallback: book.title,
      onProgress: onProgress,
      cancellationToken: cancellationToken,
    );
  }

  static String _readSummary(Object? value) {
    final summaries = _readStrings(value);
    return summaries.isEmpty ? '该目录未提供内容简介。' : summaries.join('\n\n');
  }

  static List<String> _readStrings(Object? value) => value is List
      ? value
            .whereType<String>()
            .where((item) => item.trim().isNotEmpty)
            .toList(growable: false)
      : const [];

  static String? _readPlainTextUrl(Map formats) {
    const preferred = [
      'text/plain; charset=utf-8',
      'text/plain; charset=us-ascii',
      'text/plain',
    ];
    for (final key in preferred) {
      final value = formats[key];
      if (value is String && value.startsWith('http')) {
        return value;
      }
    }
    for (final entry in formats.entries) {
      if (entry.key is String &&
          (entry.key as String).startsWith('text/plain') &&
          entry.value is String &&
          (entry.value as String).startsWith('http')) {
        return entry.value as String;
      }
    }
    return null;
  }
}
