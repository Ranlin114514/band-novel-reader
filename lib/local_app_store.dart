import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class StoredNovelDocument {
  const StoredNovelDocument({
    required this.text,
    required this.fileName,
    required this.maxCharacters,
    required this.modeIndex,
    required this.intervalMilliseconds,
    required this.customChunks,
    required this.wearablePresetEnabled,
    required this.wearablePresetBrandId,
    required this.wearablePresetBrandName,
    required this.wearablePresetMaxCharacters,
    required this.compactSegmentContent,
    required this.removeEmojiFromSegments,
    required this.richSegmentContent,
  });

  final String text;
  final String? fileName;
  final int maxCharacters;
  final int modeIndex;
  final int intervalMilliseconds;
  final List<String>? customChunks;
  final bool wearablePresetEnabled;
  final String? wearablePresetBrandId;
  final String? wearablePresetBrandName;
  final int? wearablePresetMaxCharacters;
  final bool compactSegmentContent;
  final bool removeEmojiFromSegments;
  final bool richSegmentContent;
}

enum BookStorageSource { local, network }

class StoredLibraryBook {
  const StoredLibraryBook({
    required this.id,
    required this.text,
    required this.fileName,
    required this.customChunks,
    this.source = BookStorageSource.local,
  });

  final String id;
  final String text;
  final String? fileName;
  final List<String>? customChunks;
  final BookStorageSource source;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'fileName': fileName,
    'customChunks': customChunks,
    'source': source.name,
  };

  static StoredLibraryBook? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final id = value['id'];
    final text = value['text'];
    if (id is! String || id.isEmpty || text is! String) {
      return null;
    }
    final sourceValue = value['source'];
    final source = sourceValue is String
        ? BookStorageSource.values
              .where((item) => item.name == sourceValue)
              .firstOrNull
        : null;
    return StoredLibraryBook(
      id: id,
      text: text,
      fileName: value['fileName'] as String?,
      customChunks: _decodeChunksFromValue(value['customChunks']),
      source: source ?? BookStorageSource.local,
    );
  }
}

class StoredLibrary {
  const StoredLibrary({required this.books, required this.selectedBookId});

  final List<StoredLibraryBook> books;
  final String? selectedBookId;
}

class StoredNetworkImportSettings {
  const StoredNetworkImportSettings({
    required this.url,
    required this.title,
    required this.authorization,
  });

  final String url;
  final String title;
  final String authorization;
}

class StoredAiSettings {
  const StoredAiSettings({
    required this.providerIndex,
    required this.apiName,
    required this.apiKey,
    required this.baseUrl,
    required this.chatPath,
    required this.model,
    required this.useReasoning,
    required this.customPrompt,
  });

  final int providerIndex;
  final String apiName;
  final String apiKey;
  final String baseUrl;
  final String chatPath;
  final String model;
  final bool useReasoning;
  final String customPrompt;
}

class StoredSendingSession {
  const StoredSendingSession({
    this.bookId,
    required this.chunks,
    required this.nextIndex,
    required this.modeIndex,
    required this.intervalMilliseconds,
    required this.notificationBaseId,
  });

  final String? bookId;
  final List<String> chunks;
  final int nextIndex;
  final int modeIndex;
  final int intervalMilliseconds;
  final int notificationBaseId;

  bool get canResume => chunks.isNotEmpty && nextIndex < chunks.length;

  Map<String, Object?> toJson() => {
    'bookId': bookId,
    'chunks': chunks,
    'nextIndex': nextIndex,
    'modeIndex': modeIndex,
    'intervalMilliseconds': intervalMilliseconds,
    'notificationBaseId': notificationBaseId,
  };

  static StoredSendingSession? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final chunks = _decodeChunksFromValue(value['chunks']);
    final nextIndex = value['nextIndex'];
    final notificationBaseId = value['notificationBaseId'];
    if (chunks == null || nextIndex is! int || notificationBaseId is! int) {
      return null;
    }
    return StoredSendingSession(
      bookId: value['bookId'] as String?,
      chunks: chunks,
      nextIndex: nextIndex.clamp(0, chunks.length).toInt(),
      modeIndex: value['modeIndex'] as int? ?? 0,
      intervalMilliseconds: (value['intervalMilliseconds'] as int? ?? 1000)
          .clamp(100, 3600000)
          .toInt(),
      notificationBaseId: notificationBaseId,
    );
  }
}

