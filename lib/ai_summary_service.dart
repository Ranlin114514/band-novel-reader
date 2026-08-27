import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_app_store.dart';

class AiModelInfo {
  const AiModelInfo({required this.id, required this.displayName});

  final String id;
  final String displayName;
}

class AiSummaryService {
  AiSummaryService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  static const builtInPrompt =
      '你是一名小说压缩编辑。请以情节完整为首要目标，在不添加原文没有的信息、不改变人物关系和事件因果的前提下，压缩用户提供的单个小说片段。必须保留关键人物、正在发生的事件、重要转折、线索、行动结果和必要的时间顺序。输出仅包含压缩后的正文，不要写标题、分析、免责声明、项目符号或“摘要：”等前缀。';

  final http.Client _client;
  final bool _ownsClient;

  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }

  static Uri endpointFor(StoredAiSettings settings, String path) {
    final base = settings.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final suffix = path.trim().isEmpty
        ? ''
        : '/${path.trim().replaceFirst(RegExp(r'^/+'), '')}';
    final uri = Uri.tryParse('$base$suffix');
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException('AI API Base URL 格式无效。');
    }
    return uri;
  }

  Map<String, String> _headers(StoredAiSettings settings) {
    final key = settings.apiKey.trim();
    if (key.isEmpty) {
      throw const FormatException('请先填写 AI API Key。');
    }
    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json; charset=utf-8',
      'Authorization': 'Bearer $key',
    };
  }

  Future<List<AiModelInfo>> fetchModels(StoredAiSettings settings) async {
    final response = await _client
        .get(endpointFor(settings, '/models'), headers: _headers(settings))
        .timeout(const Duration(seconds: 15));
    final decoded = _decodeResponse(response, action: '读取模型列表');
    final rawModels = decoded['data'];
    if (rawModels is! List) {
      throw const FormatException('AI API 未返回兼容的 data 模型列表。');
    }
    final models = <AiModelInfo>[];
    for (final raw in rawModels) {
      if (raw is! Map) {
        continue;
      }
      final id = raw['id'];
      if (id is String && id.trim().isNotEmpty) {
        final ownedBy = raw['owned_by'];
        models.add(
          AiModelInfo(
            id: id.trim(),
            displayName: ownedBy is String && ownedBy.trim().isNotEmpty
                ? '${id.trim()} · ${ownedBy.trim()}'
                : id.trim(),
          ),
        );
      }
    }
    models.sort((left, right) => left.id.compareTo(right.id));
    if (models.isEmpty) {
      throw const FormatException('AI API 未返回可选择的模型。');
    }
    return models;
  }

  Future<List<AiModelInfo>> testConnection(StoredAiSettings settings) {
    return fetchModels(settings);
  }

  Future<String> summarizeSegment({
    required StoredAiSettings settings,
    required String content,
    required int targetCharacters,
    required SummaryRichness richness,
  }) async {
    final model = settings.model.trim();
    if (model.isEmpty) {
      throw const FormatException('请先从模型选择页选择或手动填写 AI 模型。');
    }
    final source = content.trim();
    if (source.isEmpty) {
      throw const FormatException('无法总结空白分段。');
    }
    final target = targetCharacters.clamp(20, 250).toInt();
    final customPrompt = settings.customPrompt.trim();
    final richnessInstruction = switch (richness) {
      SummaryRichness.concise => '以精简为优先，目标不超过 $target 个中文字符或等量文本。',
      SummaryRichness.balanced => '在情节完整和篇幅之间平衡，目标约 $target 个中文字符或等量文本。',
      SummaryRichness.detailed => '尽量保留细节但仍压缩，目标不超过 $target 个中文字符或等量文本。',
    };
    final body = <String, Object?>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': builtInPrompt},
        if (customPrompt.isNotEmpty)
          {'role': 'system', 'content': '用户附加要求（不得与情节完整性规则冲突）：$customPrompt'},
        {
          'role': 'user',
          'content': '$richnessInstruction\n\n需要压缩的小说片段：\n$source',
        },
      ],
      'temperature': richness == SummaryRichness.concise ? 0.2 : 0.35,
      'max_tokens': (target * 2).clamp(64, 512),
    };
    if (settings.useReasoning) {
      body['reasoning_effort'] = 'medium';
    }
    final response = await _client
        .post(
          endpointFor(settings, settings.chatPath),
          headers: _headers(settings),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 60));
    final decoded = _decodeResponse(response, action: '生成 AI 总结');
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const FormatException('AI API 未返回可用的总结内容。');
    }
    final message = choices.first['message'];
    if (message is! Map) {
      throw const FormatException('AI API 返回的消息格式无效。');
    }
    final result = _readMessageContent(message['content']).trim();
    if (result.isEmpty) {
      throw const FormatException('AI API 返回了空白总结。');
    }
    return result;
  }

  Map<String, dynamic> _decodeResponse(
    http.Response response, {
    required String action,
  }) {
    final body = response.body.trim();
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw FormatException(
        '$action失败：服务未返回 JSON 响应（HTTP ${response.statusCode}）。',
      );
    }
    if (decoded is! Map) {
      throw FormatException('$action失败：服务返回格式无效（HTTP ${response.statusCode}）。');
    }
    final map = Map<String, dynamic>.from(decoded);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = map['error'];
      final message = error is Map ? error['message'] : null;
      throw FormatException(
        '$action失败（HTTP ${response.statusCode}）：${message is String && message.isNotEmpty ? message : '请检查 API 地址、Key、模型和网络连接。'}',
      );
    }
    return map;
  }

  String _readMessageContent(Object? value) {
    if (value is String) {
      return value;
    }
    if (value is List) {
      return value.map((part) {
        if (part is Map && part['text'] is String) {
          return part['text'] as String;
        }
        return '';
      }).join();
    }
    return '';
  }
}

enum SummaryRichness { concise, balanced, detailed }

extension SummaryRichnessLabel on SummaryRichness {
  String get title => switch (this) {
    SummaryRichness.concise => '精简',
    SummaryRichness.balanced => '平衡',
    SummaryRichness.detailed => '丰富',
  };

  String get description => switch (this) {
    SummaryRichness.concise => '压缩比更高，优先保留主线事件。',
    SummaryRichness.balanced => '兼顾人物、事件与阅读流畅性。',
    SummaryRichness.detailed => '保留更多线索和氛围，但仍受目标字数控制。',
  };
}
