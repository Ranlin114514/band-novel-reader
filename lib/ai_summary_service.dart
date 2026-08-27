import 'dart:convert';

import 'package:flutter/foundation.dart';
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
      '你是一名小说压缩编辑。用户会同时提供完整小说正文和一个待压缩的目标片段。你必须先阅读完整小说正文以理解人物、事件、转折、线索、因果和时间顺序；完整小说正文仅用于上下文，不得将其他片段的内容混入输出。随后仅压缩目标片段，在不添加原文没有的信息、不改变人物关系和事件因果的前提下，保留该片段的关键人物、正在发生的事件、重要转折、线索、行动结果和必要时间顺序。输出仅包含目标片段的压缩正文，不要写标题、分析、免责声明、项目符号或“摘要：”等前缀。';

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
    required String fullNovelText,
    required String content,
    required int segmentIndex,
    required int totalSegments,
    required List<int> requestedSegmentIndexes,
    required int targetCharacters,
    required SummaryRichness richness,
  }) async {
    final model = settings.model.trim();
    if (model.isEmpty) {
      throw const FormatException('请先从模型选择页选择或手动填写 AI 模型。');
    }
    final fullText = fullNovelText.trim();
    if (fullText.isEmpty) {
      throw const FormatException('无法读取完整小说正文。');
    }
    final source = content.trim();
    if (source.isEmpty) {
      throw const FormatException('无法总结空白分段。');
    }
    if (segmentIndex < 0 ||
        totalSegments <= 0 ||
        segmentIndex >= totalSegments) {
      throw const FormatException('目标分段索引无效。');
    }
    final selectedIndexes = requestedSegmentIndexes.toSet().toList()..sort();
    if (selectedIndexes.isEmpty ||
        selectedIndexes.any((index) => index < 0 || index >= totalSegments) ||
        !selectedIndexes.contains(segmentIndex)) {
      throw const FormatException('本次 AI 总结的分段范围无效。');
    }
    final selectedRange = selectedIndexes
        .map((index) => '第 ${index + 1} 段')
        .join('、');
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
          'content':
              '$richnessInstruction\n\n本次用户选择的总结范围：$selectedRange（共 ${selectedIndexes.length}/$totalSegments 段）。你当前只需要输出其中的第 ${segmentIndex + 1} 段总结；不得改写或输出范围外分段。\n\n完整小说正文（仅用于理解上下文，必须先完整阅读，不要整体总结，也不要将其他片段内容混入输出）：\n$fullText\n\n待压缩的目标片段（第 ${segmentIndex + 1}/$totalSegments 段；只输出这一段的压缩正文）：\n$source',
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

enum AiSummaryJobStatus { idle, running, completed, canceled, failed }

class AiSummaryCandidate {
  const AiSummaryCandidate({
    required this.jobId,
    required this.bookId,
    required this.originalChunks,
    required this.summaryChunksByOriginalIndex,
  });

  final String jobId;
  final String bookId;
  final List<String> originalChunks;
  final Map<int, List<String>> summaryChunksByOriginalIndex;

  List<int> get summarizedIndexes {
    final indexes = summaryChunksByOriginalIndex.keys.toList()..sort();
    return indexes;
  }

  List<String> buildAppliedChunks() {
    final applied = List<String>.of(originalChunks);
    final indexes = summarizedIndexes
      ..sort((left, right) => right.compareTo(left));
    for (final index in indexes) {
      final replacement = summaryChunksByOriginalIndex[index];
      if (replacement != null) {
        applied.replaceRange(index, index + 1, replacement);
      }
    }
    return applied;
  }
}

class AiSummaryJobController extends ChangeNotifier {
  AiSummaryJobController._();

  static final instance = AiSummaryJobController._();

  AiSummaryJobStatus _status = AiSummaryJobStatus.idle;
  AiSummaryCandidate? _candidate;
  Object? _error;
  int _completed = 0;
  int _total = 0;
  int _runToken = 0;
  String? _jobId;
  bool _cancelRequested = false;

  AiSummaryJobStatus get status => _status;
  AiSummaryCandidate? get candidate => _candidate;
  Object? get error => _error;
  int get completed => _completed;
  int get total => _total;
  bool get isRunning => _status == AiSummaryJobStatus.running;
  String? get jobId => _jobId;

  Future<void> start({
    required String bookId,
    required StoredAiSettings settings,
    required String fullNovelText,
    required List<String> originalChunks,
    required List<int> selectedIndexes,
    required int targetCharacters,
    required SummaryRichness richness,
    required List<String> Function(String summary) normalizeSummary,
  }) async {
    if (isRunning) {
      throw StateError('已有 AI 总结任务正在后台运行。');
    }
    final sources = List<String>.of(originalChunks);
    final indexes = selectedIndexes.toSet().toList()..sort();
    if (bookId.isEmpty || sources.isEmpty || indexes.isEmpty) {
      throw ArgumentError('AI 总结任务缺少图书或目标分段。');
    }
    if (indexes.any((index) => index < 0 || index >= sources.length)) {
      throw ArgumentError('AI 总结目标分段范围无效。');
    }

    final token = ++_runToken;
    _jobId = '$bookId-$token';
    _status = AiSummaryJobStatus.running;
    _candidate = null;
    _error = null;
    _completed = 0;
    _total = indexes.length;
    _cancelRequested = false;
    notifyListeners();

    final summarized = <int, List<String>>{};
    final service = AiSummaryService();
    try {
      for (final index in indexes.reversed) {
        if (_cancelRequested || token != _runToken) {
          break;
        }
        final summary = await service.summarizeSegment(
          settings: settings,
          fullNovelText: fullNovelText,
          content: sources[index],
          segmentIndex: index,
          totalSegments: sources.length,
          requestedSegmentIndexes: indexes,
          targetCharacters: targetCharacters,
          richness: richness,
        );
        final normalized = normalizeSummary(summary);
        if (normalized.isEmpty) {
          throw const FormatException('AI 返回内容在分段校验后为空。');
        }
        if (token != _runToken) {
          return;
        }
        summarized[index] = normalized;
        _completed++;
        notifyListeners();
      }
      if (token != _runToken) {
        return;
      }
      if (summarized.isEmpty) {
        _status = AiSummaryJobStatus.canceled;
      } else {
        _candidate = AiSummaryCandidate(
          jobId: _jobId!,
          bookId: bookId,
          originalChunks: List<String>.unmodifiable(sources),
          summaryChunksByOriginalIndex: Map<int, List<String>>.unmodifiable(
            summarized.map(
              (index, chunks) =>
                  MapEntry(index, List<String>.unmodifiable(chunks)),
            ),
          ),
        );
        _status = AiSummaryJobStatus.completed;
      }
    } catch (error) {
      if (token != _runToken) {
        return;
      }
      _status = AiSummaryJobStatus.failed;
      _error = error;
    } finally {
      service.dispose();
      if (token == _runToken) {
        notifyListeners();
      }
    }
  }

  void cancel() {
    if (isRunning) {
      _cancelRequested = true;
      notifyListeners();
    }
  }

  void clearResult() {
    if (isRunning) {
      return;
    }
    _status = AiSummaryJobStatus.idle;
    _jobId = null;
    _candidate = null;
    _error = null;
    _completed = 0;
    _total = 0;
    notifyListeners();
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