class LocalAppStore {
  LocalAppStore._();

  static final instance = LocalAppStore._();

  static const _onboardingCompletedKey = 'onboarding_completed';
  static const _textKey = 'novel_text';
  static const _fileNameKey = 'novel_file_name';
  static const _maxCharactersKey = 'novel_max_characters';
  static const _wearablePresetEnabledKey = 'wearable_preset_enabled';
  static const _wearablePresetBrandIdKey = 'wearable_preset_brand_id';
  static const _wearablePresetBrandNameKey = 'wearable_preset_brand_name';
  static const _wearablePresetMaxCharactersKey =
      'wearable_preset_max_characters';
  static const _themePreferenceKey = 'app_theme_preference';
  static const _startupScreenEnabledKey = 'startup_screen_enabled';
  static const _dynamicColorEnabledKey = 'dynamic_color_enabled';
  static const _modeIndexKey = 'sending_mode_index';
  static const _intervalMillisecondsKey = 'sending_interval_milliseconds';
  static const _legacyIntervalSecondsKey = 'sending_interval_seconds';
  static const _customChunksKey = 'novel_custom_chunks_json';
  static const _libraryBooksKey = 'library_books_json';
  static const _selectedBookIdKey = 'library_selected_book_id';
  static const _sessionsByBookKey = 'sending_sessions_by_book_json';
  static const _sessionBookIdKey = 'session_book_id';
  static const _sessionChunksKey = 'session_chunks_json';
  static const _sessionNextIndexKey = 'session_next_index';
  static const _sessionModeIndexKey = 'session_mode_index';
  static const _sessionIntervalMillisecondsKey =
      'session_interval_milliseconds';
  static const _legacySessionIntervalSecondsKey = 'session_interval_seconds';
  static const _sessionNotificationBaseIdKey = 'session_notification_base_id';
  static const _networkApiUrlKey = 'network_api_url';
  static const _networkApiTitleKey = 'network_api_title';
  static const _networkApiAuthorizationKey = 'network_api_authorization';
  static const _compactSegmentContentKey = 'compact_segment_content';
  static const _removeEmojiFromSegmentsKey = 'remove_emoji_from_segments';
  static const _richSegmentContentKey = 'rich_segment_content';
  static const _startupContentRecommendationKey =
      'startup_content_recommendation';
  static const _aiProviderIndexKey = 'ai_provider_index';
  static const _aiApiNameKey = 'ai_api_name';
  static const _aiApiKeyKey = 'ai_api_key';
  static const _aiBaseUrlKey = 'ai_base_url';
  static const _aiChatPathKey = 'ai_chat_path';
  static const _aiModelKey = 'ai_model';
  static const _aiUseReasoningKey = 'ai_use_reasoning';
  static const _aiCustomPromptKey = 'ai_custom_prompt';
  static const _deferredUpdateTagKey = 'deferred_update_tag';
  static const _updateSourceKey = 'update_source';

  Future<StoredNovelDocument> loadDocument() async {
    final preferences = await SharedPreferences.getInstance();
    return StoredNovelDocument(
      text: preferences.getString(_textKey) ?? '',
      fileName: preferences.getString(_fileNameKey),
      maxCharacters: (preferences.getInt(_maxCharactersKey) ?? 120)
          .clamp(20, 1000)
          .toInt(),
      modeIndex: preferences.getInt(_modeIndexKey) ?? 0,
      intervalMilliseconds: _readIntervalMilliseconds(
        preferences,
        _intervalMillisecondsKey,
        _legacyIntervalSecondsKey,
      ),
      customChunks: _decodeChunks(preferences.getString(_customChunksKey)),
      wearablePresetEnabled:
          preferences.getBool(_wearablePresetEnabledKey) ?? false,
      wearablePresetBrandId: preferences.getString(_wearablePresetBrandIdKey),
      wearablePresetBrandName: preferences.getString(
        _wearablePresetBrandNameKey,
      ),
      wearablePresetMaxCharacters: preferences
          .getInt(_wearablePresetMaxCharactersKey)
          ?.clamp(20, 1000)
          .toInt(),
      compactSegmentContent:
          preferences.getBool(_compactSegmentContentKey) ?? false,
      removeEmojiFromSegments:
          preferences.getBool(_removeEmojiFromSegmentsKey) ?? false,
      richSegmentContent: preferences.getBool(_richSegmentContentKey) ?? false,
    );
  }

