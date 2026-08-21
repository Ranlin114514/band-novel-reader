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
