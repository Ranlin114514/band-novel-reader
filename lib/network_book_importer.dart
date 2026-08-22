import 'dart:convert';

import 'package:http/http.dart' as http;

class DownloadedNetworkBook {
  const DownloadedNetworkBook({
    required this.title,
    required this.text,
    required this.sourceUrl,
  });

  final String title;
  final String text;
  final String sourceUrl;
}

class NetworkBookImporter {
  NetworkBookImporter._();

  static Future<DownloadedNetworkBook> download({
    required String url,
    required String titleFallback,
    String? authorization,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
      throw const FormatException('请输入以 http:// 或 https:// 开头的 API 地址。');
    }

    final headers = <String, String>{'Accept': 'text/plain, application/json'};
    if (authorization != null && authorization.trim().isNotEmpty) {
      headers['Authorization'] = authorization.trim();
    }
    final response = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('接口返回 HTTP ${response.statusCode}。');
    }

    final body = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    if (body.isEmpty) {
      throw const FormatException('接口未返回可导入的图书正文。');
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
    if (text.trim().isEmpty) {
      throw const FormatException(
        '无法从接口响应中找到正文；请确认响应含 content、text 或 body 字段，或直接返回纯文本。',
      );
    }
    return DownloadedNetworkBook(
      title: title,
      text: text.trim(),
      sourceUrl: uri.toString(),
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
    required this.textUrl,
  });

  final int id;
  final String title;
  final String author;
  final String language;
  final int downloadCount;
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
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));
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