  Future<void> saveDocument({
    required String text,
    required String? fileName,
    required int maxCharacters,
    required int modeIndex,
    required int intervalMilliseconds,
    required List<String>? customChunks,
    required bool compactSegmentContent,
    required bool removeEmojiFromSegments,
    required bool richSegmentContent,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await _saveSettings(
      preferences,
      maxCharacters: maxCharacters,
      modeIndex: modeIndex,
      intervalMilliseconds: intervalMilliseconds,
      compactSegmentContent: compactSegmentContent,
      removeEmojiFromSegments: removeEmojiFromSegments,
      richSegmentContent: richSegmentContent,
    );
    await preferences.setString(_textKey, text);
    if (fileName == null || fileName.isEmpty) {
      await preferences.remove(_fileNameKey);
    } else {
      await preferences.setString(_fileNameKey, fileName);
    }
    await _saveCustomChunks(preferences, customChunks);
  }

  Future<StoredLibrary> loadLibrary() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(_libraryBooksKey);
    final books = <StoredLibraryBook>[];
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is List) {
          for (final item in decoded) {
            final book = StoredLibraryBook.fromJson(item);
            if (book != null) {
              books.add(book);
            }
          }
        }
      } on FormatException {
        // Corrupted local library data falls back to legacy data below.
      }
    }

    if (books.isEmpty) {
      final legacy = await loadDocument();
      if (legacy.text.trim().isNotEmpty) {
        final migrated = StoredLibraryBook(
          id: _createBookId(legacy.fileName, legacy.text),
          text: legacy.text,
          fileName: legacy.fileName,
          customChunks: legacy.customChunks,
        );
        books.add(migrated);
        await saveLibrary(books: books, selectedBookId: migrated.id);
      }
    }

    final selected = preferences.getString(_selectedBookIdKey);
    final selectedId = books.any((book) => book.id == selected)
        ? selected
        : books.isEmpty
        ? null
        : books.first.id;
    return StoredLibrary(books: books, selectedBookId: selectedId);
  }

  Future<void> saveLibrary({
    required List<StoredLibraryBook> books,
    required String? selectedBookId,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _libraryBooksKey,
      jsonEncode(books.map((book) => book.toJson()).toList(growable: false)),
    );
    if (selectedBookId == null) {
      await preferences.remove(_selectedBookIdKey);
    } else {
      await preferences.setString(_selectedBookIdKey, selectedBookId);
    }
  }

  Future<void> saveSettings({
    required int maxCharacters,
    required int modeIndex,
    required int intervalMilliseconds,
    required bool compactSegmentContent,
    required bool removeEmojiFromSegments,
    required bool richSegmentContent,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await _saveSettings(
      preferences,
      maxCharacters: maxCharacters,
      modeIndex: modeIndex,
      intervalMilliseconds: intervalMilliseconds,
      compactSegmentContent: compactSegmentContent,
      removeEmojiFromSegments: removeEmojiFromSegments,
      richSegmentContent: richSegmentContent,
    );
  }

  Future<StoredNetworkImportSettings> loadNetworkImportSettings() async {
    final preferences = await SharedPreferences.getInstance();
    return StoredNetworkImportSettings(
      url: preferences.getString(_networkApiUrlKey) ?? '',
      title: preferences.getString(_networkApiTitleKey) ?? '',
      authorization: preferences.getString(_networkApiAuthorizationKey) ?? '',
    );
  }

  Future<StoredAiSettings> loadAiSettings() async {
    final preferences = await SharedPreferences.getInstance();
    return StoredAiSettings(
      providerIndex: (preferences.getInt(_aiProviderIndexKey) ?? 0)
          .clamp(0, 1)
          .toInt(),
      apiName: preferences.getString(_aiApiNameKey) ?? 'OpenAI',
      apiKey: preferences.getString(_aiApiKeyKey) ?? '',
      baseUrl:
          preferences.getString(_aiBaseUrlKey) ?? 'https://api.openai.com/v1',
      chatPath: preferences.getString(_aiChatPathKey) ?? '/chat/completions',
      model: preferences.getString(_aiModelKey) ?? '',
      useReasoning: preferences.getBool(_aiUseReasoningKey) ?? false,
      customPrompt: preferences.getString(_aiCustomPromptKey) ?? '',
    );
  }

  Future<void> saveAiSettings({
    required int providerIndex,
    required String apiName,
    required String apiKey,
    required String baseUrl,
    required String chatPath,
    required String model,
    required bool useReasoning,
    required String customPrompt,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setInt(
        _aiProviderIndexKey,
        providerIndex.clamp(0, 1).toInt(),
      ),
      preferences.setString(_aiApiNameKey, apiName.trim()),
      preferences.setString(_aiApiKeyKey, apiKey.trim()),
      preferences.setString(_aiBaseUrlKey, baseUrl.trim()),
      preferences.setString(_aiChatPathKey, chatPath.trim()),
      preferences.setString(_aiModelKey, model.trim()),
      preferences.setBool(_aiUseReasoningKey, useReasoning),
      preferences.setString(_aiCustomPromptKey, customPrompt.trim()),
    ]);
  }

  Future<int> loadUpdateSourceIndex() async {
    final preferences = await SharedPreferences.getInstance();
    return (preferences.getInt(_updateSourceKey) ?? 0).clamp(0, 1).toInt();
  }

  Future<void> saveUpdateSourceIndex(int index) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_updateSourceKey, index.clamp(0, 1).toInt());
  }

  Future<String?> loadDeferredUpdateTag() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_deferredUpdateTagKey);
  }

  Future<void> saveDeferredUpdateTag(String tag) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_deferredUpdateTagKey, tag.trim());
  }

  Future<void> clearDeferredUpdateTag() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_deferredUpdateTagKey);
  }

  Future<void> saveNetworkImportSettings({
    required String url,
    required String title,
    required String authorization,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_networkApiUrlKey, url.trim());
    await preferences.setString(_networkApiTitleKey, title.trim());
    await preferences.setString(
      _networkApiAuthorizationKey,
      authorization.trim(),
    );
  }

  Future<void> saveWearablePreset({
    required bool enabled,
    required String? brandId,
    required String? brandName,
    required int? maxCharacters,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_wearablePresetEnabledKey, enabled);
    if (brandId == null || brandId.isEmpty) {
      await preferences.remove(_wearablePresetBrandIdKey);
    } else {
      await preferences.setString(_wearablePresetBrandIdKey, brandId);
    }
    if (brandName == null || brandName.isEmpty) {
      await preferences.remove(_wearablePresetBrandNameKey);
    } else {
      await preferences.setString(_wearablePresetBrandNameKey, brandName);
    }
    if (maxCharacters == null) {
      await preferences.remove(_wearablePresetMaxCharactersKey);
    } else {
      await preferences.setInt(
        _wearablePresetMaxCharactersKey,
        maxCharacters.clamp(20, 1000).toInt(),
      );
    }
  }

  Future<int> loadThemePreference() async {
    final preferences = await SharedPreferences.getInstance();
    return (preferences.getInt(_themePreferenceKey) ?? 0).clamp(0, 2).toInt();
  }

  Future<void> saveThemePreference(int preferenceIndex) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      _themePreferenceKey,
      preferenceIndex.clamp(0, 2).toInt(),
    );
  }

  Future<bool> isStartupScreenEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_startupScreenEnabledKey) ?? true;
  }

  Future<void> saveStartupScreenEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_startupScreenEnabledKey, enabled);
  }

  Future<int> loadStartupContentRecommendation() async {
    final preferences = await SharedPreferences.getInstance();
    return (preferences.getInt(_startupContentRecommendationKey) ?? 0)
        .clamp(0, 12)
        .toInt();
  }

  Future<void> saveStartupContentRecommendation(int index) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      _startupContentRecommendationKey,
      index.clamp(0, 12).toInt(),
    );
  }

  Future<bool> isDynamicColorEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_dynamicColorEnabledKey) ?? false;
  }

  Future<void> saveDynamicColorEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_dynamicColorEnabledKey, enabled);
  }

  Future<void> _saveSettings(
    SharedPreferences preferences, {
    required int maxCharacters,
    required int modeIndex,
    required int intervalMilliseconds,
    required bool compactSegmentContent,
    required bool removeEmojiFromSegments,
    required bool richSegmentContent,
  }) async {
    await preferences.setInt(
      _maxCharactersKey,
      maxCharacters.clamp(20, 1000).toInt(),
    );
    await preferences.setInt(_modeIndexKey, modeIndex);
    await preferences.setInt(
      _intervalMillisecondsKey,
      intervalMilliseconds.clamp(100, 3600000).toInt(),
    );
    await preferences.setBool(_compactSegmentContentKey, compactSegmentContent);
    await preferences.setBool(
      _removeEmojiFromSegmentsKey,
      removeEmojiFromSegments,
    );
    await preferences.setBool(_richSegmentContentKey, richSegmentContent);
  }

  Future<void> _saveCustomChunks(
    SharedPreferences preferences,
    List<String>? customChunks,
  ) async {
    if (customChunks == null) {
      await preferences.remove(_customChunksKey);
    } else {
      await preferences.setString(_customChunksKey, jsonEncode(customChunks));
    }
  }

  Future<bool> hasCompletedOnboarding() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_onboardingCompletedKey) ?? false;
  }

  Future<void> markOnboardingCompleted() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_onboardingCompletedKey, true);
  }

  Future<StoredSendingSession?> loadSendingSession() async {
    final preferences = await SharedPreferences.getInstance();
    final chunksJson = preferences.getString(_sessionChunksKey);
    final nextIndex = preferences.getInt(_sessionNextIndexKey);
    final notificationBaseId = preferences.getInt(
      _sessionNotificationBaseIdKey,
    );
    if (chunksJson == null || nextIndex == null || notificationBaseId == null) {
      return null;
    }
    final chunks = _decodeChunks(chunksJson);
    if (chunks == null) {
      return null;
    }
    return StoredSendingSession(
      bookId: preferences.getString(_sessionBookIdKey),
      chunks: chunks,
      nextIndex: nextIndex.clamp(0, chunks.length).toInt(),
      modeIndex: preferences.getInt(_sessionModeIndexKey) ?? 0,
      intervalMilliseconds: _readIntervalMilliseconds(
        preferences,
        _sessionIntervalMillisecondsKey,
        _legacySessionIntervalSecondsKey,
      ),
      notificationBaseId: notificationBaseId,
    );
  }

  Future<Map<String, StoredSendingSession>> loadSendingSessions() async {
    final preferences = await SharedPreferences.getInstance();
    final decoded = _decodeJsonMap(preferences.getString(_sessionsByBookKey));
    final sessions = <String, StoredSendingSession>{};
    if (decoded != null) {
      for (final entry in decoded.entries) {
        final session = StoredSendingSession.fromJson(entry.value);
        if (session?.bookId == entry.key && session!.canResume) {
          sessions[entry.key] = session;
        }
      }
    }
    final legacy = await loadSendingSession();
    if (legacy?.bookId case final String bookId when legacy!.canResume) {
      sessions.putIfAbsent(bookId, () => legacy);
    }
    return sessions;
  }

  Future<void> _saveSendingSessions(
    SharedPreferences preferences,
    Map<String, StoredSendingSession> sessions,
  ) async {
    await preferences.setString(
      _sessionsByBookKey,
      jsonEncode(sessions.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  Future<void> saveSendingSession({
    String? bookId,
    required List<String> chunks,
    required int nextIndex,
    required int modeIndex,
    required int intervalMilliseconds,
    required int notificationBaseId,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    if (bookId == null) {
      await preferences.remove(_sessionBookIdKey);
    } else {
      await preferences.setString(_sessionBookIdKey, bookId);
    }
    await preferences.setString(_sessionChunksKey, jsonEncode(chunks));
    await preferences.setInt(
      _sessionNextIndexKey,
      nextIndex.clamp(0, chunks.length).toInt(),
    );
    await preferences.setInt(_sessionModeIndexKey, modeIndex);
    await preferences.setInt(
      _sessionIntervalMillisecondsKey,
      intervalMilliseconds.clamp(100, 3600000).toInt(),
    );
    await preferences.setInt(_sessionNotificationBaseIdKey, notificationBaseId);
    if (bookId != null) {
      final sessions = await loadSendingSessions();
      sessions[bookId] = StoredSendingSession(
        bookId: bookId,
        chunks: chunks,
        nextIndex: nextIndex.clamp(0, chunks.length).toInt(),
        modeIndex: modeIndex,
        intervalMilliseconds: intervalMilliseconds.clamp(100, 3600000).toInt(),
        notificationBaseId: notificationBaseId,
      );
      await _saveSendingSessions(preferences, sessions);
    }
  }

  int _readIntervalMilliseconds(
    SharedPreferences preferences,
    String millisecondsKey,
    String legacySecondsKey,
  ) {
    final milliseconds = preferences.getInt(millisecondsKey);
    if (milliseconds != null) {
      return milliseconds.clamp(100, 3600000).toInt();
    }
    final legacySeconds = preferences.getInt(legacySecondsKey);
    if (legacySeconds != null) {
      return (legacySeconds * 1000).clamp(100, 3600000).toInt();
    }
    return 1000;
  }

  Future<void> updateSendingProgress(
    int nextIndex, {
    String? expectedBookId,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final active = await loadSendingSession();
    if (expectedBookId != null && active?.bookId != expectedBookId) {
      return;
    }
    await preferences.setInt(
      _sessionNextIndexKey,
      nextIndex.clamp(0, active?.chunks.length ?? nextIndex).toInt(),
    );
    final bookId = active?.bookId;
    if (active != null && bookId != null) {
      final sessions = await loadSendingSessions();
      final updated = StoredSendingSession(
        bookId: bookId,
        chunks: active.chunks,
        nextIndex: nextIndex.clamp(0, active.chunks.length).toInt(),
        modeIndex: active.modeIndex,
        intervalMilliseconds: active.intervalMilliseconds,
        notificationBaseId: active.notificationBaseId,
      );
      if (updated.canResume) {
        sessions[bookId] = updated;
      } else {
        sessions.remove(bookId);
      }
      await _saveSendingSessions(preferences, sessions);
    }
  }

  Future<void> removeSendingSessionForBook(String bookId) async {
    final preferences = await SharedPreferences.getInstance();
    final sessions = await loadSendingSessions();
    sessions.remove(bookId);
    await _saveSendingSessions(preferences, sessions);
    final active = await loadSendingSession();
    if (active?.bookId == bookId) {
      await _clearLegacySendingSession(preferences);
    }
  }

  Future<void> clearActiveSendingSession({String? expectedBookId}) async {
    final active = await loadSendingSession();
    if (expectedBookId != null && active?.bookId != expectedBookId) {
      return;
    }
    final bookId = active?.bookId;
    if (bookId == null) {
      await clearSendingSession();
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    final sessions = await loadSendingSessions();
    sessions.remove(bookId);
    await _saveSendingSessions(preferences, sessions);
    await _clearLegacySendingSession(preferences);
  }

  Future<void> clearSendingSession() async {
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.remove(_sessionsByBookKey),
      _clearLegacySendingSession(preferences),
    ]);
  }

  Future<void> _clearLegacySendingSession(SharedPreferences preferences) async {
    await Future.wait([
      preferences.remove(_sessionBookIdKey),
      preferences.remove(_sessionChunksKey),
      preferences.remove(_sessionNextIndexKey),
      preferences.remove(_sessionModeIndexKey),
      preferences.remove(_sessionIntervalMillisecondsKey),
      preferences.remove(_legacySessionIntervalSecondsKey),
      preferences.remove(_sessionNotificationBaseIdKey),
    ]);
  }

  static String createBookId(String? fileName, String text) {
    return _createBookId(fileName, text);
  }

  static String _createBookId(String? fileName, String text) {
    final base =
        '${fileName ?? 'novel'}:${text.hashCode}:${DateTime.now().microsecondsSinceEpoch}';
    return base.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').substring(0, 20);
  }
}

List<String>? _decodeChunks(String? chunksJson) {
  if (chunksJson == null) {
    return null;
  }
  try {
    final decoded = jsonDecode(chunksJson);
    return _decodeChunksFromValue(decoded);
  } on FormatException {
    return null;
  }
}

List<String>? _decodeChunksFromValue(Object? value) {
  if (value is! List) {
    return null;
  }
  final chunks = value.map((item) => item.toString()).toList(growable: false);
  return chunks.isEmpty ? null : chunks;
}

Map<String, Object?>? _decodeJsonMap(String? encoded) {
  if (encoded == null || encoded.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      return null;
    }
    return {
      for (final entry in decoded.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  } catch (_) {
    return null;
  }
}
