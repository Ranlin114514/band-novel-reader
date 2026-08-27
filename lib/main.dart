import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:dynamic_color/dynamic_color.dart' show DynamicColorBuilder;
import 'package:epubx/epubx.dart' hide Image;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'app_release.dart';
import 'app_update_download_page.dart';
import 'ai_summary_service.dart';
import 'app_update_service.dart';
import 'book_metadata.dart';
import 'cache_cleaner.dart';
import 'local_app_store.dart';
import 'network_book_importer.dart';

const _notificationChannelId = 'novel_text_channel';
const _notificationChannelName = '小说阅读通知';
const _notificationChannelDescription = '用于逐段显示小说文本';
const _notificationGroupKey = 'novel_text_group';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    FlutterForegroundTask.initCommunicationPort();
  } catch (_) {
    // 后台服务在实际启动时会再次初始化；启动阶段不阻塞主界面呈现。
  }
  final themeLoading = AppThemeController.instance.load();
  final startupScreenEnabledLoading = LocalAppStore.instance
      .isStartupScreenEnabled();
  await themeLoading;
  final startupScreenEnabled = await startupScreenEnabledLoading;
  runApp(
    NovelNotifierApp(
      themeController: AppThemeController.instance,
      startupScreenEnabled: startupScreenEnabled,
    ),
  );
}

enum AppThemePreference { system, light, dark }

enum AppColorPalette { teal, blue, indigo, violet, rose, coral, amber, lime }

extension AppColorPaletteLabel on AppColorPalette {
  String get title => switch (this) {
    AppColorPalette.teal => '青绿',
    AppColorPalette.blue => '湛蓝',
    AppColorPalette.indigo => '靛蓝',
    AppColorPalette.violet => '紫罗兰',
    AppColorPalette.rose => '玫粉',
    AppColorPalette.coral => '珊瑚',
    AppColorPalette.amber => '琥珀',
    AppColorPalette.lime => '青柠',
  };

  Color get seedColor => switch (this) {
    AppColorPalette.teal => const Color(0xFF0B6B69),
    AppColorPalette.blue => const Color(0xFF2465A8),
    AppColorPalette.indigo => const Color(0xFF4F5DAA),
    AppColorPalette.violet => const Color(0xFF7652A8),
    AppColorPalette.rose => const Color(0xFFB24D7E),
    AppColorPalette.coral => const Color(0xFFC25F3D),
    AppColorPalette.amber => const Color(0xFF9B6500),
    AppColorPalette.lime => const Color(0xFF647A00),
  };
}

extension AppThemePreferenceLabel on AppThemePreference {
  String get title => switch (this) {
    AppThemePreference.system => '跟随系统',
    AppThemePreference.light => '浅色',
    AppThemePreference.dark => '深色',
  };

  IconData get icon => switch (this) {
    AppThemePreference.system => Icons.brightness_auto_outlined,
    AppThemePreference.light => Icons.light_mode_outlined,
    AppThemePreference.dark => Icons.dark_mode_outlined,
  };
}

class AppThemeController extends ChangeNotifier {
  AppThemeController._();

  static final instance = AppThemeController._();
  AppThemePreference _preference = AppThemePreference.system;
  bool _dynamicColorEnabled = false;
  AppColorPalette _palette = AppColorPalette.teal;

  AppThemePreference get preference => _preference;
  bool get dynamicColorEnabled => _dynamicColorEnabled;
  AppColorPalette get palette => _palette;
  ThemeMode get themeMode => switch (_preference) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };

  Future<void> load() async {
    final values = await Future.wait<Object>([
      LocalAppStore.instance.loadThemePreference(),
      LocalAppStore.instance.isDynamicColorEnabled(),
      LocalAppStore.instance.loadThemePalette(),
    ]);
    final index = values[0] as int;
    _preference = AppThemePreference.values[index.clamp(0, 2)];
    _dynamicColorEnabled = values[1] as bool;
    final paletteIndex = values[2] as int;
    _palette = AppColorPalette.values[paletteIndex.clamp(0, 7)];
  }

  Future<void> setPreference(AppThemePreference preference) async {
    if (_preference == preference) {
      return;
    }
    _preference = preference;
    notifyListeners();
    await LocalAppStore.instance.saveThemePreference(preference.index);
  }

  Future<void> setDynamicColorEnabled(bool enabled) async {
    if (_dynamicColorEnabled == enabled) {
      return;
    }
    _dynamicColorEnabled = enabled;
    notifyListeners();
    await LocalAppStore.instance.saveDynamicColorEnabled(enabled);
  }

  Future<void> setPalette(AppColorPalette palette) async {
    if (_palette == palette) {
      return;
    }
    _palette = palette;
    notifyListeners();
    await LocalAppStore.instance.saveThemePalette(palette.index);
  }
}

enum SendingMode { foreground, background }

extension SendingModeLabel on SendingMode {
  String get title => switch (this) {
    SendingMode.foreground => '前台自动发送',
    SendingMode.background => '后台持续发送',
  };

  String get description => switch (this) {
    SendingMode.foreground => '应用保持打开时，按设定间隔发送；适合较短、需要精确控制的阅读任务。',
    SendingMode.background => '启用可见的系统服务通知，切换应用或锁屏后仍持续尝试发送；可在任务页停止。',
  };
}

class SendingConfig {
  const SendingConfig({required this.mode, required this.intervalMilliseconds});

  const SendingConfig.defaults()
    : mode = SendingMode.foreground,
      intervalMilliseconds = 1000;

  final SendingMode mode;
  final int intervalMilliseconds;

  SendingConfig copyWith({SendingMode? mode, int? intervalMilliseconds}) {
    return SendingConfig(
      mode: mode ?? this.mode,
      intervalMilliseconds: intervalMilliseconds ?? this.intervalMilliseconds,
    );
  }
}

enum StartupContentRecommendation {
  random(null, '随机推荐', '由一言在可用内容中随机推荐', Icons.shuffle_outlined),
  animation('a', '动画', '动画台词与相关句子', Icons.movie_outlined),
  comics('b', '漫画', '漫画台词与相关句子', Icons.auto_stories_outlined),
  games('c', '游戏', '游戏台词与相关句子', Icons.sports_esports_outlined),
  literature('d', '文学', '小说、散文与文学摘录', Icons.menu_book_outlined),
  original('e', '原创', '原创投稿内容', Icons.edit_note_outlined),
  network('f', '网络', '来自网络的句子', Icons.language_outlined),
  other('g', '其他', '其他分类内容', Icons.category_outlined),
  film('h', '影视', '影视台词与相关句子', Icons.live_tv_outlined),
  poetry('i', '诗词', '古今诗词内容', Icons.format_quote_outlined),
  music('j', '网易云', '音乐类内容；服务端可能无可用结果', Icons.music_note_outlined),
  philosophy('k', '哲学', '哲学与思辨内容', Icons.psychology_outlined),
  humor('l', '抖机灵', '轻松幽默的短句', Icons.sentiment_satisfied_alt_outlined);

  const StartupContentRecommendation(
    this.apiCategory,
    this.title,
    this.description,
    this.icon,
  );

  final String? apiCategory;
  final String title;
  final String description;
  final IconData icon;
}

class AppSettingsResult {
  const AppSettingsResult({
    required this.config,
    required this.maxCharacters,
    required this.compactSegmentContent,
    required this.removeEmojiFromSegments,
    required this.richSegmentContent,
  });

  final SendingConfig config;
  final int maxCharacters;
  final bool compactSegmentContent;
  final bool removeEmojiFromSegments;
  final bool richSegmentContent;
}

class EditorResult {
  const EditorResult({required this.text, required this.fileName});

  final String text;
  final String? fileName;
}

class NetworkImportRequest {
  const NetworkImportRequest({
    required this.url,
    required this.title,
    required this.authorization,
  });

  final String url;
  final String title;
  final String authorization;
}

class NovelNotifierApp extends StatelessWidget {
  const NovelNotifierApp({
    required this.themeController,
    required this.startupScreenEnabled,
    super.key,
  });

  final AppThemeController themeController;
  final bool startupScreenEnabled;

  ThemeData _buildTheme(Brightness brightness, {ColorScheme? colorScheme}) {
    final scheme =
        colorScheme ??
        ColorScheme.fromSeed(
          seedColor: themeController.palette.seedColor,
          brightness: brightness,
        );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        scrolledUnderElevation: 3,
      ),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: scheme.surfaceTint,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        indicatorColor: scheme.secondaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
        selectedColor: scheme.secondaryContainer,
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        secondaryLabelStyle: TextStyle(color: scheme.onSecondaryContainer),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          shape: const CircleBorder(),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        shape: const StadiumBorder(),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        alignLabelWithHint: true,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        linearMinHeight: 8,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeController,
      builder: (context, _) => DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) {
          final useDynamic =
              themeController.dynamicColorEnabled &&
              lightDynamic != null &&
              darkDynamic != null;
          return MaterialApp(
            title: '手环通知小说',
            debugShowCheckedModeBanner: false,
            themeMode: themeController.themeMode,
            theme: _buildTheme(
              Brightness.light,
              colorScheme: useDynamic ? lightDynamic : null,
            ),
            darkTheme: _buildTheme(
              Brightness.dark,
              colorScheme: useDynamic ? darkDynamic : null,
            ),
            themeAnimationDuration: const Duration(milliseconds: 360),
            themeAnimationCurve: Curves.easeOutCubic,
            home: startupScreenEnabled
                ? const StartupQuotePage()
                : const LibraryHomePage(),
          );
        },
      ),
    );
  }
}

class StartupQuotePage extends StatefulWidget {
  const StartupQuotePage({super.key});

  @override
  State<StartupQuotePage> createState() => _StartupQuotePageState();
}

class _StartupQuotePageState extends State<StartupQuotePage> {
  static const _fallbackQuote = '愿你出走半生，归来仍是少年。';
  String _quote = _fallbackQuote;
  String _source = '本地文案';
  bool _visible = false;
  StartupContentRecommendation _recommendation =
      StartupContentRecommendation.random;

  @override
  void initState() {
    super.initState();
    unawaited(_loadQuoteThenEnter());
  }

  Future<void> _loadQuoteThenEnter() async {
    final leaveAt = DateTime.now().add(const Duration(milliseconds: 1100));
    try {
      final index = await LocalAppStore.instance
          .loadStartupContentRecommendation();
      _recommendation =
          StartupContentRecommendation.values[index.clamp(
            0,
            StartupContentRecommendation.values.length - 1,
          )];
      final query = <String, String>{'encode': 'json'};
      if (_recommendation.apiCategory case final String category) {
        query['c'] = category;
      }
      final response = await http
          .get(
            Uri.https('v1.hitokoto.cn', '/', query),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(milliseconds: 700));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['hitokoto'] is String) {
          final text = (decoded['hitokoto'] as String).trim();
          final from = decoded['from'];
          final fromWho = decoded['from_who'];
          if (text.isNotEmpty && mounted) {
            final pieces = <String>[
              if (fromWho is String && fromWho.trim().isNotEmpty)
                fromWho.trim(),
              if (from is String && from.trim().isNotEmpty) from.trim(),
            ];
            setState(() {
              _quote = text;
              _source = pieces.isEmpty
                  ? '一言 · ${_recommendation.title}'
                  : '${pieces.join(' · ')} · ${_recommendation.title}';
            });
          }
        }
      }
    } catch (_) {
      // 网络不可用、接口超时或格式异常时保留本地文案，不阻塞启动。
    }
    if (!mounted) {
      return;
    }
    setState(() => _visible = true);
    final remaining = leaveAt.difference(DateTime.now());
    if (remaining.inMicroseconds > 0) {
      await Future<void>.delayed(remaining);
    }
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LibraryHomePage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primaryContainer,
              Theme.of(context).colorScheme.surface,
            ],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 520),
              curve: Curves.easeOutBack,
              tween: Tween(begin: 0.94, end: _visible ? 1 : 0.94),
              builder: (context, scale, child) => Opacity(
                opacity: _visible ? 1 : 0,
                child: Transform.scale(scale: scale, child: child),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_stories_outlined,
                    size: 42,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    '“$_quote”',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 14),
                  Text(_source, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 28),
                  Text(
                    '正在进入手环通知小说…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LibraryHomePage extends StatefulWidget {
  const LibraryHomePage({super.key});

  @override
  State<LibraryHomePage> createState() => _LibraryHomePageState();
}

class _LibraryHomePageState extends State<LibraryHomePage> {
  List<StoredLibraryBook> _books = const [];
  String? _selectedBookId;
  int _maxCharacters = 120;
  bool _compactSegmentContent = false;
  bool _removeEmojiFromSegments = false;
  bool _richSegmentContent = false;
  SendingConfig _sendingConfig = const SendingConfig.defaults();
  StoredSendingSession? _session;
  Map<String, StoredSendingSession> _sessionsByBook = const {};
  bool _isBackgroundRunning = false;
  bool _isSwitchingBook = false;
  bool _isCatalogImporting = false;
  bool _isRecoveringBackground = false;
  bool _isCheckingForUpdate = false;
  bool _isLoading = true;
  String? _startupError;
  String? _wearableBrandId;
  String? _wearableBrandName;
  late final AppLifecycleListener _lifecycleListener;
  late final Future<int> _appLaunchCount;

  StoredLibraryBook? get _selectedBook {
    for (final book in _books) {
      if (book.id == _selectedBookId) {
        return book;
      }
    }
    return _books.isEmpty ? null : _books.first;
  }

  List<String> get _selectedChunks {
    final book = _selectedBook;
    if (book == null) {
      return const [];
    }
    return book.customChunks ??
        NovelTextSplitter.split(
          book.text,
          maxCharacters: _maxCharacters,
          compactContent: _compactSegmentContent,
          removeEmoji: _removeEmojiFromSegments,
          richContent: _richSegmentContent,
        );
  }

  Future<void> _safeRestoreState() async {
    try {
      await _restoreState();
    } catch (error) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _startupError = error.toString();
        });
      }
    }
  }

  Future<void> _resetStartupData() async {
    await LocalAppStore.instance.saveLibrary(
      books: const [],
      selectedBookId: null,
    );
    await LocalAppStore.instance.clearSendingSession();
    if (mounted) {
      setState(() {
        _books = const [];
        _selectedBookId = null;
        _session = null;
        _startupError = null;
        _isLoading = false;
      });
    }
  }

  bool get _hasSelectedResumableSession =>
      _session?.bookId == _selectedBook?.id && _session?.canResume == true;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.resumed) {
          unawaited(_refreshAndRecoverBackgroundSession());
        } else {
          unawaited(_persistLibrary());
        }
      },
    );
    FlutterForegroundTask.addTaskDataCallback(_onBackgroundData);
    _appLaunchCount = LocalAppStore.instance.registerAppLaunch();
    _safeRestoreState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_checkForAppUpdate()),
    );
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onBackgroundData);
    _lifecycleListener.dispose();
    super.dispose();
  }

  SendingMode _modeFromIndex(int index) {
    return SendingMode.values[index.clamp(0, SendingMode.values.length - 1)];
  }

  Future<void> _restoreState() async {
    final values = await Future.wait<Object?>([
      LocalAppStore.instance.loadDocument(),
      LocalAppStore.instance.loadLibrary(),
      LocalAppStore.instance.loadSendingSession(),
      LocalAppStore.instance.loadSendingSessions(),
      LocalAppStore.instance.hasCompletedOnboarding(),
    ]);
    final document = values[0] as StoredNovelDocument;
    final library = values[1] as StoredLibrary;
    final session = values[2] as StoredSendingSession?;
    final sessionsByBook = values[3] as Map<String, StoredSendingSession>;
    final onboardingCompleted = values[4] as bool;
    if (!mounted) {
      return;
    }
    setState(() {
      _books = library.books;
      _selectedBookId = library.selectedBookId;
      _maxCharacters = document.maxCharacters;
      _compactSegmentContent = document.compactSegmentContent;
      _removeEmojiFromSegments = document.removeEmojiFromSegments;
      _richSegmentContent = document.richSegmentContent;
      _sendingConfig = SendingConfig(
        mode: _modeFromIndex(document.modeIndex),
        intervalMilliseconds: document.intervalMilliseconds,
      );
      _sessionsByBook = sessionsByBook;
      _session = _sessionForBook(
        bookId: library.selectedBookId,
        sessionsByBook: sessionsByBook,
        legacySession: session,
      );
      _isBackgroundRunning = false;
      _wearableBrandId = document.wearablePresetBrandId;
      _wearableBrandName = document.wearablePresetBrandName;
      _isLoading = false;
    });
    unawaited(_refreshAndRecoverBackgroundSession());
    if (!onboardingCompleted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openOnboarding());
    }
  }

  Future<void> _refreshAndRecoverBackgroundSession() async {
    await _refreshSendingState();
    final session = _session;
    if (session?.canResume == true && !_isBackgroundRunning) {
      await _recoverBackgroundSession(session!);
    }
  }

  Future<void> _recoverBackgroundSession(StoredSendingSession session) async {
    if (_isRecoveringBackground ||
        session.nextIndex >= session.chunks.length ||
        session.chunks.isEmpty) {
      return;
    }
    _isRecoveringBackground = true;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        if (mounted) {
          setState(() => _isBackgroundRunning = true);
        }
        return;
      }
      await BackgroundNovelSender.start(
        bookId: session.bookId,
        chunks: session.chunks,
        intervalMilliseconds: session.intervalMilliseconds,
        startIndex: session.nextIndex,
        notificationBaseId: session.notificationBaseId,
      );
      if (mounted) {
        setState(() => _isBackgroundRunning = true);
      }
    } catch (_) {
      // The resumable session is retained for a later foreground restart.
    } finally {
      _isRecoveringBackground = false;
    }
  }

  Future<void> _persistLibrary() async {
    await LocalAppStore.instance.saveLibrary(
      books: _books,
      selectedBookId: _selectedBookId,
    );
    await LocalAppStore.instance.saveSettings(
      maxCharacters: _maxCharacters,
      modeIndex: _sendingConfig.mode.index,
      intervalMilliseconds: _sendingConfig.intervalMilliseconds,
      compactSegmentContent: _compactSegmentContent,
      removeEmojiFromSegments: _removeEmojiFromSegments,
      richSegmentContent: _richSegmentContent,
    );
  }

  StoredSendingSession? _sessionForBook({
    required String? bookId,
    required Map<String, StoredSendingSession> sessionsByBook,
    required StoredSendingSession? legacySession,
  }) {
    final mappedSession = bookId == null ? null : sessionsByBook[bookId];
    if (mappedSession != null) {
      return mappedSession;
    }
    if (legacySession?.canResume == true &&
        (legacySession!.bookId == null || legacySession.bookId == bookId)) {
      return legacySession;
    }
    return null;
  }

  Future<void> _refreshSendingState() async {
    final session = await LocalAppStore.instance.loadSendingSession();
    final sessionsByBook = await LocalAppStore.instance.loadSendingSessions();
    final running = await FlutterForegroundTask.isRunningService;
    if (mounted) {
      setState(() {
        _sessionsByBook = sessionsByBook;
        _session = _sessionForBook(
          bookId: _selectedBookId,
          sessionsByBook: sessionsByBook,
          legacySession: session,
        );
        _isBackgroundRunning = running;
      });
    }
  }

  void _onBackgroundData(Object data) {
    if (data is! Map) {
      return;
    }
    final type = data['type'];
    final eventBookId = data['bookId'];
    if (eventBookId is String && _session?.bookId != eventBookId) {
      return;
    }
    if (type == 'progress' && data['sent'] is int && _session != null) {
      final nextIndex = data['sent'] as int;
      final current = _session!;
      if (mounted) {
        setState(() {
          final updated = StoredSendingSession(
            bookId: current.bookId,
            chunks: current.chunks,
            nextIndex: nextIndex,
            modeIndex: current.modeIndex,
            intervalMilliseconds: current.intervalMilliseconds,
            notificationBaseId: current.notificationBaseId,
          );
          _session = updated;
          if (updated.bookId != null) {
            _sessionsByBook = {..._sessionsByBook, updated.bookId!: updated};
          }
          _isBackgroundRunning = true;
        });
      }
    } else if (type == 'complete') {
      if (mounted) {
        setState(() {
          _session = null;
          _isBackgroundRunning = false;
        });
      }
    } else if ((type == 'stopped' || type == 'interrupted') && mounted) {
      // Keep the persisted session; it will be resumed when the app returns to foreground.
      setState(() => _isBackgroundRunning = false);
    }
  }

  List<String> _captureInitialChunks(String text) {
    // Text recovery always returns to the original import baseline, rather than
    // reapplying any later character-limit or content-processing settings.
    return NovelTextSplitter.split(text, maxCharacters: 120);
  }

  Future<void> _importBooks() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty) {
        return;
      }
      final imported = <StoredLibraryBook>[];
      final rejectedFiles = <String>[];
      for (final file in files) {
        try {
          final decoded = await LocalBookImporter.decode(file);
          imported.add(
            StoredLibraryBook(
              id: LocalAppStore.createBookId(file.name, decoded.text),
              text: decoded.text,
              fileName: file.name,
              customChunks: null,
              initialChunks: _captureInitialChunks(decoded.text),
            ),
          );
        } on FormatException {
          rejectedFiles.add(file.name);
        }
      }
      if (imported.isEmpty || !mounted) {
        if (rejectedFiles.isNotEmpty) {
          _showMessage(
            '未导入任何图书：${rejectedFiles.join('、')} 格式不受支持。请重新选择 TXT、TEXT、Markdown、LOG、JSON 或 EPUB 图书文件。',
          );
        } else {
          _showMessage('未找到可导入的文本图书。');
        }
        return;
      }
      final byIdentity = <String, StoredLibraryBook>{
        for (final book in _books)
          '${book.fileName}:${book.text.hashCode}': book,
      };
      for (final book in imported) {
        byIdentity['${book.fileName}:${book.text.hashCode}'] = book;
      }
      setState(() {
        _books = byIdentity.values.toList(growable: false);
        _selectedBookId = imported.last.id;
      });
      await _persistLibrary();
      final rejectedNotice = rejectedFiles.isEmpty
          ? ''
          : '；已跳过 ${rejectedFiles.length} 个不支持格式的文件，请重新选择 TXT、TEXT、Markdown、LOG、JSON 或 EPUB 图书文件。';
      _showMessage('已导入 ${imported.length} 本图书，并选中最新导入的图书$rejectedNotice');
    } on PlatformException catch (error) {
      _showMessage('无法打开文件选择器：${error.message ?? error.code}');
    } on FormatException catch (error) {
      _showMessage(error.message.toString());
    } catch (error) {
      _showMessage('导入失败：$error');
    }
  }

  Future<void> _showImportOptions() async {
    if (_isCatalogImporting) {
      _showMessage('目录下载或导入正在进行，请完成或取消当前流程后再导入其他图书。');
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('导入图书', style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('请选择图书来源。网络导入可选择已在设置页配置的 API，或搜索公共领域开源书源。'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.of(sheetContext).pop('local'),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('本地导入图书（TXT / EPUB 等）'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(sheetContext).pop('network'),
                icon: const Icon(Icons.language_outlined),
                label: const Text('网络导入图书'),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == 'local') {
      await _importBooks();
    } else if (action == 'network') {
      await _showNetworkImportSources();
    }
  }

  Future<void> _showNetworkImportSources() async {
    if (_isCatalogImporting) {
      _showMessage('网络下载或导入正在进行，请完成或取消当前流程后再试。');
      return;
    }
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '网络导入图书',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text('请选择来源。两种来源均会先显示详情与确认步骤，再下载、校验并自动导入。'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.of(sheetContext).pop('api'),
                icon: const Icon(Icons.api_outlined),
                label: const Text('从已配置 API 导入'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(sheetContext).pop('catalog'),
                icon: const Icon(Icons.travel_explore_outlined),
                label: const Text('搜索开源图书目录'),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == 'api') {
      await _importFromNetwork();
    } else if (source == 'catalog') {
      await _searchPublicDomainBooks();
    }
  }

  Future<void> _importFromNetwork() async {
    final settings = await LocalAppStore.instance.loadNetworkImportSettings();
    if (!mounted) {
      return;
    }
    if (settings.url.trim().isEmpty) {
      _showMessage('请先在“设置 → API 导入详情”中填写图书 API 地址。');
      return;
    }
    final request = NetworkImportRequest(
      url: settings.url,
      title: settings.title,
      authorization: settings.authorization,
    );
    final confirmed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => NetworkApiImportDetailPage(request: request),
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _isCatalogImporting = true);
    try {
      final imported = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CatalogBookDownloadPage.forApi(
            request: request,
            onImport: _importCatalogBook,
          ),
        ),
      );
      if (imported == true && mounted) {
        await _openNetworkBookManager(focusBookId: _selectedBookId);
      }
    } finally {
      if (mounted) {
        setState(() => _isCatalogImporting = false);
      }
    }
  }

  Future<void> _searchPublicDomainBooks() async {
    if (_isCatalogImporting) {
      _showMessage('目录下载或导入正在进行，请完成或取消当前流程后再试。');
      return;
    }
    final selected = await Navigator.of(context).push<PublicDomainBookResult>(
      MaterialPageRoute(builder: (_) => const PublicDomainBookSearchPage()),
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() => _isCatalogImporting = true);
    try {
      final imported = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CatalogBookDownloadPage(
            book: selected,
            onImport: _importCatalogBook,
          ),
        ),
      );
      if (imported == true && mounted) {
        await _openNetworkBookManager(focusBookId: _selectedBookId);
      }
    } finally {
      if (mounted) {
        setState(() => _isCatalogImporting = false);
      }
    }
  }

  Future<void> _importCatalogBook(DownloadedNetworkBook downloaded) async {
    await _pauseTaskBeforeBookSwitch();
    if (!mounted) {
      throw const FormatException('应用已退出，无法将下载内容写入书库。');
    }
    final imported = StoredLibraryBook(
      id: LocalAppStore.createBookId(
        '${downloaded.title}.txt',
        downloaded.text,
      ),
      text: downloaded.text,
      fileName: '${downloaded.title}.txt',
      customChunks: null,
      initialChunks: _captureInitialChunks(downloaded.text),
      source: BookStorageSource.network,
    );
    final byIdentity = <String, StoredLibraryBook>{
      for (final book in _books) '${book.fileName}:${book.text.hashCode}': book,
      '${imported.fileName}:${imported.text.hashCode}': imported,
    };
    setState(() {
      _books = byIdentity.values.toList(growable: false);
      _selectedBookId = imported.id;
      _session = _sessionsByBook[imported.id];
    });
    await _persistLibrary();
  }

  Future<void> _openNetworkBookManager({String? focusBookId}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => NetworkBookStoragePage(
          books: _books
              .where((book) => book.source == BookStorageSource.network)
              .toList(growable: false),
          selectedBookId: focusBookId ?? _selectedBookId,
          onDelete: _deleteNetworkBook,
        ),
      ),
    );
  }

  Future<void> _deleteNetworkBook(StoredLibraryBook book) async {
    if (book.source != BookStorageSource.network) {
      return;
    }
    if (book.id == _selectedBookId) {
      await _pauseTaskBeforeBookSwitch();
    }
    await LocalAppStore.instance.removeSendingSessionForBook(book.id);
    if (!mounted) {
      return;
    }
    final remaining = _books
        .where((item) => item.id != book.id)
        .toList(growable: false);
    final remainingSessions = Map<String, StoredSendingSession>.from(
      _sessionsByBook,
    )..remove(book.id);
    final nextSelectedId = remaining.any((item) => item.id == _selectedBookId)
        ? _selectedBookId
        : (remaining.isEmpty ? null : remaining.first.id);
    setState(() {
      _books = remaining;
      _selectedBookId = nextSelectedId;
      _sessionsByBook = remainingSessions;
      _session = _sessionForBook(
        bookId: nextSelectedId,
        sessionsByBook: remainingSessions,
        legacySession: null,
      );
      _isBackgroundRunning = false;
    });
    await _persistLibrary();
  }

  Future<void> _pauseTaskBeforeBookSwitch() async {
    final activeSession = await LocalAppStore.instance.loadSendingSession();
    final serviceRunning = await FlutterForegroundTask.isRunningService;
    if (activeSession?.canResume != true && !serviceRunning) {
      return;
    }
    if (mounted) {
      setState(() => _isSwitchingBook = true);
    }
    try {
      // The background worker persists its next index before each notification.
      // Stop it before changing the selected book so no new segment can cross books.
      if (serviceRunning) {
        await BackgroundNovelSender.stop();
      }
      await _refreshSendingState();
    } finally {
      if (mounted) {
        setState(() => _isSwitchingBook = false);
      }
    }
  }

  Future<void> _openLibrarySelector() async {
    if (_isCatalogImporting) {
      _showMessage('目录下载或导入正在进行，暂时不能切换图书。');
      return;
    }
    final selectedId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('选择要发送的图书'),
              subtitle: Text('发送、预览和断点续传都以当前选择的图书为准。'),
            ),
            for (final book in _books)
              ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: Text(
                  BookMetadataResolver.resolve(
                    fileName: book.fileName,
                    text: book.text,
                  ).title,
                ),
                subtitle: Text(
                  book.fileName ?? '未命名 TXT',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: book.id == _selectedBookId
                    ? const Icon(Icons.check_circle_outline)
                    : null,
                onTap: _isSwitchingBook
                    ? null
                    : () => Navigator.of(sheetContext).pop(book.id),
              ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('导入更多本地图书'),
              onTap: () => Navigator.of(sheetContext).pop('__import__'),
            ),
          ],
        ),
      ),
    );
    if (selectedId == null) {
      return;
    }
    if (selectedId == '__import__') {
      await _showImportOptions();
      return;
    }
    await _pauseTaskBeforeBookSwitch();
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedBookId = selectedId;
      _session = _sessionsByBook[selectedId];
    });
    await _persistLibrary();
    _showMessage('已切换图书；如有进行中的传输，断点已先保存并暂停。');
  }

  Future<void> _openSettings() async {
    final result = await Navigator.of(context).push<AppSettingsResult>(
      MaterialPageRoute(
        builder: (_) => UnifiedSettingsPage(
          initialConfig: _sendingConfig,
          initialMaxCharacters: _maxCharacters,
          initialCompactSegmentContent: _compactSegmentContent,
          initialRemoveEmojiFromSegments: _removeEmojiFromSegments,
          initialRichSegmentContent: _richSegmentContent,
        ),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    final requiresResegment =
        _maxCharacters != result.maxCharacters ||
        _compactSegmentContent != result.compactSegmentContent ||
        _removeEmojiFromSegments != result.removeEmojiFromSegments ||
        _richSegmentContent != result.richSegmentContent;
    setState(() {
      _sendingConfig = result.config;
      _maxCharacters = result.maxCharacters;
      _compactSegmentContent = result.compactSegmentContent;
      _removeEmojiFromSegments = result.removeEmojiFromSegments;
      _richSegmentContent = result.richSegmentContent;
      if (requiresResegment) {
        _books = _books
            .map(
              (book) => StoredLibraryBook(
                id: book.id,
                text: book.text,
                fileName: book.fileName,
                customChunks: null,
                initialChunks: book.initialChunks,
                source: book.source,
              ),
            )
            .toList(growable: false);
      }
    });
    await _persistLibrary();
  }

  Future<void> _openPreview() async {
    final book = _selectedBook;
    final chunks = _selectedChunks;
    if (book == null || chunks.isEmpty) {
      _showMessage('请先选择并导入一本图书。');
      return;
    }
    final adjusted = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => SegmentPreviewPage(
          chunks: chunks,
          maxCharacters: _maxCharacters,
          completedCount: _session?.nextIndex ?? 0,
        ),
      ),
    );
    if (adjusted == null || !mounted) {
      return;
    }
    setState(() {
      _books = _books
          .map(
            (item) => item.id == book.id
                ? StoredLibraryBook(
                    id: item.id,
                    text: item.text,
                    fileName: item.fileName,
                    customChunks: adjusted,
                    initialChunks: item.initialChunks,
                    source: item.source,
                  )
                : item,
          )
          .toList(growable: false);
    });
    await _persistLibrary();
  }

  Future<void> _restoreDefaultSegments() async {
    final book = _selectedBook;
    if (book == null) {
      _showMessage('请先选择并导入一本图书。');
      return;
    }
    if (book.customChunks == null) {
      _showMessage('当前图书已经使用默认分段规则。');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.restore_page_outlined),
        title: const Text('恢复默认分段？'),
        content: const Text(
          '将清除当前图书在完整分段预览、批量调整或 AI 总结后保存的自定义分段，恢复为刚导入时未启用内容处理功能的基础分段。该图书的发送断点也会清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.restore_page_outlined),
            label: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _pauseTaskBeforeBookSwitch();
    await LocalAppStore.instance.removeSendingSessionForBook(book.id);
    if (!mounted) {
      return;
    }
    final remainingSessions = Map<String, StoredSendingSession>.from(
      _sessionsByBook,
    )..remove(book.id);
    final initialChunks =
        book.initialChunks ?? _captureInitialChunks(book.text);
    setState(() {
      _books = _books
          .map(
            (item) => item.id == book.id
                ? StoredLibraryBook(
                    id: item.id,
                    text: item.text,
                    fileName: item.fileName,
                    customChunks: initialChunks,
                    initialChunks: item.initialChunks ?? initialChunks,
                    source: item.source,
                  )
                : item,
          )
          .toList(growable: false);
      _sessionsByBook = remainingSessions;
      _session = _sessionForBook(
        bookId: book.id,
        sessionsByBook: remainingSessions,
        legacySession: null,
      );
      _isBackgroundRunning = false;
    });
    await _persistLibrary();
    _showMessage('已恢复为刚导入时的基础分段，并清除当前图书的发送断点。');
  }

  Future<void> _startSelectedBook() async {
    if (_isCatalogImporting) {
      _showMessage('目录下载或导入正在进行，请完成或取消后再开始发送。');
      return;
    }
    final book = _selectedBook;
    final chunks = _selectedChunks;
    if (book == null || chunks.isEmpty) {
      _showMessage('请先选择并导入一本图书。');
      return;
    }
    final baseId = NotificationService.createBaseId(chunks.length);
    await LocalAppStore.instance.saveSendingSession(
      bookId: book.id,
      chunks: chunks,
      nextIndex: 0,
      modeIndex: _sendingConfig.mode.index,
      intervalMilliseconds: _sendingConfig.intervalMilliseconds,
      notificationBaseId: baseId,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      final started = StoredSendingSession(
        bookId: book.id,
        chunks: chunks,
        nextIndex: 0,
        modeIndex: _sendingConfig.mode.index,
        intervalMilliseconds: _sendingConfig.intervalMilliseconds,
        notificationBaseId: baseId,
      );
      _session = started;
      _sessionsByBook = {..._sessionsByBook, book.id: started};
    });
    await _openTask(
      bookId: book.id,
      chunks: chunks,
      config: _sendingConfig,
      initialIndex: 0,
      notificationBaseId: baseId,
      startImmediately: true,
    );
  }

  Future<void> _togglePauseContinue() async {
    if (_isCatalogImporting) {
      _showMessage('目录下载或导入正在进行，请完成或取消后再操作发送任务。');
      return;
    }
    final session = _session;
    if (!_hasSelectedResumableSession || session == null) {
      _showMessage('当前选择的图书没有可继续的发送任务。');
      return;
    }
    if (_isBackgroundRunning) {
      await BackgroundNovelSender.stop();
      await _refreshSendingState();
      _showMessage('已暂停发送并保存断点。');
      return;
    }
    final config = SendingConfig(
      mode: _modeFromIndex(session.modeIndex),
      intervalMilliseconds: session.intervalMilliseconds,
    );
    await _openTask(
      bookId: session.bookId ?? _selectedBookId ?? '',
      chunks: session.chunks,
      config: config,
      initialIndex: session.nextIndex,
      notificationBaseId: session.notificationBaseId,
      startImmediately: true,
    );
  }

  Future<void> _openTask({
    required String bookId,
    required List<String> chunks,
    required SendingConfig config,
    required int initialIndex,
    required int notificationBaseId,
    required bool startImmediately,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SendingTaskPage(
          bookId: bookId,
          chunks: chunks,
          config: config,
          initialIndex: initialIndex,
          notificationBaseId: notificationBaseId,
          startImmediately: startImmediately,
        ),
      ),
    );
    await _refreshSendingState();
  }

  Future<void> _requestPermission() async {
    try {
      final granted = await NotificationService.instance.requestPermission();
      if (mounted) {
        _showMessage(
          granted ? '通知权限已授予，可以发送测试通知。' : '通知尚未开启；请点击“通知设置”在系统页面中允许通知。',
        );
      }
    } catch (error) {
      _showMessage('申请通知权限失败：$error');
    }
  }

  Future<void> _openNotificationSettings() async {
    try {
      await NotificationService.instance.openNotificationSettings();
    } catch (error) {
      _showMessage(error.toString());
    }
  }

  Future<void> _sendTestNotification() async {
    try {
      final granted = await NotificationService.instance.requestPermission();
      if (!granted) {
        _showMessage('未获得通知权限，请在系统设置中开启后重试。');
        return;
      }
      await NotificationService.instance.showChunk(
        id: 923456,
        index: 0,
        total: 1,
        text: '这是一条测试通知。若手环已镜像手机通知，应能收到本条内容。',
      );
      _showMessage('测试通知已发送，请检查手机通知栏和手环。');
    } catch (error) {
      _showMessage('测试通知发送失败：$error');
    }
  }

  Future<void> _openOnboarding() async {
    if (!mounted) {
      return;
    }
    final result = await Navigator.of(context).push<OnboardingResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const OnboardingPage(),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    setState(() {
      _maxCharacters = result.maxCharacters;
      _books = _books
          .map(
            (book) => StoredLibraryBook(
              id: book.id,
              text: book.text,
              fileName: book.fileName,
              customChunks: null,
              initialChunks: book.initialChunks,
              source: book.source,
            ),
          )
          .toList(growable: false);
      _session = null;
    });
    await LocalAppStore.instance.clearSendingSession();
    await _persistLibrary();
    _showMessage('已应用 ${result.maxCharacters} 字/段的手环品牌预设；已清除旧分段和断点。');
  }

  Future<void> _openBrandPicker() async {
    final selected = await Navigator.of(context).push<WearableManagerOption>(
      MaterialPageRoute(
        builder: (_) => BrandPickerPage(initialBrandId: _wearableBrandId),
      ),
    );
    if (selected == null || !mounted) {
      return;
    }
    await LocalAppStore.instance.saveWearablePreset(
      enabled: true,
      brandId: selected.id,
      brandName: selected.brandName,
      maxCharacters: selected.recommendedMaxCharacters,
    );
    await LocalAppStore.instance.clearSendingSession();
    if (!mounted) {
      return;
    }
    setState(() {
      _wearableBrandId = selected.id;
      _wearableBrandName = selected.brandName;
      _maxCharacters = selected.recommendedMaxCharacters;
      _books = _books
          .map(
            (book) => StoredLibraryBook(
              id: book.id,
              text: book.text,
              fileName: book.fileName,
              customChunks: null,
              initialChunks: book.initialChunks,
              source: book.source,
            ),
          )
          .toList(growable: false);
      _session = null;
      _isBackgroundRunning = false;
    });
    await _persistLibrary();
    _showMessage(
      '已切换为${selected.brandName}预设：${selected.recommendedMaxCharacters} 字/段；已清除旧分段和断点。',
    );
  }

  Future<void> _checkForAppUpdate({bool forceUpdateDetails = false}) async {
    if (_isCheckingForUpdate) return;
    if (mounted) {
      setState(() => _isCheckingForUpdate = true);
    }
    try {
      final sourceIndex = await LocalAppStore.instance.loadUpdateSourceIndex();
      final automaticEnabled = await LocalAppStore.instance
          .isAutomaticUpdateCheckEnabled();
      if (!forceUpdateDetails && !automaticEnabled) {
        return;
      }
      final source = AppUpdateSource
          .values[sourceIndex.clamp(0, AppUpdateSource.values.length - 1)];
      final update = await AppUpdateService.checkForUpdate(source: source);
      if (!mounted) return;
      if (update == null) {
        return;
      }
      final appLaunchCount = await _appLaunchCount;
      final shouldPrompt =
          forceUpdateDetails ||
          await AppUpdateService.shouldPrompt(
            update,
            appLaunchCount: appLaunchCount,
          );
      if (!mounted || !shouldPrompt) return;
      if (update.isPrerelease) {
        final acceptedRisk = await _showPrereleaseUpdateRiskDialog(update);
        if (!mounted || !acceptedRisk) {
          return;
        }
      }
      final immediate = await _showUpdateDialog(
        update,
        appLaunchCount: appLaunchCount,
      );
      if (immediate && mounted) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => AppUpdateDownloadPage(
              update: update,
              openInstaller: NotificationService.instance.openDownloadedApk,
            ),
          ),
        );
      }
    } on FormatException catch (error) {
      if (forceUpdateDetails && mounted) {
        _showMessage(error.message.toString());
      }
    } catch (_) {
      if (forceUpdateDetails && mounted) {
        _showMessage('检查更新失败，请检查网络后重试。');
      }
    } finally {
      if (mounted) {
        setState(() => _isCheckingForUpdate = false);
      }
    }
  }

  Future<bool> _showPrereleaseUpdateRiskDialog(AppUpdateInfo update) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.warning_amber_outlined),
        title: Text('测试版更新提示：${update.name}'),
        content: const Text(
          '该更新为测试版，可能包含未预期的功能变化、兼容性问题或稳定性风险。建议先备份重要内容，并仅在接受这些风险后继续查看更新详情和安装选项。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('暂不查看'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('继续查看'),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  Future<bool> _showUpdateDialog(
    AppUpdateInfo update, {
    required int appLaunchCount,
  }) async {
    final selected = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.system_update_alt_outlined),
        title: Text('发现新版本：${update.name}'),
        content: SingleChildScrollView(
          child: Text(
            update.notes.isEmpty
                ? '发现可下载的新版本。立即更新会下载 APK 并打开系统安装界面。'
                : '${update.notes}\n\n立即更新会显示下载进度，并在完成后打开系统安装界面。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await AppUpdateService.defer(
                update,
                appLaunchCount: appLaunchCount,
              );
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop(false);
              }
            },
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              unawaited(AppUpdateService.clearDeferred());
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
    return selected ?? false;
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_startupError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('手环通知小说')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 56),
                const SizedBox(height: 16),
                const Text('书库加载失败'),
                const SizedBox(height: 8),
                const Text(
                  '可以重试加载；若本地旧数据异常，也可以清空书库后重新导入图书。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                      _startupError = null;
                    });
                    _safeRestoreState();
                  },
                  child: const Text('重试加载'),
                ),
                TextButton(
                  onPressed: _resetStartupData,
                  child: const Text('清空书库并继续'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    final book = _selectedBook;
    final chunks = _selectedChunks;
    final metadata = BookMetadataResolver.resolve(
      fileName: book?.fileName,
      text: book?.text ?? '',
    );
    final session = _hasSelectedResumableSession ? _session : null;
    final progress =
        (session == null || session.chunks.isEmpty
                ? 0.0
                : session.nextIndex / session.chunks.length)
            .clamp(0.0, 1.0)
            .toDouble();

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的书库'),
        actions: [
          _isCheckingForUpdate
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                )
              : IconButton(
                  tooltip: '检查更新',
                  onPressed: () => _checkForAppUpdate(forceUpdateDetails: true),
                  icon: const Icon(Icons.system_update_alt_outlined),
                ),
          IconButton(
            tooltip: _wearableBrandName == null
                ? '选择手环品牌'
                : '切换手环品牌：$_wearableBrandName',
            onPressed: _openBrandPicker,
            icon: BrandLogoIcon(brandId: _wearableBrandId, size: 24),
          ),
          IconButton(
            tooltip: '管理书源下载',
            onPressed:
                _books.any((book) => book.source == BookStorageSource.network)
                ? _openNetworkBookManager
                : null,
            icon: const Icon(Icons.inventory_2_outlined),
          ),
          IconButton(
            tooltip: '选择图书',
            onPressed: _books.isEmpty ? null : _openLibrarySelector,
            icon: const Icon(Icons.library_books_outlined),
          ),
          IconButton(
            tooltip: '导入图书',
            onPressed: _showImportOptions,
            icon: const Icon(Icons.add_to_photos_outlined),
          ),
          IconButton(
            tooltip: '统一设置管理',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            GestureDetector(
              onTap: _openLibrarySelector,
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _BookCover(title: metadata.title, hasBook: book != null),
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              metadata.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              metadata.introduction,
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              book == null
                                  ? '点击选择图书，或使用右上角按钮导入 TXT。'
                                  : '当前第 ${_books.indexWhere((item) => item.id == book.id) + 1}/${_books.length} 本 · ${chunks.length} 段',
                              style: theme.textTheme.labelMedium,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (session != null)
              _HomeProgressCard(
                session: session,
                progress: progress,
                isRunning: _isBackgroundRunning,
              ),
            if (session != null) const SizedBox(height: 14),
            if (book != null)
              OutlinedButton.icon(
                onPressed: _openPreview,
                icon: const Icon(Icons.preview_outlined),
                label: const Text('查看完整分段与批量调整'),
              ),
            if (book != null) const SizedBox(height: 8),
            if (book != null)
              OutlinedButton.icon(
                onPressed: _restoreDefaultSegments,
                icon: const Icon(Icons.restore_page_outlined),
                label: const Text('文本恢复（恢复默认分段）'),
              ),
            if (book != null) const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: session == null
                  ? (book == null ? null : _startSelectedBook)
                  : _togglePauseContinue,
              style: session == null
                  ? null
                  : FilledButton.styleFrom(
                      backgroundColor: _isBackgroundRunning
                          ? theme.colorScheme.error
                          : theme.colorScheme.secondary,
                      foregroundColor: _isBackgroundRunning
                          ? theme.colorScheme.onError
                          : theme.colorScheme.onSecondary,
                    ),
              icon: Icon(
                session == null
                    ? Icons.send_outlined
                    : _isBackgroundRunning
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
              label: Text(
                session == null ? '发送' : (_isBackgroundRunning ? '暂停' : '继续'),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: _requestPermission,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('通知权限'),
                ),
                TextButton.icon(
                  onPressed: _sendTestNotification,
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('发送测试通知'),
                ),
                TextButton.icon(
                  onPressed: _openNotificationSettings,
                  icon: const Icon(Icons.settings_applications_outlined),
                  label: const Text('通知设置'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeProgressCard extends StatelessWidget {
  const _HomeProgressCard({
    required this.session,
    required this.progress,
    required this.isRunning,
  });

  final StoredSendingSession session;
  final double progress;
  final bool isRunning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  isRunning ? Icons.sync_outlined : Icons.pause_circle_outline,
                ),
                const SizedBox(width: 8),
                Text(
                  isRunning ? '正在发送' : '发送已暂停',
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  '${(progress * 100).toStringAsFixed(2)}%',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 10),
            Text(
              '已发送 ${session.nextIndex}/${session.chunks.length} 段 · 剩余 ${session.chunks.length - session.nextIndex} 段',
            ),
          ],
        ),
      ),
    );
  }
}

class _BookCover extends StatelessWidget {
  const _BookCover({required this.title, required this.hasBook});

  final String title;
  final bool hasBook;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final titleRunes = title.runes.toList();
    final shortTitle = titleRunes.length > 12
        ? '${String.fromCharCodes(titleRunes.take(12))}…'
        : title;
    return Container(
      width: 112,
      height: 164,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: hasBook
              ? [const Color(0xFF123B4A), const Color(0xFF2C6A73)]
              : [
                  colorScheme.outlineVariant,
                  colorScheme.surfaceContainerHighest,
                ],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(3, 5),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              hasBook ? Icons.menu_book_outlined : Icons.add_circle_outline,
              color: hasBook ? Colors.white : colorScheme.onSurfaceVariant,
            ),
            const Spacer(),
            Text(
              shortTitle,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: hasBook ? Colors.white : colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WearableManagerOption {
  const WearableManagerOption({
    required this.id,
    required this.brandName,
    required this.appName,
    required this.icon,
    required this.recommendedMaxCharacters,
    this.logoAssetPath,
    this.canLaunchManager = true,
  });

  final String id;
  final String brandName;
  final String appName;
  final IconData icon;
  final int recommendedMaxCharacters;
  final String? logoAssetPath;
  final bool canLaunchManager;
}

class BrandLogoIcon extends StatelessWidget {
  const BrandLogoIcon({required this.brandId, this.size = 28, super.key});

  final String? brandId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final options = _OnboardingPageState._wearableManagerOptions;
    final option = options.where((item) => item.id == brandId).firstOrNull;
    if (option?.logoAssetPath == null) {
      return Icon(option?.icon ?? Icons.watch_outlined, size: size);
    }
    return Semantics(
      label: '${option!.brandName}品牌标识',
      child: SizedBox(
        width: size,
        height: size,
        child: Image.asset(
          option.logoAssetPath!,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}

class BrandPickerPage extends StatelessWidget {
  const BrandPickerPage({required this.initialBrandId, super.key});

  final String? initialBrandId;

  @override
  Widget build(BuildContext context) {
    final options = _OnboardingPageState._wearableManagerOptions;
    return Scaffold(
      appBar: AppBar(title: const Text('切换手环品牌')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final option = options[index];
          final selected = option.id == initialBrandId;
          return Card(
            color: selected
                ? Theme.of(context).colorScheme.secondaryContainer
                : null,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: BrandLogoIcon(brandId: option.id, size: 38),
              title: Text(option.brandName),
              subtitle: Text(
                '${option.appName} · ${option.recommendedMaxCharacters} 字/段预设',
              ),
              trailing: selected
                  ? Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pop(option),
            ),
          );
        },
      ),
    );
  }
}

class OnboardingResult {
  const OnboardingResult({required this.maxCharacters});

  final int maxCharacters;
}

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  var _step = 0;
  bool? _notificationGranted;
  bool _requestingPermission = false;
  int _permissionStateVersion = 0;
  WearableManagerOption? _selectedWearableManager;
  bool _openingWearableManager = false;
  String? _wearableManagerMessage;
  Timer? _donationTimer;
  int _donationSeconds = 5;
  final PageController _onboardingPaymentController = PageController();
  int _onboardingPaymentIndex = 0;
  StoredAiSettings? _onboardingAiSettings;
  bool _isLoadingOnboardingAiSettings = true;

  static const _wearableManagerOptions = <WearableManagerOption>[
    WearableManagerOption(
      id: 'xiaomi',
      brandName: '小米',
      appName: 'Mi Fitness / Zepp Life',
      icon: Icons.watch_outlined,
      recommendedMaxCharacters: 160,
      logoAssetPath: 'assets/images/brand_logos/xiaomi_logo.png',
    ),
    WearableManagerOption(
      id: 'huawei',
      brandName: '华为',
      appName: '华为运动健康',
      icon: Icons.favorite_outline,
      recommendedMaxCharacters: 80,
      logoAssetPath: 'assets/images/brand_logos/huawei_logo.png',
    ),
    WearableManagerOption(
      id: 'honor',
      brandName: '荣耀',
      appName: '荣耀运动健康',
      icon: Icons.health_and_safety_outlined,
      recommendedMaxCharacters: 80,
      logoAssetPath: 'assets/images/brand_logos/honor_logo.png',
    ),
    WearableManagerOption(
      id: 'oppo',
      brandName: 'OPPO',
      appName: 'OHealth',
      icon: Icons.directions_run_outlined,
      recommendedMaxCharacters: 100,
      logoAssetPath: 'assets/images/brand_logos/oppo_logo.png',
    ),
    WearableManagerOption(
      id: 'vivo',
      brandName: 'vivo',
      appName: 'Origin Health',
      icon: Icons.monitor_heart_outlined,
      recommendedMaxCharacters: 100,
      logoAssetPath: 'assets/images/brand_logos/vivo_logo.png',
    ),
    WearableManagerOption(
      id: 'other',
      brandName: '其他品牌',
      appName: '你的手环管理软件',
      icon: Icons.devices_other_outlined,
      recommendedMaxCharacters: 60,
      canLaunchManager: false,
    ),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_readNotificationStatus());
    unawaited(_loadOnboardingAiSettings());
  }

  @override
  void dispose() {
    _donationTimer?.cancel();
    _onboardingPaymentController.dispose();
    super.dispose();
  }

  void _startDonationCountdown() {
    _donationTimer?.cancel();
    setState(() => _donationSeconds = 5);
    _donationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _step != 5) {
        timer.cancel();
        return;
      }
      if (_donationSeconds <= 1) {
        setState(() => _donationSeconds = 0);
        timer.cancel();
      } else {
        setState(() => _donationSeconds--);
      }
    });
  }

  Future<void> _loadOnboardingAiSettings() async {
    final settings = await LocalAppStore.instance.loadAiSettings();
    if (mounted) {
      setState(() {
        _onboardingAiSettings = settings;
        _isLoadingOnboardingAiSettings = false;
      });
    }
  }

  Future<void> _openOnboardingAiSettings() async {
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => const AiSettingsPage()));
    if (mounted) {
      await _loadOnboardingAiSettings();
    }
  }

  Future<void> _readNotificationStatus() async {
    final version = _permissionStateVersion;
    final granted = await NotificationService.instance
        .areNotificationsEnabled();
    if (mounted && version == _permissionStateVersion) {
      setState(() => _notificationGranted = granted);
    }
  }

  Future<void> _requestNotifications() async {
    if (_requestingPermission) {
      return;
    }
    final version = ++_permissionStateVersion;
    setState(() => _requestingPermission = true);
    try {
      final granted = await NotificationService.instance.requestPermission();
      if (mounted && version == _permissionStateVersion) {
        setState(() => _notificationGranted = granted);
      }
    } catch (_) {
      if (mounted && version == _permissionStateVersion) {
        setState(() => _notificationGranted = false);
      }
    } finally {
      if (mounted) {
        setState(() => _requestingPermission = false);
      }
    }
  }

  Future<void> _openNotificationSettings() async {
    try {
      await NotificationService.instance.openNotificationSettings();
    } catch (_) {
      // 不能跳转时仍保留再次请求权限的按钮。
    }
  }

  Future<void> _selectWearableManager(WearableManagerOption option) async {
    if (_openingWearableManager) {
      return;
    }
    setState(() {
      _selectedWearableManager = option;
      _wearableManagerMessage = null;
    });
    final document = await LocalAppStore.instance.loadDocument();
    await LocalAppStore.instance.saveSettings(
      maxCharacters: option.recommendedMaxCharacters,
      modeIndex: document.modeIndex,
      intervalMilliseconds: document.intervalMilliseconds,
      compactSegmentContent: document.compactSegmentContent,
      removeEmojiFromSegments: document.removeEmojiFromSegments,
      richSegmentContent: document.richSegmentContent,
    );
    await LocalAppStore.instance.saveWearablePreset(
      enabled: true,
      brandId: option.id,
      brandName: option.brandName,
      maxCharacters: option.recommendedMaxCharacters,
    );
    if (!mounted) {
      return;
    }
    if (!option.canLaunchManager) {
      setState(() {
        _wearableManagerMessage =
            '已应用通用保守预设：${option.recommendedMaxCharacters} 字/段。请手动打开你的手环管理软件，并开启“手环通知小说”的通知同步；之后可在统一设置中调整字数。';
      });
      return;
    }
    await _launchWearableManager(option);
  }

  Future<void> _launchWearableManager(WearableManagerOption option) async {
    setState(() => _openingWearableManager = true);
    try {
      final result = await NotificationService.instance.launchWearableManager(
        option.id,
      );
      if (!mounted) {
        return;
      }
      final status = result['status'];
      setState(() {
        _wearableManagerMessage = status == 'launched'
            ? '已应用 ${option.recommendedMaxCharacters} 字/段预设，并打开 ${option.appName}。请在其中找到“设备 / 通知 / 应用通知”，开启“手环通知小说”的通知同步；完成后返回本应用。'
            : '已应用 ${option.recommendedMaxCharacters} 字/段预设。未检测到已安装的 ${option.appName}，已尝试打开应用商店；安装后请在管理软件内开启“手环通知小说”的通知同步。';
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _wearableManagerMessage = error.message);
      }
    } finally {
      if (mounted) {
        setState(() => _openingWearableManager = false);
      }
    }
  }

  void _showWeChatPayment() {
    _onboardingPaymentController.animateToPage(
      1,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _next() async {
    if (_step == 0) {
      setState(() => _step = 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (mounted && _notificationGranted != true) {
        await _requestNotifications();
      }
      return;
    }
    if (_step == 1 && _notificationGranted != true) {
      await _requestNotifications();
      return;
    }
    if (_step == 2 && _selectedWearableManager == null) {
      return;
    }
    if (_step < 5) {
      final nextStep = _step + 1;
      setState(() => _step = nextStep);
      if (nextStep == 5) {
        _startDonationCountdown();
      }
      return;
    }
    await _finish();
  }

  Future<void> _finish() async {
    if (_notificationGranted != true) {
      setState(() => _step = 1);
      await _requestNotifications();
      return;
    }
    final selected = _selectedWearableManager;
    if (selected == null) {
      setState(() => _step = 2);
      return;
    }
    await LocalAppStore.instance.markOnboardingCompleted();
    if (mounted) {
      Navigator.of(
        context,
      ).pop(OnboardingResult(maxCharacters: selected.recommendedMaxCharacters));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = <({IconData icon, String title, String body})>[
      (
        icon: Icons.menu_book_outlined,
        title: '欢迎使用小说通知阅读器',
        body: '此页仅以示意方式说明小说导入流程。引导结束后不会显示或自动导入示例小说；请使用自己的本地图书、已授权接口或开源目录图书建立书库，再统一设置每段字数。',
      ),
      (
        icon: Icons.notifications_active_outlined,
        title: '请开启通知权限',
        body: '小说的完整分段会通过系统通知显示。Android 13 及以上需要在系统弹窗中允许通知后才能发送。',
      ),
      (
        icon: Icons.watch_outlined,
        title: '选择手环管理软件',
        body: '选择你的手环品牌后，应用会自动应用保守的单段字数预设，并打开相应的管理软件。请在其中开启“手环通知小说”的应用通知同步或镜像。',
      ),
      (
        icon: Icons.auto_awesome_outlined,
        title: '配置 AI 总结（可选）',
        body: 'AI 总结需要你提供自己的 API、API Key 和模型。请在下一步打开 AI 设置，读取模型列表并测试服务连通性；未配置时仍可正常阅读和发送小说。',
      ),
      (
        icon: Icons.save_outlined,
        title: '本地保存与断点续传',
        body: '小说、分段规则、发送模式和未完成的发送位置均保存在本机。发送中止或重启应用后，可从上一次进度继续。',
      ),
      (
        icon: Icons.volunteer_activism_outlined,
        title: '支持项目继续前行',
        body: '这是引导的最后一步。请在下一页查看支付宝或微信支付二维码；可左右滑动切换支付方式。',
      ),
    ];
    if (_step == 5) {
      final ready = _donationSeconds == 0;
      return PopScope(
        canPop: false,
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              child: Column(
                children: [
                  Expanded(
                    child: PageView(
                      controller: _onboardingPaymentController,
                      onPageChanged: (index) =>
                          setState(() => _onboardingPaymentIndex = index),
                      children: const [
                        ColoredBox(
                          color: Colors.white,
                          child: Image(
                            image: AssetImage(
                              'assets/images/donation_alipay.webp',
                            ),
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                        ColoredBox(
                          color: Colors.white,
                          child: Image(
                            image: AssetImage(
                              'assets/images/donation_wechat.jpeg',
                            ),
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${_onboardingPaymentIndex == 0 ? '支付宝' : '微信支付'} · 左右滑动图片切换支付方式',
                    style: Theme.of(context).textTheme.labelLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    ready ? '感谢支持，你现在可以继续。' : '请稍候 $_donationSeconds 秒后继续',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _onboardingPaymentIndex == 1
                        ? null
                        : _showWeChatPayment,
                    icon: const Icon(Icons.wechat_outlined),
                    label: const Text('什么没有支付宝，没关系 V 我 50'),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: ready ? _next : null,
                      icon: const Icon(Icons.check_outlined),
                      label: Text(ready ? '完成引导' : '完成（$_donationSeconds 秒）'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final page = pages[_step];
    final isLast = _step == pages.length - 1;

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(title: Text('使用引导 ${_step + 1}/${pages.length}')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Spacer(),
                Icon(
                  page.icon,
                  size: 88,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 28),
                Text(
                  page.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(page.body, textAlign: TextAlign.center),
                if (_step == 1) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: Theme.of(context).colorScheme.tertiaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.watch_outlined,
                            color: Theme.of(context)
                                .colorScheme
                                .onTertiaryContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '还需开启手环通知同步',
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onTertiaryContainer,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '请打开你的手环配套管理软件，在“设备 / 通知 / 应用通知（或应用提醒）”中找到“手环通知小说”，并开启通知同步或镜像。仅允许手机系统通知不足以让手环显示内容。',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onTertiaryContainer,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _requestingPermission
                        ? null
                        : _requestNotifications,
                    icon: _requestingPermission
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_user_outlined),
                    label: Text(
                      _notificationGranted == true ? '通知权限已开启' : '在系统弹窗中允许通知',
                    ),
                  ),
                  if (_notificationGranted == false) ...[
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('必须开启通知权限后才能继续。若系统弹窗未出现或此前已拒绝，请打开通知设置后允许通知。'),
                    ),
                    TextButton.icon(
                      onPressed: _openNotificationSettings,
                      icon: const Icon(Icons.settings_applications_outlined),
                      label: const Text('打开系统通知设置'),
                    ),
                  ],
                ],
                if (_step == 3) ...[
                  const SizedBox(height: 18),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isLoadingOnboardingAiSettings
                                ? '正在读取 AI 设置…'
                                : _onboardingAiSettings!.apiKey
                                          .trim()
                                          .isNotEmpty &&
                                      _onboardingAiSettings!.model
                                          .trim()
                                          .isNotEmpty
                                ? '已配置模型：${_onboardingAiSettings!.model}'
                                : '尚未配置 AI 服务',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '打开后可填写 API Base URL、API Key 和聊天路径，从 /models 中选择模型，并执行连通性测试。配置仅存储在本机。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _isLoadingOnboardingAiSettings
                                ? null
                                : _openOnboardingAiSettings,
                            icon: _isLoadingOnboardingAiSettings
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.settings_suggest_outlined),
                            label: const Text('配置 AI、选择模型并测试'),
                          ),
                          const SizedBox(height: 4),
                          TextButton.icon(
                            onPressed: _next,
                            icon: const Icon(Icons.skip_next_outlined),
                            label: const Text('跳过 AI 设置，稍后再配置'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_step == 2) ...[
                  const SizedBox(height: 18),
                  Text(
                    '选择品牌后会自动应用保守预设，并打开对应管理软件：',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: _wearableManagerOptions.map((option) {
                      return ChoiceChip(
                        showCheckmark: false,
                        avatar: option.logoAssetPath == null
                            ? Icon(option.icon, size: 18)
                            : Container(
                                width: 28,
                                height: 28,
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Image.asset(
                                  option.logoAssetPath!,
                                  fit: BoxFit.contain,
                                ),
                              ),
                        label: AnimatedScale(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutBack,
                          scale: _selectedWearableManager?.id == option.id
                              ? 1.04
                              : 1,
                          child: Text(
                            '${option.brandName}\n${option.recommendedMaxCharacters} 字预设',
                          ),
                        ),
                        selected: _selectedWearableManager?.id == option.id,
                        onSelected: _openingWearableManager
                            ? null
                            : (_) => unawaited(_selectWearableManager(option)),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  if (_openingWearableManager)
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (_wearableManagerMessage != null)
                    Text(
                      _wearableManagerMessage!,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else
                    Text(
                      '未安装时将尝试打开应用商店；“其他品牌”会应用 60 字通用预设，请手动打开其管理软件。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
                const Spacer(),
                Row(
                  children: [
                    if (_step > 0)
                      TextButton(
                        onPressed: () {
                          _donationTimer?.cancel();
                          setState(() => _step--);
                        },
                        child: const Text('上一步'),
                      ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed:
                          (_step == 1 && _notificationGranted != true) ||
                              (_step == 2 &&
                                  _selectedWearableManager == null) ||
                              (_step == 5 && _donationSeconds > 0)
                          ? null
                          : _next,
                      icon: Icon(
                        isLast ? Icons.check_outlined : Icons.arrow_forward,
                      ),
                      label: Text(
                        _step == 5 && _donationSeconds > 0
                            ? '下一步（$_donationSeconds 秒）'
                            : (isLast ? '完成' : '下一步'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DonationImagePage extends StatefulWidget {
  const DonationImagePage({super.key});

  @override
  State<DonationImagePage> createState() => _DonationImagePageState();
}

class _DonationImagePageState extends State<DonationImagePage> {
  final PageController _pageController = PageController();
  var _pageIndex = 0;

  static const _paymentPages = <({String title, String assetPath})>[
    (title: '支付宝', assetPath: 'assets/images/donation_alipay.webp'),
    (title: '微信支付', assetPath: 'assets/images/donation_wechat.jpeg'),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('捐献支持')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Text(
                '捐献我们，让我们走得更远',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '当前：${_paymentPages[_pageIndex].title}。左右滑动图片可切换支付宝和微信支付。',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _paymentPages.length,
                  onPageChanged: (index) => setState(() => _pageIndex = index),
                  itemBuilder: (context, index) {
                    final payment = _paymentPages[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InteractiveViewer(
                        minScale: 0.8,
                        maxScale: 3,
                        child: Center(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Image.asset(
                              payment.assetPath,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List<Widget>.generate(
                  _paymentPages.length,
                  (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: index == _pageIndex ? 20 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: index == _pageIndex
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text('滑动切换支付方式', style: theme.textTheme.labelMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class LaboratoryPage extends StatefulWidget {
  const LaboratoryPage({super.key});

  @override
  State<LaboratoryPage> createState() => _LaboratoryPageState();
}

class _LaboratoryPageState extends State<LaboratoryPage> {
  final TextEditingController _sampleController = TextEditingController(
    text: '第一段有空行。\n\n\n第二段包含表情 😀，并保留情节转折。',
  );
  StoredNovelDocument? _document;
  StoredUpdateDeferral? _deferral;
  AppUpdateSource _source = AppUpdateSource.github;
  bool _automaticCheckEnabled = true;
  int _launchCount = 0;
  List<String> _preview = const [];
  bool _isLoading = true;
  bool _isSendingNotificationPreview = false;
  String? _notificationPreviewMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _sampleController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final values = await Future.wait<Object?>([
      LocalAppStore.instance.loadDocument(),
      LocalAppStore.instance.loadUpdateDeferral(),
      LocalAppStore.instance.loadUpdateSourceIndex(),
      LocalAppStore.instance.isAutomaticUpdateCheckEnabled(),
      LocalAppStore.instance.loadAppLaunchCount(),
    ]);
    if (!mounted) {
      return;
    }
    final document = values[0] as StoredNovelDocument;
    final sourceIndex = values[2] as int;
    setState(() {
      _document = document;
      _deferral = values[1] as StoredUpdateDeferral?;
      _source = AppUpdateSource
          .values[sourceIndex.clamp(0, AppUpdateSource.values.length - 1)];
      _automaticCheckEnabled = values[3] as bool;
      _launchCount = values[4] as int;
      _isLoading = false;
      _preview = NovelTextSplitter.split(
        _sampleController.text,
        maxCharacters: document.maxCharacters,
        compactContent: document.compactSegmentContent,
        removeEmoji: document.removeEmojiFromSegments,
        richContent: document.richSegmentContent,
      );
    });
  }

  void _runSegmentExperiment() {
    final document = _document;
    if (document == null) {
      return;
    }
    setState(() {
      _preview = NovelTextSplitter.split(
        _sampleController.text,
        maxCharacters: document.maxCharacters,
        compactContent: document.compactSegmentContent,
        removeEmoji: document.removeEmojiFromSegments,
        richContent: document.richSegmentContent,
      );
    });
  }

  int get _estimatedSeconds {
    final document = _document;
    if (document == null || _preview.length < 2) {
      return 0;
    }
    return ((_preview.length - 1) * document.intervalMilliseconds / 1000)
        .round();
  }

  String get _estimatedDuration {
    final seconds = _estimatedSeconds;
    if (seconds < 60) {
      return '$seconds 秒';
    }
    return '${seconds ~/ 60} 分 ${seconds % 60} 秒';
  }

  Future<void> _sendNotificationPreview() async {
    if (_isSendingNotificationPreview) {
      return;
    }
    setState(() {
      _isSendingNotificationPreview = true;
      _notificationPreviewMessage = null;
    });
    try {
      final granted = await NotificationService.instance.requestPermission();
      if (!granted) {
        if (mounted) {
          setState(() => _notificationPreviewMessage = '未获得通知权限，请在系统设置中开启后重试。');
        }
        return;
      }
      final previewText = _preview.isEmpty
          ? _sampleController.text.trim()
          : _preview.first;
      if (previewText.isEmpty) {
        if (mounted) {
          setState(() => _notificationPreviewMessage = '请先输入实验文本并运行分段试验。');
        }
        return;
      }
      await NotificationService.instance.showChunk(
        id: 923457,
        index: 0,
        total: math.max(1, _preview.length),
        text: previewText,
      );
      if (mounted) {
        setState(() => _notificationPreviewMessage = '预览通知已发送，请检查手机通知栏和手环镜像。');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _notificationPreviewMessage = '预览通知发送失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _isSendingNotificationPreview = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final document = _document;
    return Scaffold(
      appBar: AppBar(
        title: const Text('实验室'),
        actions: [
          IconButton(
            tooltip: '刷新诊断数据',
            onPressed: _isLoading ? null : _load,
            icon: const Icon(Icons.refresh_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    color: theme.colorScheme.tertiaryContainer,
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '实验室中的结果仅用于验证功能，不会自动修改书库、分段内容或更新策略。实验功能可能在后续版本调整或移除。',
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('更新提醒策略诊断', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '自动检查：${_automaticCheckEnabled ? '已开启' : '已关闭'}',
                          ),
                          const SizedBox(height: 6),
                          Text('更新来源：${_source.title}'),
                          const SizedBox(height: 6),
                          Text('已记录应用启动次数：$_launchCount'),
                          const SizedBox(height: 6),
                          Text(
                            _deferral == null
                                ? '当前没有延后提醒记录。'
                                : '延后版本：${_deferral!.tag} · 已延后 ${_deferral!.deferCount} 次 · 下次自动提示不早于第 ${_deferral!.nextPromptLaunch} 次启动。',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('实验性分段试验场', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '使用当前正式设置：${document?.maxCharacters ?? 0} 字/段 · ${document?.compactSegmentContent == true ? '内容紧凑' : '保留空行'} · ${document?.removeEmojiFromSegments == true ? '删除 Emoji' : '保留 Emoji'} · ${document?.richSegmentContent == true ? '内容丰富' : '常规分段'}',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _sampleController,
                            minLines: 3,
                            maxLines: 6,
                            decoration: const InputDecoration(
                              labelText: '实验文本',
                              helperText: '仅用于预览，不会保存或发送。',
                              alignLabelWithHint: true,
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _runSegmentExperiment,
                            icon: const Icon(Icons.play_arrow_outlined),
                            label: const Text('运行分段试验'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    color: theme.colorScheme.secondaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '试验结果：${_preview.length} 段',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          if (_preview.isEmpty)
                            const Text('输入文本后运行试验，即可在这里查看分段结果。')
                          else
                            for (
                              var index = 0;
                              index < _preview.length && index < 3;
                              index++
                            )
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  '${index + 1}. ${_preview[index]}',
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          if (_preview.length > 3)
                            Text(
                              '其余 ${_preview.length - 3} 段已省略；本实验不会写入书库。',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '手环通知预览与阅读节奏',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _preview.isEmpty
                                ? '运行分段试验后可估算连续发送时长，并将首段作为真实通知发送。'
                                : '按当前 ${document?.intervalMilliseconds ?? 0} ms 发送间隔，$_preview.length 段预计需 $_estimatedDuration。该操作不会创建发送任务或改变断点。',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _isSendingNotificationPreview
                                ? null
                                : _sendNotificationPreview,
                            icon: _isSendingNotificationPreview
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.notifications_active_outlined,
                                  ),
                            label: Text(
                              _isSendingNotificationPreview
                                  ? '正在发送预览通知…'
                                  : '发送首段通知预览',
                            ),
                          ),
                          if (_notificationPreviewMessage != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              _notificationPreviewMessage!,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ThemePaletteTile extends StatelessWidget {
  const _ThemePaletteTile({
    required this.palette,
    required this.selected,
    required this.onSelected,
  });

  final AppColorPalette palette;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: palette.seedColor,
      brightness: Theme.of(context).brightness,
    );
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '${palette.title}调色板${selected ? '，已选择' : ''}',
      child: Tooltip(
        message: '${palette.title}调色板',
        child: Material(
          color: selected
              ? theme.colorScheme.secondaryContainer
              : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onSelected,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primaryContainer,
                      border: Border.all(
                        color: selected
                            ? theme.colorScheme.primary
                            : scheme.primary,
                        width: selected ? 3 : 1,
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            height: 19,
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: const BorderRadius.vertical(
                                bottom: Radius.circular(21),
                              ),
                            ),
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check,
                            color: theme.colorScheme.onSecondaryContainer,
                            size: 21,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    palette.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NovelEditorPage extends StatefulWidget {
  const NovelEditorPage({
    required this.initialText,
    required this.initialFileName,
    super.key,
  });

  final String initialText;
  final String? initialFileName;

  @override
  State<NovelEditorPage> createState() => _NovelEditorPageState();
}

class _NovelEditorPageState extends State<NovelEditorPage> {
  late final TextEditingController _textController;
  String? _fileName;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _importTxt() async {
    setState(() => _isImporting = true);
    try {
      final file = await FilePicker.pickFile(type: FileType.any);
      if (file == null) {
        return;
      }
      final decoded = await LocalBookImporter.decode(file);
      if (!mounted) {
        return;
      }
      setState(() {
        _textController.text = decoded.text;
        _fileName = file.name;
      });
      _showMessage('已导入 ${file.name}。');
    } on PlatformException catch (error) {
      _showMessage('无法打开文件选择器：${error.message ?? error.code}');
    } on FormatException catch (error) {
      _showMessage(error.message.toString());
    } catch (error) {
      _showMessage('导入失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  void _save() {
    Navigator.of(context)
        .pop(EditorResult(text: _textController.text, fileName: _fileName));
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('小说与分段'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            OutlinedButton.icon(
              onPressed: _isImporting ? null : _importTxt,
              icon: _isImporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_open_outlined),
              label: const Text('导入本地图书（TXT / EPUB 等）'),
            ),
            const SizedBox(height: 8),
            Text(
              _fileName == null ? '未选择文件，也可以直接在下方输入文本。' : '当前文件：$_fileName',
              style: Theme.of(context).textTheme.bodySmall,
            ),

            const SizedBox(height: 16),
            TextField(
              controller: _textController,
              minLines: 12,
              maxLines: 18,
              decoration: const InputDecoration(
                labelText: '小说正文',
                hintText: '导入 TXT 后会显示在这里；也可以直接粘贴或编辑。',
                prefixIcon: Padding(
                  padding: EdgeInsets.only(bottom: 248),
                  child: Icon(Icons.subject_outlined),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '原文 ${_textController.text.runes.length} 个字符。分段字数、发送方式和缓存清理均在“统一设置管理”页面配置；保存后可在完整分段预览页对指定区间批量调整。',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class UnifiedSettingsPage extends StatefulWidget {
  const UnifiedSettingsPage({
    required this.initialConfig,
    required this.initialMaxCharacters,
    required this.initialCompactSegmentContent,
    required this.initialRemoveEmojiFromSegments,
    required this.initialRichSegmentContent,
    super.key,
  });

  final SendingConfig initialConfig;
  final int initialMaxCharacters;
  final bool initialCompactSegmentContent;
  final bool initialRemoveEmojiFromSegments;
  final bool initialRichSegmentContent;

  @override
  State<UnifiedSettingsPage> createState() => _UnifiedSettingsPageState();
}

class _UnifiedSettingsPageState extends State<UnifiedSettingsPage> {
  late SendingMode _mode;
  late final TextEditingController _intervalController;
  late final TextEditingController _maxCharactersController;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _startupKey = GlobalKey();
  final GlobalKey _appearanceKey = GlobalKey();
  final GlobalKey _readingKey = GlobalKey();
  final GlobalKey _sourcesKey = GlobalKey();
  final GlobalKey _maintenanceKey = GlobalKey();
  final GlobalKey _aboutKey = GlobalKey();
  String? _cacheMessage;
  String? _autoSaveMessage;
  bool _isClearingCache = false;
  bool _presetLoaded = false;
  bool _useWearablePreset = false;
  String? _wearablePresetBrandId;
  String? _wearablePresetBrandName;
  int? _wearablePresetMaxCharacters;
  bool _startupScreenEnabled = true;
  late bool _compactSegmentContent;
  late bool _removeEmojiFromSegments;
  late bool _richSegmentContent;
  late StartupContentRecommendation _startupRecommendation;
  AppUpdateSource _updateSource = AppUpdateSource.github;
  bool _isLoadingUpdateSettings = true;
  bool _automaticUpdateCheckEnabled = true;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialConfig.mode;
    _intervalController = TextEditingController(
      text: widget.initialConfig.intervalMilliseconds.toString(),
    );
    _maxCharactersController = TextEditingController(
      text: widget.initialMaxCharacters.toString(),
    );
    _compactSegmentContent = widget.initialCompactSegmentContent;
    _removeEmojiFromSegments = widget.initialRemoveEmojiFromSegments;
    _richSegmentContent = widget.initialRichSegmentContent;
    _startupRecommendation = StartupContentRecommendation.random;
    _intervalController.addListener(_onSettingChanged);
    _maxCharactersController.addListener(_onSettingChanged);
    unawaited(_loadWearablePreset());
    unawaited(_loadStartupScreenSetting());
    unawaited(_loadStartupContentRecommendation());
    unawaited(_loadUpdateSource());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _intervalController.dispose();
    _maxCharactersController.dispose();
    super.dispose();
  }

  int get _intervalMilliseconds {
    final entered = int.tryParse(_intervalController.text.trim()) ?? 1000;
    const minimum = 100;
    return entered.clamp(minimum, 3600000).toInt();
  }

  int get _manualMaxCharacters {
    final entered = int.tryParse(_maxCharactersController.text.trim()) ?? 120;
    return entered.clamp(60, 250).toInt();
  }

  void _setMaxCharactersFromSlider(double value) {
    _maxCharactersController.text = value.round().toString();
  }

  int get _maxCharacters =>
      _useWearablePreset && _wearablePresetMaxCharacters != null
      ? _wearablePresetMaxCharacters!
      : _manualMaxCharacters;

  Future<void> _loadWearablePreset() async {
    final document = await LocalAppStore.instance.loadDocument();
    if (!mounted) {
      return;
    }
    setState(() {
      _useWearablePreset =
          document.wearablePresetEnabled &&
          document.wearablePresetMaxCharacters != null;
      _wearablePresetBrandId = document.wearablePresetBrandId;
      _wearablePresetBrandName = document.wearablePresetBrandName;
      _wearablePresetMaxCharacters = document.wearablePresetMaxCharacters;
      _presetLoaded = true;
      if (_useWearablePreset) {
        _maxCharactersController.text = _maxCharacters.toString();
      }
    });
  }

  Future<void> _loadStartupScreenSetting() async {
    final enabled = await LocalAppStore.instance.isStartupScreenEnabled();
    if (mounted) {
      setState(() => _startupScreenEnabled = enabled);
    }
  }

  Future<void> _loadStartupContentRecommendation() async {
    final index = await LocalAppStore.instance
        .loadStartupContentRecommendation();
    if (mounted) {
      setState(() {
        _startupRecommendation =
            StartupContentRecommendation.values[index.clamp(
              0,
              StartupContentRecommendation.values.length - 1,
            )];
      });
    }
  }

  Future<void> _loadUpdateSource() async {
    final values = await Future.wait<Object>([
      LocalAppStore.instance.loadUpdateSourceIndex(),
      LocalAppStore.instance.isAutomaticUpdateCheckEnabled(),
    ]);
    final index = values[0] as int;
    final automaticEnabled = values[1] as bool;
    if (mounted) {
      setState(() {
        _updateSource = AppUpdateSource
            .values[index.clamp(0, AppUpdateSource.values.length - 1)];
        _automaticUpdateCheckEnabled = automaticEnabled;
        _isLoadingUpdateSettings = false;
      });
    }
  }

  void _setAutomaticUpdateCheckEnabled(bool enabled) {
    setState(() => _automaticUpdateCheckEnabled = enabled);
    unawaited(LocalAppStore.instance.saveAutomaticUpdateCheckEnabled(enabled));
  }

  void _setUpdateSource(AppUpdateSource source) {
    setState(() => _updateSource = source);
    unawaited(LocalAppStore.instance.saveUpdateSourceIndex(source.index));
  }

  Future<void> _openLaboratory() async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.science_outlined),
        title: const Text('实验室高风险提示'),
        content: const Text(
          '实验室包含仍在验证的功能与诊断工具，界面、行为和可用性可能在后续版本改变。请不要将实验输出视为已保存的正式内容，并在继续前确认你接受上述风险。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.science_outlined),
            label: const Text('我已了解，进入实验室'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await Navigator.of(
        context,
      ).push<void>(MaterialPageRoute(builder: (_) => const LaboratoryPage()));
    }
  }

  void _setStartupScreenEnabled(bool enabled) {
    setState(() => _startupScreenEnabled = enabled);
    unawaited(LocalAppStore.instance.saveStartupScreenEnabled(enabled));
  }

  void _setStartupRecommendation(StartupContentRecommendation value) {
    setState(() => _startupRecommendation = value);
    unawaited(
      LocalAppStore.instance.saveStartupContentRecommendation(value.index),
    );
  }

  Future<void> _setRichSegmentContent(bool enabled) async {
    if (!enabled) {
      setState(() => _richSegmentContent = false);
      await _persistSettings();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const RichSegmentRiskDialog(),
    );
    if (confirmed == true && mounted) {
      setState(() => _richSegmentContent = true);
      await _persistSettings();
    }
  }

  void _setUseWearablePreset(bool enabled) {
    if (enabled && _wearablePresetMaxCharacters == null) {
      return;
    }
    setState(() {
      _useWearablePreset = enabled;
      if (enabled) {
        _maxCharactersController.text = _maxCharacters.toString();
      }
    });
    unawaited(_persistSettings());
  }

  Future<void> _openExternalLink(String value) async {
    final launched = await launchUrl(
      Uri.parse(value),
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      setState(() => _autoSaveMessage = '无法打开链接，请复制后在浏览器或应用中访问。');
    }
  }

  Future<void> _clearCache() async {
    setState(() => _isClearingCache = true);
    try {
      final bytes = await CacheCleaner.clearTemporaryCache();
      if (mounted) {
        setState(
          () => _cacheMessage =
              '已清理 ${CacheCleaner.formatBytes(bytes)} 临时缓存；书籍和进度未删除。',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _cacheMessage = '缓存清理失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _isClearingCache = false);
      }
    }
  }

  AppSettingsResult get _result => AppSettingsResult(
    config: SendingConfig(
      mode: _mode,
      intervalMilliseconds: _intervalMilliseconds,
    ),
    maxCharacters: _maxCharacters,
    compactSegmentContent: _compactSegmentContent,
    removeEmojiFromSegments: _removeEmojiFromSegments,
    richSegmentContent: _richSegmentContent,
  );

  Future<void> _persistSettings() async {
    await LocalAppStore.instance.saveSettings(
      maxCharacters: _maxCharacters,
      modeIndex: _mode.index,
      intervalMilliseconds: _intervalMilliseconds,
      compactSegmentContent: _compactSegmentContent,
      removeEmojiFromSegments: _removeEmojiFromSegments,
      richSegmentContent: _richSegmentContent,
    );
    if (_presetLoaded) {
      await LocalAppStore.instance.saveWearablePreset(
        enabled: _useWearablePreset,
        brandId: _wearablePresetBrandId,
        brandName: _wearablePresetBrandName,
        maxCharacters: _wearablePresetMaxCharacters,
      );
    }
    if (mounted) {
      setState(() => _autoSaveMessage = '设置已自动保存');
    }
  }

  void _onSettingChanged() {
    setState(() {});
    unawaited(_persistSettings());
  }

  void _scrollToSection(GlobalKey key) {
    final targetContext = key.currentContext;
    if (targetContext == null) {
      return;
    }
    Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: 0.06,
    );
  }

  Future<void> _close() async {
    await _persistSettings();
    if (mounted) {
      Navigator.of(context).pop(_result);
    }
  }

  @override
  Widget build(BuildContext context) {
    const minimum = 100;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_close());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('设置'),
          leading: IconButton(
            tooltip: '返回',
            onPressed: _close,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: SafeArea(
          child: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            children: [
              Text('设置导航', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.apps_outlined),
                      title: const Text('应用与后台'),
                      subtitle: const Text('启动页、通知与后台发送保护'),
                      trailing: const Icon(Icons.chevron_right_outlined),
                      onTap: () => _scrollToSection(_startupKey),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('主题与色彩'),
                      subtitle: const Text('深浅主题、莫奈和调色板'),
                      trailing: const Icon(Icons.chevron_right_outlined),
                      onTap: () => _scrollToSection(_appearanceKey),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.auto_stories_outlined),
                      title: const Text('阅读与发送'),
                      subtitle: const Text('分段规则、手环预设与发送频率'),
                      trailing: const Icon(Icons.chevron_right_outlined),
                      onTap: () => _scrollToSection(_readingKey),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.cloud_outlined),
                      title: const Text('导入与智能'),
                      subtitle: const Text('图书 API、AI 设置和模型'),
                      trailing: const Icon(Icons.chevron_right_outlined),
                      onTap: () => _scrollToSection(_sourcesKey),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.storage_outlined),
                      title: const Text('存储与实验室'),
                      subtitle: const Text('缓存清理与实验功能'),
                      trailing: const Icon(Icons.chevron_right_outlined),
                      onTap: () => _scrollToSection(_maintenanceKey),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('更新与关于'),
                      subtitle: const Text('更新策略、联系信息与项目支持'),
                      trailing: const Icon(Icons.chevron_right_outlined),
                      onTap: () => _scrollToSection(_aboutKey),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Container(
                key: _startupKey,
                child: Text(
                  '应用与后台',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: _startupScreenEnabled
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SwitchListTile.adaptive(
                  secondary: const Icon(Icons.auto_stories_outlined),
                  title: const Text('启用启动页'),
                  subtitle: Text(
                    _startupScreenEnabled
                        ? '每次启动请求一言并短暂显示一句文案；请求失败时使用本地兜底文案。'
                        : '已关闭；下次启动将直接进入书库，不请求一言。',
                  ),
                  value: _startupScreenEnabled,
                  onChanged: _setStartupScreenEnabled,
                ),
              ),
              const SizedBox(height: 12),
              AnimatedSize(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: _startupScreenEnabled
                    ? Card(
                        child: ListTile(
                          leading: Icon(_startupRecommendation.icon),
                          title: const Text('启动页内容推荐'),
                          subtitle: Text(
                            '${_startupRecommendation.title} · ${_startupRecommendation.description}',
                          ),
                          trailing: const Icon(Icons.chevron_right_outlined),
                          onTap: () async {
                            final selected =
                                await showModalBottomSheet<
                                  StartupContentRecommendation
                                >(
                                  context: context,
                                  showDragHandle: true,
                                  builder: (sheetContext) => SafeArea(
                                    child: ListView(
                                      shrinkWrap: true,
                                      children: [
                                        const ListTile(
                                          title: Text('选择启动页内容'),
                                          subtitle: Text(
                                            '随机推荐或选择一言 API 的单一内容分类。',
                                          ),
                                        ),
                                        for (final item
                                            in StartupContentRecommendation
                                                .values)
                                          ListTile(
                                            leading: Icon(item.icon),
                                            title: Text(item.title),
                                            subtitle: Text(item.description),
                                            trailing:
                                                item == _startupRecommendation
                                                ? const Icon(
                                                    Icons.check_circle_outlined,
                                                  )
                                                : null,
                                            onTap: () =>
                                                Navigator.of(sheetContext)
                                                    .pop(item),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                            if (selected != null) {
                              _setStartupRecommendation(selected);
                            }
                          },
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.battery_saver_outlined),
                  title: const Text('后台发送保护'),
                  subtitle: const Text(
                    '后台模式使用前台服务、唤醒锁和恢复会话。华为设备请在“应用启动管理”关闭自动管理并允许后台活动，再在多任务界面锁定本应用；可点此打开电池优化设置。',
                  ),
                  trailing: const Icon(Icons.open_in_new_outlined),
                  onTap: () async {
                    try {
                      await NotificationService.instance
                          .openBatteryOptimizationSettings();
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(error.toString())),
                        );
                      }
                    }
                  },
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.settings_suggest_outlined),
                  title: const Text('华为应用启动管理'),
                  subtitle: const Text('华为设备请关闭自动管理，并启用“允许后台活动”；再在多任务界面锁定本应用。'),
                  trailing: const Icon(Icons.open_in_new_outlined),
                  onTap: () async {
                    try {
                      await NotificationService.instance
                          .openHuaweiAppLaunchSettings();
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(error.toString())),
                        );
                      }
                    }
                  },
                ),
              ),
              const SizedBox(height: 24),
              Container(
                key: _appearanceKey,
                child: Text(
                  '主题与色彩',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '选择应用主题，设置会自动保存并在下次启动时恢复。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      SegmentedButton<AppThemePreference>(
                        segments: AppThemePreference.values
                            .map(
                              (preference) => ButtonSegment(
                                value: preference,
                                icon: Icon(preference.icon),
                                label: Text(preference.title),
                              ),
                            )
                            .toList(growable: false),
                        selected: {AppThemeController.instance.preference},
                        onSelectionChanged: (selected) {
                          unawaited(
                            AppThemeController.instance.setPreference(
                              selected.first,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: SwitchListTile.adaptive(
                  secondary: const Icon(Icons.palette_outlined),
                  title: const Text('使用系统动态配色（莫奈）'),
                  subtitle: Text(
                    AppThemeController.instance.dynamicColorEnabled
                        ? '已启用：Android 12 及以上使用壁纸与系统配色；不支持时自动使用应用默认配色。'
                        : '关闭：始终使用应用默认的 Material 3 配色。',
                  ),
                  value: AppThemeController.instance.dynamicColorEnabled,
                  onChanged: (enabled) => unawaited(
                    AppThemeController.instance.setDynamicColorEnabled(enabled),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '调色板',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppThemeController.instance.dynamicColorEnabled
                            ? '当前启用系统动态取色；关闭莫奈后将使用下方选择的调色板。'
                            : '选择配色后会立即应用并自动保存。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 14),
                      GridView.count(
                        crossAxisCount: 4,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.9,
                        children: AppColorPalette.values
                            .map(
                              (palette) => _ThemePaletteTile(
                                palette: palette,
                                selected:
                                    AppThemeController.instance.palette ==
                                    palette,
                                onSelected: () => unawaited(
                                  AppThemeController.instance.setPalette(
                                    palette,
                                  ),
                                ),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                key: _readingKey,
                child: Text(
                  '阅读与发送',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (_autoSaveMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  _autoSaveMessage!,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeInCubic,
                child: Card(
                  key: ValueKey(_presetLoaded && _useWearablePreset),
                  color: _useWearablePreset
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : null,
                  child: SwitchListTile.adaptive(
                    secondary: const Icon(Icons.auto_awesome_outlined),
                    title: const Text('启用预设'),
                    subtitle: Text(
                      _wearablePresetMaxCharacters == null
                          ? '尚未选择手环品牌。请重新打开引导并选择品牌后使用预设。'
                          : '根据你选择的$_wearablePresetBrandName预设单条通知的最大容量：$_wearablePresetMaxCharacters 字/段。开启后隐藏手动字数调节。',
                    ),
                    value: _presetLoaded && _useWearablePreset,
                    onChanged:
                        !_presetLoaded || _wearablePresetMaxCharacters == null
                        ? null
                        : _setUseWearablePreset,
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                child: _useWearablePreset
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Card(
                          color: Theme.of(context)
                              .colorScheme
                              .secondaryContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                const Icon(Icons.tune_outlined),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '当前按预设分段：$_maxCharacters 字/段。关闭“启用预设”后可手动调整。',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.format_size_outlined),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        '统一每段最大字符数：$_maxCharacters',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall,
                                      ),
                                    ),
                                  ],
                                ),
                                Slider(
                                  value: _manualMaxCharacters.toDouble(),
                                  min: 60,
                                  max: 250,
                                  divisions: 190,
                                  label: '$_manualMaxCharacters 字',
                                  onChanged: _setMaxCharactersFromSlider,
                                ),
                                Text(
                                  '滑动范围 60–250 字；也可在下方手动输入。修改后会统一重新切分，并覆盖局部批量调整。',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _maxCharactersController,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: '手动输入每段最大字符数',
                                    helperText: '支持 60–250 字。',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              Card(
                child: SwitchListTile.adaptive(
                  secondary: const Icon(Icons.format_line_spacing_outlined),
                  title: const Text('内容紧凑'),
                  subtitle: const Text('开启后会在分段前合并连续空行，删除每段中的多余空白行。'),
                  value: _compactSegmentContent,
                  onChanged: (enabled) {
                    setState(() => _compactSegmentContent = enabled);
                    unawaited(_persistSettings());
                  },
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: SwitchListTile.adaptive(
                  secondary: const Icon(Icons.sentiment_dissatisfied_outlined),
                  title: const Text('自动删除 Emoji'),
                  subtitle: const Text('开启后会检测并删除分段文字中的表情符号，减少手环通知显示异常。'),
                  value: _removeEmojiFromSegments,
                  onChanged: (enabled) {
                    setState(() => _removeEmojiFromSegments = enabled);
                    unawaited(_persistSettings());
                  },
                ),
              ),
              const SizedBox(height: 8),
              Card(
                color: _richSegmentContent
                    ? Theme.of(context).colorScheme.tertiaryContainer
                    : null,
                child: SwitchListTile.adaptive(
                  secondary: const Icon(Icons.warning_amber_outlined),
                  title: const Text('内容丰富模式'),
                  subtitle: const Text(
                    '启用后为尽量填满每段字数会删除全部 Emoji 和部分弱标点，可能影响阅读节奏。',
                  ),
                  value: _richSegmentContent,
                  onChanged: (enabled) =>
                      unawaited(_setRichSegmentContent(enabled)),
                ),
              ),
              const SizedBox(height: 24),
              Text('发送规则', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<SendingMode>(
                segments: const [
                  ButtonSegment(
                    value: SendingMode.foreground,
                    icon: Icon(Icons.phone_android_outlined),
                    label: Text('前台'),
                  ),
                  ButtonSegment(
                    value: SendingMode.background,
                    icon: Icon(Icons.cloud_sync_outlined),
                    label: Text('后台'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (selected) {
                  setState(() => _mode = selected.first);
                  unawaited(_persistSettings());
                },
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_mode.description),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _intervalController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: '自动发送间隔（毫秒）',
                  helperText: '支持 $minimum–3600000 ms；例如 500 ms 即每 0.5 秒发送一段。',
                  prefixIcon: const Icon(Icons.timer_outlined),
                ),
              ),
              if (_mode == SendingMode.background) ...[
                const SizedBox(height: 12),
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('后台模式会显示一条系统服务通知，并受安卓对长时间后台运行的限制。发送页可暂停和继续。'),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Container(
                key: _sourcesKey,
                child: Text(
                  '导入与智能',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              Text('网络导入设置', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.api_outlined),
                  title: const Text('API 导入详情'),
                  subtitle: const Text(
                    '设置图书 API 地址、书名回退和 Authorization。实际 API 或开源书源导入请从“导入图书 → 网络导入图书”进入。',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => const NetworkApiSettingsPage(),
                      ),
                    );
                    if (mounted) {
                      setState(() {});
                    }
                  },
                ),
              ),
              const SizedBox(height: 24),
              Text('AI 总结', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: const Text('AI 设置与模型'),
                  subtitle: const Text(
                    '配置 OpenAI 或兼容 API，测试连通性，读取可选模型，并设置深度思考和附加提示词。',
                  ),
                  trailing: const Icon(Icons.chevron_right_outlined),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => const AiSettingsPage()),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                key: _maintenanceKey,
                child: Text(
                  '存储与实验室',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              Text('实验室', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.science_outlined),
                  title: const Text('实验室功能'),
                  subtitle: const Text('查看实验性分段试验场与更新提醒策略诊断。功能可能在后续版本变化。'),
                  trailing: const Icon(Icons.chevron_right_outlined),
                  onTap: _openLaboratory,
                ),
              ),
              const SizedBox(height: 24),
              Text('存储与缓存', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('清理临时缓存'),
                  subtitle: Text(_cacheMessage ?? '仅清理临时文件，不会删除已导入书籍、设置或发送进度。'),
                  trailing: _isClearingCache
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _isClearingCache ? null : _clearCache,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                key: _aboutKey,
                child: Text(
                  '更新与关于',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              Text('关于', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.menu_book_outlined),
                          const SizedBox(width: 10),
                          Text(
                            '手环通知小说',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Text('应用版本'),
                      const SizedBox(height: 2),
                      Text(
                        AppRelease.displayVersion,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '开发者',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutBack,
                        child: Material(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => unawaited(
                              _openExternalLink(
                                'https://space.bilibili.com/3493268220283756',
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  const CircleAvatar(
                                    radius: 28,
                                    backgroundImage: AssetImage(
                                      'assets/images/ritualcollapse_bilibili_avatar.webp',
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text('ritualcollapse'),
                                        const SizedBox(height: 2),
                                        Text(
                                          '哔哩哔哩 UP 主 · 点击访问主页',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.open_in_new_outlined),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.alternate_email_outlined),
                        title: const Text('联系方式'),
                        subtitle: const Text('huanglinran114514@outlook.com'),
                        trailing: const Icon(Icons.open_in_new_outlined),
                        onTap: () => unawaited(
                          _openExternalLink(
                            'mailto:huanglinran114514@outlook.com',
                          ),
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.groups_outlined),
                        title: const Text('QQ 群'),
                        subtitle: const Text('1033414307 · 点击使用 QQ 进入群聊'),
                        trailing: const Icon(Icons.open_in_new_outlined),
                        onTap: () => unawaited(
                          _openExternalLink(
                            'mqqapi://card/show_pslcard?src_type=internal&version=1&uin=1033414307&card_type=group&source=qrcode',
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text('开源仓库'),
                      const SizedBox(height: 4),
                      SelectableText(
                        'https://github.com/Ranlin114514/band-novel-reader',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '仓库包含完整源代码、GPL-3.0 许可、历史版本安装包和中英文更新日志。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => const DonationImagePage(),
                            ),
                          ),
                          icon: const Icon(Icons.volunteer_activism_outlined),
                          label: const Text('捐献支持'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: SwitchListTile.adaptive(
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: const Text('自动检查更新'),
                  subtitle: Text(
                    _isLoadingUpdateSettings
                        ? '正在读取更新策略…'
                        : _automaticUpdateCheckEnabled
                        ? '启动后检查更高版本；测试版会先显示风险提示。'
                        : '已关闭；启动时不会检查或弹出更新提示，仍可手动检查。',
                  ),
                  value: _automaticUpdateCheckEnabled,
                  onChanged: _isLoadingUpdateSettings
                      ? null
                      : _setAutomaticUpdateCheckEnabled,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.system_update_alt_outlined),
                  title: const Text('更新来源'),
                  subtitle: Text(
                    _isLoadingUpdateSettings
                        ? '正在读取更新设置…'
                        : '${_updateSource.title} · ${_updateSource.subtitle}',
                  ),
                  trailing: _isLoadingUpdateSettings
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right_outlined),
                  onTap: _isLoadingUpdateSettings
                      ? null
                      : () async {
                          final selected =
                              await showModalBottomSheet<AppUpdateSource>(
                                context: context,
                                showDragHandle: true,
                                builder: (sheetContext) => SafeArea(
                                  child: ListView(
                                    shrinkWrap: true,
                                    children: [
                                      const ListTile(
                                        title: Text('选择更新来源'),
                                        subtitle: Text(
                                          '更新检查和 APK 下载会统一使用所选来源。镜像服务由第三方提供，请在网络受限时按需使用。',
                                        ),
                                      ),
                                      for (final source
                                          in AppUpdateSource.values)
                                        ListTile(
                                          leading: Icon(
                                            source == AppUpdateSource.github
                                                ? Icons.verified_outlined
                                                : Icons.swap_horiz_outlined,
                                          ),
                                          title: Text(source.title),
                                          subtitle: Text(source.subtitle),
                                          trailing: source == _updateSource
                                              ? const Icon(
                                                  Icons.check_circle_outlined,
                                                )
                                              : null,
                                          onTap: () =>
                                              Navigator.of(sheetContext)
                                                  .pop(source),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                          if (selected != null) {
                            _setUpdateSource(selected);
                          }
                        },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RichSegmentRiskDialog extends StatefulWidget {
  const RichSegmentRiskDialog({super.key});

  @override
  State<RichSegmentRiskDialog> createState() => _RichSegmentRiskDialogState();
}

class _RichSegmentRiskDialogState extends State<RichSegmentRiskDialog> {
  Timer? _timer;
  int _seconds = 3;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_seconds <= 1) {
        timer.cancel();
        setState(() => _seconds = 0);
      } else {
        setState(() => _seconds--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: const Text('高风险：内容丰富模式'),
      content: const Text(
        '此模式会为尽量填满单条通知的最大字数，自动删除全部 Emoji，并移除逗号、顿号、冒号、分号等弱标点。它不会替换正文或删除句号、问号和感叹号，但阅读节奏、语气与部分格式仍可能变差。\n\n请仅在确认手环容量非常有限且愿意承担阅读困难风险时开启。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _seconds == 0
              ? () => Navigator.of(context).pop(true)
              : null,
          icon: _seconds == 0
              ? const Icon(Icons.warning_amber_rounded)
              : const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
          label: Text(_seconds == 0 ? '我已了解，仍要开启' : '请阅读（$_seconds 秒）'),
        ),
      ],
    );
  }
}

class SegmentPreviewPage extends StatefulWidget {
  const SegmentPreviewPage({
    required this.chunks,
    required this.maxCharacters,
    this.completedCount = 0,
    super.key,
  });
  final List<String> chunks;
  final int maxCharacters;
  final int completedCount;

  @override
  State<SegmentPreviewPage> createState() => _SegmentPreviewPageState();
}

class _SegmentPreviewPageState extends State<SegmentPreviewPage> {
  late List<String> _chunks;
  bool _wasAdjusted = false;

  @override
  void initState() {
    super.initState();
    _chunks = List<String>.of(widget.chunks);
  }

  Future<void> _openAiSummary() async {
    final summarized = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => AiSegmentSummaryPage(
          chunks: _chunks,
          maxCharacters: widget.maxCharacters,
        ),
      ),
    );
    if (summarized == null || !mounted) {
      return;
    }
    setState(() {
      _chunks = summarized;
      _wasAdjusted = true;
    });
  }

  Future<void> _openBatchAdjuster() async {
    final adjusted = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => BatchSegmentAdjustPage(
          chunks: _chunks,
          initialMaxCharacters: widget.maxCharacters,
          completedCount: widget.completedCount,
        ),
      ),
    );
    if (adjusted == null || !mounted) {
      return;
    }
    setState(() {
      _chunks = adjusted;
      _wasAdjusted = true;
    });
  }

  void _finish() {
    Navigator.of(context).pop(_wasAdjusted ? _chunks : null);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<List<String>>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _finish();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '返回',
            onPressed: _finish,
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('完整分段预览'),
          actions: [
            IconButton(
              tooltip: 'AI 总结分段',
              onPressed: _openAiSummary,
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
            IconButton(
              tooltip: '批量调整指定段落',
              onPressed: _openBatchAdjuster,
              icon: const Icon(Icons.tune_outlined),
            ),
            TextButton(onPressed: _finish, child: const Text('完成')),
          ],
        ),
        body: SafeArea(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _chunks.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '共 ${_chunks.length} 段；下方内容与通知 body 一致，未做省略或摘要。',
                          ),
                          const SizedBox(height: 8),
                          const Text('点击右上角调节图标，可对任意起止段落统一重新按指定字数切分。'),
                        ],
                      ),
                    ),
                  ),
                );
              }
              final chunk = _chunks[index - 1];
              final completed = index <= widget.completedCount;
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '通知片段 $index/${_chunks.length} · ${chunk.runes.length} 字',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const Divider(height: 24),
                          SelectableText(chunk),
                        ],
                      ),
                    ),
                    if (completed)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Semantics(
                          label: '该通知片段已完成发送',
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: ShapeDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer,
                              shape: const StadiumBorder(),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.done_rounded,
                                  size: 14,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSecondaryContainer,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '已发送',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSecondaryContainer,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class BatchSegmentAdjustPage extends StatefulWidget {
  const BatchSegmentAdjustPage({
    required this.chunks,
    required this.initialMaxCharacters,
    required this.completedCount,
    super.key,
  });
  final List<String> chunks;
  final int initialMaxCharacters;
  final int completedCount;

  @override
  State<BatchSegmentAdjustPage> createState() => _BatchSegmentAdjustPageState();
}

class _BatchSegmentAdjustPageState extends State<BatchSegmentAdjustPage> {
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  late final TextEditingController _limitController;

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController(text: '1');
    _endController = TextEditingController(
      text: widget.chunks.length.toString(),
    );
    _limitController = TextEditingController(
      text: widget.initialMaxCharacters.toString(),
    );
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    _limitController.dispose();
    super.dispose();
  }

  int get _start => (int.tryParse(_startController.text) ?? 1)
      .clamp(1, widget.chunks.length)
      .toInt();
  int get _end => (int.tryParse(_endController.text) ?? widget.chunks.length)
      .clamp(_start, widget.chunks.length)
      .toInt();
  int get _limit =>
      (int.tryParse(_limitController.text) ?? widget.initialMaxCharacters)
          .clamp(20, 1000)
          .toInt();

  void _apply() {
    final adjusted = SegmentBatchAdjuster.adjust(
      widget.chunks,
      startSegment: _start,
      endSegment: _end,
      maxCharacters: _limit,
    );
    Navigator.of(context).pop(adjusted);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('批量调整段落字数')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '选择要重新切分的段落区间。只会重排该区间文字，区间外的原有分段保持不变。将起止段落设为 1–${widget.chunks.length} 可一次统一调整全部段落。',
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _startController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '起始段落（从 1 开始）',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _endController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: '结束段落'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _limitController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '该区间每段最大字符数',
                helperText: '支持 20–1000；可用于单段（起止相同）或多段批量设置。',
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '将重排第 $_start 至第 $_end 段，采用 $_limit 字/段。已完成 ${widget.completedCount.clamp(0, widget.chunks.length)} 段会以勾选状态保留在完整分段预览中。',
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _apply,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              icon: const Icon(Icons.auto_fix_high_outlined),
              label: const Text('应用批量调整'),
            ),
          ],
        ),
      ),
    );
  }
}

class SegmentBatchAdjuster {
  const SegmentBatchAdjuster._();

  static List<String> adjust(
    List<String> chunks, {
    required int startSegment,
    required int endSegment,
    required int maxCharacters,
  }) {
    if (chunks.isEmpty) {
      return const [];
    }
    final start = startSegment.clamp(1, chunks.length).toInt() - 1;
    final end = endSegment.clamp(start + 1, chunks.length).toInt() - 1;
    final selectedText = chunks.sublist(start, end + 1).join();
    final adjusted = NovelTextSplitter.split(
      selectedText,
      maxCharacters: maxCharacters.clamp(20, 1000).toInt(),
    );
    return [...chunks.take(start), ...adjusted, ...chunks.skip(end + 1)];
  }
}

class SendingTaskPage extends StatefulWidget {
  const SendingTaskPage({
    this.bookId,
    required this.chunks,
    required this.config,
    required this.initialIndex,
    required this.notificationBaseId,
    this.startImmediately = false,
    super.key,
  });

  final String? bookId;
  final List<String> chunks;
  final SendingConfig config;
  final int initialIndex;
  final int notificationBaseId;
  final bool startImmediately;

  @override
  State<SendingTaskPage> createState() => _SendingTaskPageState();
}

class _SendingTaskPageState extends State<SendingTaskPage> {
  bool _isRunning = false;
  bool _isFinished = false;
  bool _cancelForeground = false;
  late int _sent;
  String _status = '准备开始…';

  @override
  void initState() {
    super.initState();
    _sent = widget.initialIndex.clamp(0, widget.chunks.length).toInt();
    FlutterForegroundTask.addTaskDataCallback(_onBackgroundData);
    _status = _sent >= widget.chunks.length
        ? '全部段落已发送完成。'
        : '准备从第 ${_sent + 1}/${widget.chunks.length} 段发送。';
    _isFinished = _sent >= widget.chunks.length;
    if (widget.startImmediately && !_isFinished) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onBackgroundData);
    super.dispose();
  }

  void _onBackgroundData(Object data) {
    if (data is! Map) {
      return;
    }
    final type = data['type'];
    final eventBookId = data['bookId'];
    if (eventBookId is String &&
        widget.bookId != null &&
        eventBookId != widget.bookId) {
      return;
    }
    if (type == 'progress') {
      final sent = data['sent'];
      if (sent is int && mounted) {
        setState(() {
          _sent = sent;
          _status = '后台模式正在发送 $_sent/${widget.chunks.length} 段…';
        });
        unawaited(
          LocalAppStore.instance.updateSendingProgress(
            sent,
            expectedBookId: widget.bookId,
          ),
        );
      }
    } else if (type == 'complete' && mounted) {
      setState(() {
        _sent = widget.chunks.length;
        _isRunning = false;
        _isFinished = true;
        _status = '全部 ${widget.chunks.length} 段已发送完成。';
      });
      unawaited(
        LocalAppStore.instance.clearActiveSendingSession(
          expectedBookId: widget.bookId,
        ),
      );
    } else if (type == 'stopped' && mounted && !_isFinished) {
      setState(() {
        _isRunning = false;
        _status = '后台发送任务已停止。';
      });
    }
  }

  Future<void> _start() async {
    try {
      final granted = await NotificationService.instance.requestPermission();
      if (!granted) {
        if (!mounted) {
          return;
        }
        setState(() => _status = '未取得通知权限，无法开始。');
        return;
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _cancelForeground = false;
        _isRunning = true;
        _status = widget.config.mode == SendingMode.foreground
            ? '前台模式正在发送 $_sent/${widget.chunks.length} 段…'
            : '正在启动后台发送服务…';
      });

      if (widget.config.mode == SendingMode.foreground) {
        await _runForeground();
      } else {
        await _runBackground();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isRunning = false;
          _status = '通知发送失败：$error。请检查系统通知权限后重试。';
        });
      }
    }
  }

  Future<void> _runForeground() async {
    for (var index = _sent; index < widget.chunks.length; index++) {
      if (_cancelForeground) {
        break;
      }
      await NotificationService.instance.showChunk(
        id: widget.notificationBaseId + index,
        index: index,
        total: widget.chunks.length,
        text: widget.chunks[index],
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _sent = index + 1;
        _status = '前台模式正在发送 $_sent/${widget.chunks.length} 段…';
      });
      await LocalAppStore.instance.updateSendingProgress(
        _sent,
        expectedBookId: widget.bookId,
      );
      if (index < widget.chunks.length - 1 && !_cancelForeground) {
        await Future<void>.delayed(
          Duration(milliseconds: widget.config.intervalMilliseconds),
        );
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _isRunning = false;
      _isFinished = !_cancelForeground;
      _status = _cancelForeground
          ? '前台发送任务已在 $_sent/${widget.chunks.length} 段后停止。'
          : '全部 ${widget.chunks.length} 段已发送完成。';
    });
    if (!_cancelForeground) {
      await LocalAppStore.instance.clearActiveSendingSession(
        expectedBookId: widget.bookId,
      );
    }
  }

  Future<void> _runBackground() async {
    try {
      await BackgroundNovelSender.start(
        bookId: widget.bookId,
        chunks: widget.chunks,
        intervalMilliseconds: widget.config.intervalMilliseconds,
        startIndex: _sent,
        notificationBaseId: widget.notificationBaseId,
      );
      if (mounted) {
        setState(() => _status = '后台服务已启动，正在等待第一段通知。');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isRunning = false;
          _status = '后台服务启动失败：$error';
        });
      }
    }
  }

  Future<void> _pause() async {
    if (widget.config.mode == SendingMode.foreground) {
      setState(() {
        _cancelForeground = true;
        _status = '已请求暂停；当前等待结束后将保留进度。';
      });
      return;
    }

    await BackgroundNovelSender.stop();
    if (mounted) {
      setState(() {
        _isRunning = false;
        _status = '后台发送已暂停，进度已保存。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress =
        (widget.chunks.isEmpty ? 0.0 : _sent / widget.chunks.length)
            .clamp(0.0, 1.0)
            .toDouble();
    return PopScope(
      canPop: !_isRunning,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('发送任务'),
          automaticallyImplyLeading: !_isRunning,
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.config.mode.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '每 ${widget.config.intervalMilliseconds} ms 发送一段；总计 ${widget.chunks.length} 段。',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.timeline_outlined),
                            const SizedBox(width: 8),
                            Text(
                              '发送进度',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const Spacer(),
                            Text(
                              '${(progress * 100).toStringAsFixed(2)}%',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Semantics(
                          label:
                              '发送进度 ${(progress * 100).toStringAsFixed(2)}%，已发送 $_sent，共 ${widget.chunks.length} 段',
                          child: LinearProgressIndicator(value: progress),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('已发送 $_sent 段'),
                            Text('剩余 ${widget.chunks.length - _sent} 段'),
                          ],
                        ),
                        const Divider(height: 24),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              _isFinished
                                  ? Icons.check_circle_outline
                                  : _isRunning
                                  ? Icons.sync_outlined
                                  : Icons.pause_circle_outline,
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_status)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isRunning || _isFinished || _sent > 0
                            ? null
                            : _start,
                        icon: const Icon(Icons.send_outlined),
                        label: const Text('发送'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _isFinished
                            ? null
                            : (_isRunning ? _pause : _start),
                        style: FilledButton.styleFrom(
                          backgroundColor: _isRunning
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.secondary,
                          foregroundColor: _isRunning
                              ? Theme.of(context).colorScheme.onError
                              : Theme.of(context).colorScheme.onSecondary,
                        ),
                        icon: Icon(
                          _isRunning
                              ? Icons.pause_circle_outline
                              : Icons.play_circle_outline,
                        ),
                        label: Text(_isRunning ? '暂停' : '继续'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class NotificationService {
  NotificationService._();

  static final instance = NotificationService._();
  static const MethodChannel _systemNotificationChannel = MethodChannel(
    'com.ritualcollapse.wristnovel/notifications',
  );

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  Future<void>? _initializing;
  bool _initialized = false;

  static const _channel = AndroidNotificationChannel(
    _notificationChannelId,
    _notificationChannelName,
    description: _notificationChannelDescription,
    importance: Importance.defaultImportance,
  );

  Future<void> initialize() {
    if (_initialized) {
      return Future.value();
    }
    return _initializing ??= initializePlugin(_plugin).then((_) {
      _initialized = true;
    });
  }

  static Future<void> initializePlugin(
    FlutterLocalNotificationsPlugin plugin,
  ) async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('app_icon'),
    );
    await plugin.initialize(settings: settings);
    final androidPlugin = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(_channel);
  }

  Future<bool> requestPermission() async {
    await initialize();
    try {
      final granted = await _systemNotificationChannel.invokeMethod<bool>(
        'requestPermission',
      );
      if (granted != null) {
        return granted;
      }
    } on PlatformException {
      // 原生桥接不可用时，继续使用通知插件的兼容实现。
    } on MissingPluginException {
      // 单元测试或非 Android 平台中没有原生桥接，使用兼容实现。
    }

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin == null) {
      return false;
    }
    final wasEnabled = await androidPlugin.areNotificationsEnabled();
    if (wasEnabled ?? false) {
      return true;
    }
    final granted = await androidPlugin.requestNotificationsPermission();
    return granted ?? await androidPlugin.areNotificationsEnabled() ?? false;
  }

  Future<bool> areNotificationsEnabled() async {
    try {
      final enabled = await _systemNotificationChannel.invokeMethod<bool>(
        'areNotificationsEnabled',
      );
      if (enabled != null) {
        return enabled;
      }
    } on PlatformException {
      // 使用下方插件实现作为兼容回退。
    } on MissingPluginException {
      // 使用下方插件实现作为兼容回退。
    }
    await initialize();
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await androidPlugin?.areNotificationsEnabled() ?? false;
  }

  Future<void> openNotificationSettings() async {
    try {
      await _systemNotificationChannel.invokeMethod<bool>(
        'openNotificationSettings',
      );
    } on PlatformException {
      throw const FormatException('无法打开系统通知设置，请在系统设置中手动开启本应用通知。');
    } on MissingPluginException {
      throw const FormatException('当前设备不支持直接打开系统通知设置。');
    }
  }

  Future<void> openBatteryOptimizationSettings() async {
    try {
      await _systemNotificationChannel.invokeMethod<bool>(
        'openBatteryOptimizationSettings',
      );
    } on PlatformException {
      throw const FormatException('无法打开电池优化设置，请在系统设置中手动允许本应用后台运行。');
    } on MissingPluginException {
      throw const FormatException('当前设备不支持直接打开电池优化设置。');
    }
  }

  Future<void> openHuaweiAppLaunchSettings() async {
    try {
      await _systemNotificationChannel.invokeMethod<bool>(
        'openHuaweiAppLaunchSettings',
      );
    } on PlatformException {
      throw const FormatException('无法打开华为应用启动管理，请在系统设置中搜索“应用启动管理”。');
    } on MissingPluginException {
      throw const FormatException('当前设备不支持直接打开华为应用启动管理。');
    }
  }

  Future<Map<String, dynamic>> openDownloadedApk(String path) async {
    try {
      final result = await _systemNotificationChannel
          .invokeMapMethod<String, dynamic>('openDownloadedApk', {
            'path': path,
          });
      if (result == null) {
        throw const FormatException('无法打开系统安装界面。');
      }
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? '无法打开系统安装界面。');
    } on MissingPluginException {
      throw const FormatException('当前设备不支持应用内安装更新。');
    }
  }

  Future<Map<String, dynamic>> launchWearableManager(String brand) async {
    try {
      final result = await _systemNotificationChannel
          .invokeMapMethod<String, dynamic>('launchWearableManager', {
            'brand': brand,
          });
      if (result == null) {
        throw const FormatException('无法启动手环管理软件。');
      }
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? '无法启动手环管理软件。');
    } on MissingPluginException {
      throw const FormatException('当前设备不支持直接启动手环管理软件。');
    }
  }

  static int createBaseId(int chunkCount) {
    final maximumBaseId = 2000000000 - chunkCount - 1;
    return DateTime.now().millisecondsSinceEpoch.remainder(
      math.max(1, maximumBaseId).toInt(),
    );
  }

  Future<void> showChunk({
    required int id,
    required int index,
    required int total,
    required String text,
  }) async {
    await initialize();
    await showChunkWithPlugin(
      _plugin,
      id: id,
      index: index,
      total: total,
      text: text,
    );
  }

  static Future<void> showChunkWithPlugin(
    FlutterLocalNotificationsPlugin plugin, {
    required int id,
    required int index,
    required int total,
    required String text,
  }) {
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _notificationChannelId,
        _notificationChannelName,
        channelDescription: _notificationChannelDescription,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        groupKey: _notificationGroupKey,
        styleInformation: BigTextStyleInformation(text),
      ),
    );
    return plugin.show(
      id: id,
      title: '小说片段 ${index + 1}/$total',
      body: text,
      notificationDetails: details,
      payload: 'chunk:${index + 1}',
    );
  }
}

class BackgroundNovelSender {
  BackgroundNovelSender._();

  static const _serviceId = 4160;
  static const _chunksKey = 'novel_chunks_json';
  static const _nextIndexKey = 'novel_next_index';
  static const _notificationBaseIdKey = 'novel_notification_base_id';
  static const _bookIdKey = 'novel_book_id';

  static void initialize() {
    _configure(intervalMilliseconds: 1000);
  }

  static void _configure({required int intervalMilliseconds}) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'novel_background_sender',
        channelName: '小说后台发送',
        channelDescription: '小说片段正在按设定频率发送。',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(intervalMilliseconds),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowAutoRestart: true,
        allowWakeLock: true,
        allowWifiLock: false,
        stopWithTask: false,
      ),
    );
  }

  static Future<void> start({
    String? bookId,
    required List<String> chunks,
    required int intervalMilliseconds,
    required int startIndex,
    required int notificationBaseId,
  }) async {
    if (chunks.isEmpty) {
      throw ArgumentError('没有可发送的小说分段。');
    }
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }

    _configure(
      intervalMilliseconds: intervalMilliseconds.clamp(100, 3600000).toInt(),
    );
    await FlutterForegroundTask.saveData(key: _bookIdKey, value: bookId ?? '');
    await FlutterForegroundTask.saveData(
      key: _chunksKey,
      value: jsonEncode(chunks),
    );
    await FlutterForegroundTask.saveData(
      key: _nextIndexKey,
      value: startIndex.clamp(0, chunks.length).toInt(),
    );
    await FlutterForegroundTask.saveData(
      key: _notificationBaseIdKey,
      value: notificationBaseId,
    );

    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: '小说后台发送中',
      notificationText:
          '准备从第 ${startIndex.clamp(0, chunks.length) + 1}/${chunks.length} 段发送',
      notificationButtons: const [NotificationButton(id: 'stop', text: '停止')],
      callback: backgroundNovelTaskStartCallback,
    );
    if (result is ServiceRequestFailure) {
      throw result.error;
    }
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}

@pragma('vm:entry-point')
void backgroundNovelTaskStartCallback() {
  FlutterForegroundTask.setTaskHandler(BackgroundNovelTaskHandler());
}

class BackgroundNovelTaskHandler extends TaskHandler {
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _isReady = false;
  bool _isComplete = false;
  bool _isSending = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    DartPluginRegistrant.ensureInitialized();
    await NotificationService.initializePlugin(_notifications);
    _isReady = true;
    final storedBookId = await FlutterForegroundTask.getData<String>(
      key: BackgroundNovelSender._bookIdKey,
    );
    final bookId = storedBookId == null || storedBookId.isEmpty
        ? null
        : storedBookId;
    FlutterForegroundTask.sendDataToMain({'type': 'started', 'bookId': bookId});
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_sendNext());
  }

  Future<void> _sendNext() async {
    if (!_isReady || _isComplete || _isSending) {
      return;
    }
    _isSending = true;
    try {
      final chunksJson = await FlutterForegroundTask.getData<String>(
        key: BackgroundNovelSender._chunksKey,
      );
      final nextIndex = await FlutterForegroundTask.getData<int>(
        key: BackgroundNovelSender._nextIndexKey,
      );
      final baseId = await FlutterForegroundTask.getData<int>(
        key: BackgroundNovelSender._notificationBaseIdKey,
      );
      final storedBookId = await FlutterForegroundTask.getData<String>(
        key: BackgroundNovelSender._bookIdKey,
      );
      final bookId = storedBookId == null || storedBookId.isEmpty
          ? null
          : storedBookId;
      if (chunksJson == null || nextIndex == null || baseId == null) {
        await _finish(stopped: true);
        return;
      }

      final decoded = jsonDecode(chunksJson);
      if (decoded is! List) {
        await _finish(stopped: true);
        return;
      }
      final chunks = decoded
          .map((item) => item.toString())
          .toList(growable: false);
      if (nextIndex >= chunks.length) {
        await _finish();
        return;
      }

      final text = chunks[nextIndex];
      await NotificationService.showChunkWithPlugin(
        _notifications,
        id: baseId + nextIndex,
        index: nextIndex,
        total: chunks.length,
        text: text,
      );
      final sent = nextIndex + 1;
      await FlutterForegroundTask.saveData(
        key: BackgroundNovelSender._nextIndexKey,
        value: sent,
      );
      await LocalAppStore.instance.updateSendingProgress(
        sent,
        expectedBookId: bookId,
      );
      await FlutterForegroundTask.updateService(
        notificationTitle: '小说后台发送中',
        notificationText: '已发送 $sent/${chunks.length} 段',
      );
      FlutterForegroundTask.sendDataToMain({
        'type': 'progress',
        'sent': sent,
        'bookId': bookId,
      });

      if (sent >= chunks.length) {
        await _finish();
      }
    } catch (error) {
      // Preserve LocalAppStore progress so the foreground app can restart safely.
      final storedBookId = await FlutterForegroundTask.getData<String>(
        key: BackgroundNovelSender._bookIdKey,
      );
      final bookId = storedBookId == null || storedBookId.isEmpty
          ? null
          : storedBookId;
      FlutterForegroundTask.sendDataToMain({
        'type': 'interrupted',
        'error': error.toString(),
        'bookId': bookId,
      });
    } finally {
      _isSending = false;
    }
  }

  Future<void> _finish({bool stopped = false}) async {
    if (_isComplete) {
      return;
    }
    _isComplete = true;
    final storedBookId = await FlutterForegroundTask.getData<String>(
      key: BackgroundNovelSender._bookIdKey,
    );
    final bookId = storedBookId == null || storedBookId.isEmpty
        ? null
        : storedBookId;
    FlutterForegroundTask.sendDataToMain({
      'type': stopped ? 'stopped' : 'complete',
      'bookId': bookId,
    });
    if (!stopped) {
      await LocalAppStore.instance.clearActiveSendingSession(
        expectedBookId: bookId,
      );
    }
    await FlutterForegroundTask.stopService();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    if (!_isComplete) {
      final storedBookId = await FlutterForegroundTask.getData<String>(
        key: BackgroundNovelSender._bookIdKey,
      );
      final bookId = storedBookId == null || storedBookId.isEmpty
          ? null
          : storedBookId;
      FlutterForegroundTask.sendDataToMain({
        'type': 'interrupted',
        'bookId': bookId,
      });
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      unawaited(_finish(stopped: true));
    }
  }
}

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final _nameController = TextEditingController();
  final _keyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _chatPathController = TextEditingController();
  final _modelController = TextEditingController();
  final _promptController = TextEditingController();
  int _providerIndex = 0;
  bool _useReasoning = false;
  bool _hideKey = true;
  bool _isLoading = true;
  bool _isTesting = false;
  String? _statusMessage;
  List<AiModelInfo> _models = const [];

  @override
  void initState() {
    super.initState();
    for (final controller in [
      _nameController,
      _keyController,
      _baseUrlController,
      _chatPathController,
      _modelController,
      _promptController,
    ]) {
      controller.addListener(_autosave);
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final controller in [
      _nameController,
      _keyController,
      _baseUrlController,
      _chatPathController,
      _modelController,
      _promptController,
    ]) {
      controller
        ..removeListener(_autosave)
        ..dispose();
    }
    super.dispose();
  }

  StoredAiSettings get _settings => StoredAiSettings(
    providerIndex: _providerIndex,
    apiName: _nameController.text,
    apiKey: _keyController.text,
    baseUrl: _baseUrlController.text,
    chatPath: _chatPathController.text,
    model: _modelController.text,
    useReasoning: _useReasoning,
    customPrompt: _promptController.text,
  );

  Future<void> _load() async {
    final stored = await LocalAppStore.instance.loadAiSettings();
    if (!mounted) {
      return;
    }
    setState(() {
      _providerIndex = stored.providerIndex;
      _nameController.text = stored.apiName;
      _keyController.text = stored.apiKey;
      _baseUrlController.text = stored.baseUrl;
      _chatPathController.text = stored.chatPath;
      _modelController.text = stored.model;
      _useReasoning = stored.useReasoning;
      _promptController.text = stored.customPrompt;
      _isLoading = false;
    });
  }

  Future<void> _persist() => LocalAppStore.instance.saveAiSettings(
    providerIndex: _providerIndex,
    apiName: _nameController.text,
    apiKey: _keyController.text,
    baseUrl: _baseUrlController.text,
    chatPath: _chatPathController.text,
    model: _modelController.text,
    useReasoning: _useReasoning,
    customPrompt: _promptController.text,
  );

  void _autosave() {
    if (!_isLoading) {
      unawaited(_persist());
    }
  }

  void _setProvider(int index) {
    setState(() {
      _providerIndex = index;
      if (index == 0) {
        _nameController.text = 'OpenAI';
        _baseUrlController.text = 'https://api.openai.com/v1';
        _chatPathController.text = '/chat/completions';
      } else if (_nameController.text.trim().isEmpty ||
          _nameController.text.trim() == 'OpenAI') {
        _nameController.text = '兼容 API';
      }
    });
    unawaited(_persist());
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _statusMessage = null;
    });
    try {
      await _persist();
      final service = AiSummaryService();
      try {
        final models = await service.testConnection(_settings);
        if (mounted) {
          setState(() {
            _models = models;
            _statusMessage = '连接正常，已读取 ${models.length} 个可用模型。';
          });
        }
      } finally {
        service.dispose();
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _statusMessage = error.message.toString());
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _statusMessage = '连接测试失败，请检查网络、Base URL、API Key 与 /models 支持情况。',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isTesting = false);
      }
    }
  }

  Future<void> _pickModel() async {
    await _persist();
    if (!mounted) {
      return;
    }
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => AiModelPickerPage(settings: _settings)),
    );
    if (selected == null || !mounted) {
      return;
    }
    _modelController.text = selected;
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('AI 设置与模型')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: theme.colorScheme.primaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '配置将仅保存在本机。AI 总结会把你选择的分段发送至所配置的服务；请只使用你信任的 API，并确保具备对应服务的授权。',
                ),
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  icon: Icon(Icons.auto_awesome_outlined),
                  label: Text('OpenAI'),
                ),
                ButtonSegment(
                  value: 1,
                  icon: Icon(Icons.settings_ethernet_outlined),
                  label: Text('兼容 API'),
                ),
              ],
              selected: {_providerIndex},
              onSelectionChanged: (selected) => _setProvider(selected.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '名称',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _keyController,
              obscureText: _hideKey,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'API Key',
                prefixIcon: const Icon(Icons.key_outlined),
                suffixIcon: IconButton(
                  tooltip: _hideKey ? '显示 API Key' : '隐藏 API Key',
                  onPressed: () => setState(() => _hideKey = !_hideKey),
                  icon: Icon(
                    _hideKey
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'API Base URL',
                helperText: '例如 https://api.openai.com/v1',
                prefixIcon: Icon(Icons.link_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _chatPathController,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'API 路径',
                helperText: '默认 /chat/completions',
                prefixIcon: Icon(Icons.account_tree_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.hub_outlined),
                title: const Text('大模型选择'),
                subtitle: Text(
                  _modelController.text.trim().isEmpty
                      ? '尚未选择；点击后从 API 的 /models 列表读取。'
                      : _modelController.text.trim(),
                ),
                trailing: const Icon(Icons.chevron_right_outlined),
                onTap: _pickModel,
              ),
            ),
            if (_models.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '已缓存 ${_models.length} 个模型；可随时重新打开选择页刷新。',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _modelController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '手动填写模型 ID',
                helperText: '当服务不支持 /models 时，可按服务文档手动填写。',
                prefixIcon: Icon(Icons.edit_outlined),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile.adaptive(
                secondary: const Icon(Icons.psychology_outlined),
                title: const Text('使用深度思考'),
                subtitle: const Text(
                  '开启时请求会携带 reasoning_effort=medium。仅在当前模型与兼容服务支持该参数时开启；如返回参数错误，请关闭后重试。',
                ),
                value: _useReasoning,
                onChanged: (enabled) {
                  setState(() => _useReasoning = enabled);
                  unawaited(_persist());
                },
              ),
            ),
            const SizedBox(height: 16),
            Text('AI 提示词', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('内置提示词', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    const SelectableText(AiSummaryService.builtInPrompt),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _promptController,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: '附加提示词（可选）',
                        helperText: '附加要求会与内置“保留情节完整性”规则一同发送。',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isTesting ? null : _testConnection,
              icon: _isTesting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check_outlined),
              label: Text(_isTesting ? '正在测试连接…' : '测试 AI 连通性并读取模型'),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Card(
                color: _statusMessage!.startsWith('连接正常')
                    ? theme.colorScheme.secondaryContainer
                    : theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _statusMessage!,
                    style: TextStyle(
                      color: _statusMessage!.startsWith('连接正常')
                          ? theme.colorScheme.onSecondaryContainer
                          : theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AiModelPickerPage extends StatefulWidget {
  const AiModelPickerPage({required this.settings, super.key});

  final StoredAiSettings settings;

  @override
  State<AiModelPickerPage> createState() => _AiModelPickerPageState();
}

class _AiModelPickerPageState extends State<AiModelPickerPage> {
  List<AiModelInfo> _models = const [];
  String? _errorMessage;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadModels());
  }

  Future<void> _loadModels() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    final service = AiSummaryService();
    try {
      final models = await service.fetchModels(widget.settings);
      if (mounted) {
        setState(() => _models = models);
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _errorMessage = error.message.toString());
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = '读取模型失败，请检查网络、API Key 和 /models 接口。');
      }
    } finally {
      service.dispose();
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择支持的大模型'),
        actions: [
          IconButton(
            tooltip: '刷新模型列表',
            onPressed: _isLoading ? null : _loadModels,
            icon: const Icon(Icons.refresh_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _errorMessage != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_outlined, size: 56),
                      const SizedBox(height: 16),
                      Text(_errorMessage!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _loadModels,
                        icon: const Icon(Icons.refresh_outlined),
                        label: const Text('重试读取'),
                      ),
                    ],
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _models.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            '以下模型来自当前 API 的 /models 返回。选择后会自动保存至本机 AI 设置。',
                          ),
                        ),
                      ),
                    );
                  }
                  final model = _models[index - 1];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      leading: const Icon(Icons.smart_toy_outlined),
                      title: Text(model.id),
                      subtitle: model.displayName == model.id
                          ? null
                          : Text(model.displayName),
                      trailing: const Icon(Icons.chevron_right_outlined),
                      onTap: () => Navigator.of(context).pop(model.id),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class AiSegmentSummaryPage extends StatefulWidget {
  const AiSegmentSummaryPage({
    required this.chunks,
    required this.maxCharacters,
    super.key,
  });

  final List<String> chunks;
  final int maxCharacters;

  @override
  State<AiSegmentSummaryPage> createState() => _AiSegmentSummaryPageState();
}

class _AiSegmentSummaryPageState extends State<AiSegmentSummaryPage> {
  late List<String> _summarizedChunks;
  late int _targetCharacters;
  final Set<int> _selectedIndexes = <int>{};
  SummaryRichness _richness = SummaryRichness.balanced;
  StoredAiSettings? _settings;
  bool _isLoadingSettings = true;
  bool _isSummarizing = false;
  bool _cancelRequested = false;
  int _completed = 0;
  int _total = 0;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _summarizedChunks = List<String>.of(widget.chunks);
    _targetCharacters = widget.maxCharacters.clamp(20, 250).toInt();
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    final settings = await LocalAppStore.instance.loadAiSettings();
    if (mounted) {
      setState(() {
        _settings = settings;
        _isLoadingSettings = false;
      });
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => const AiSettingsPage()));
    await _loadSettings();
  }

  void _toggleAll() {
    setState(() {
      if (_selectedIndexes.length == _summarizedChunks.length) {
        _selectedIndexes.clear();
      } else {
        _selectedIndexes
          ..clear()
          ..addAll(
            List<int>.generate(_summarizedChunks.length, (index) => index),
          );
      }
    });
  }

  Future<void> _summarize() async {
    if (_isSummarizing) {
      return;
    }
    final settings = _settings;
    if (settings == null) {
      return;
    }
    if (settings.apiKey.trim().isEmpty || settings.model.trim().isEmpty) {
      setState(
        () => _errorMessage = '请先在 AI 设置中填写 API Key，并从模型选择页选择或手动填写模型 ID。',
      );
      return;
    }
    if (_selectedIndexes.isEmpty) {
      setState(() => _errorMessage = '请至少选择一个分段，或使用“全选分段”。');
      return;
    }
    final targetIndexes = _selectedIndexes.toList()
      ..sort((left, right) => right.compareTo(left));
    setState(() {
      _isSummarizing = true;
      _cancelRequested = false;
      _completed = 0;
      _total = targetIndexes.length;
      _errorMessage = null;
    });
    final service = AiSummaryService();
    try {
      for (final index in targetIndexes) {
        if (_cancelRequested) {
          break;
        }
        final source = _summarizedChunks[index];
        final summary = await service.summarizeSegment(
          settings: settings,
          content: source,
          targetCharacters: _targetCharacters,
          richness: _richness,
        );
        if (!mounted) {
          return;
        }
        final normalized = NovelTextSplitter.split(
          summary,
          maxCharacters: widget.maxCharacters,
        );
        if (normalized.isEmpty) {
          throw const FormatException('AI 返回内容在分段校验后为空。');
        }
        _summarizedChunks.replaceRange(index, index + 1, normalized);
        setState(() => _completed++);
      }
      if (mounted && _completed > 0) {
        setState(() {
          _selectedIndexes.clear();
          if (_cancelRequested) {
            _errorMessage = '已停止后续总结；已完成的 $_completed 段可继续应用。';
          }
        });
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _errorMessage = error.message.toString());
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = 'AI 总结失败，请检查网络、模型能力、深度思考参数和服务限额后重试。');
      }
    } finally {
      service.dispose();
      if (mounted) {
        setState(() => _isSummarizing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = _settings;
    final maxTarget = widget.maxCharacters.clamp(20, 250).toDouble();
    final progress = _total == 0 ? 0.0 : _completed / _total;
    return PopScope(
      canPop: !_isSummarizing,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AI 总结分段'),
          actions: [
            TextButton(
              onPressed: _isSummarizing
                  ? null
                  : () => Navigator.of(context).pop(_summarizedChunks),
              child: const Text('应用结果'),
            ),
          ],
        ),
        body: SafeArea(
          child: _isLoadingSettings
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      color: theme.colorScheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('情节完整性优先', style: theme.textTheme.titleMedium),
                            const SizedBox(height: 8),
                            const Text(
                              '内置提示词要求 AI 保留人物、事件、转折、线索和因果关系。总结结果会再次按当前最大分段字数校验；仅在你点击“应用结果”后写回书库。',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.hub_outlined),
                        title: const Text('当前 AI 配置'),
                        subtitle: Text(
                          settings == null || settings.model.trim().isEmpty
                              ? '尚未选择模型'
                              : '${settings.apiName} · ${settings.model}${settings.useReasoning ? ' · 深度思考' : ''}',
                        ),
                        trailing: const Icon(Icons.settings_outlined),
                        onTap: _isSummarizing ? null : _openSettings,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text('总结范围', style: theme.textTheme.titleMedium),
                        const Spacer(),
                        TextButton(
                          onPressed: _isSummarizing ? null : _toggleAll,
                          child: Text(
                            _selectedIndexes.length == _summarizedChunks.length
                                ? '取消全选'
                                : '全选分段',
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '已选择 ${_selectedIndexes.length}/${_summarizedChunks.length} 段。可以仅勾选部分段落，或一次总结全部段落。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '单段目标字数：$_targetCharacters',
                              style: theme.textTheme.titleSmall,
                            ),
                            Slider(
                              value: _targetCharacters.toDouble(),
                              min: 20,
                              max: maxTarget,
                              divisions: (maxTarget - 20).round(),
                              label: '$_targetCharacters 字',
                              onChanged: _isSummarizing
                                  ? null
                                  : (value) => setState(
                                      () => _targetCharacters = value.round(),
                                    ),
                            ),
                            Text(
                              '目标字数不会超过当前单段最大字数 ${widget.maxCharacters}。',
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 16),
                            Text('内容丰富程度', style: theme.textTheme.titleSmall),
                            const SizedBox(height: 8),
                            SegmentedButton<SummaryRichness>(
                              segments: SummaryRichness.values
                                  .map(
                                    (value) => ButtonSegment(
                                      value: value,
                                      label: Text(value.title),
                                    ),
                                  )
                                  .toList(growable: false),
                              selected: {_richness},
                              onSelectionChanged: _isSummarizing
                                  ? null
                                  : (selected) => setState(
                                      () => _richness = selected.first,
                                    ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _richness.description,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_isSummarizing) ...[
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 8),
                      Text(
                        '正在总结 $_completed/$_total 段… 当前请求完成后会响应取消。',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () =>
                            setState(() => _cancelRequested = true),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('停止后续总结'),
                      ),
                    ] else
                      FilledButton.icon(
                        onPressed: _summarize,
                        icon: const Icon(Icons.auto_awesome_outlined),
                        label: Text(
                          _selectedIndexes.isEmpty
                              ? '选择分段后开始 AI 总结'
                              : '总结已选 ${_selectedIndexes.length} 段',
                        ),
                      ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Card(
                        color: _errorMessage!.startsWith('已停止')
                            ? theme.colorScheme.tertiaryContainer
                            : theme.colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              color: _errorMessage!.startsWith('已停止')
                                  ? theme.colorScheme.onTertiaryContainer
                                  : theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text('选择分段', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (
                      var index = 0;
                      index < _summarizedChunks.length;
                      index++
                    )
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: CheckboxListTile(
                          value: _selectedIndexes.contains(index),
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            '第 ${index + 1} 段 · ${_summarizedChunks[index].runes.length} 字',
                          ),
                          subtitle: Text(
                            _summarizedChunks[index],
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: _isSummarizing
                              ? null
                              : (selected) => setState(() {
                                  if (selected == true) {
                                    _selectedIndexes.add(index);
                                  } else {
                                    _selectedIndexes.remove(index);
                                  }
                                }),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class NetworkApiSettingsPage extends StatefulWidget {
  const NetworkApiSettingsPage({super.key});

  @override
  State<NetworkApiSettingsPage> createState() => _NetworkApiSettingsPageState();
}

class _NetworkApiSettingsPageState extends State<NetworkApiSettingsPage> {
  late final TextEditingController _urlController;
  late final TextEditingController _titleController;
  late final TextEditingController _authorizationController;
  bool _isLoading = true;
  bool _isTesting = false;
  DownloadCancellationToken _testCancellationToken =
      DownloadCancellationToken();
  DownloadProgress? _testProgress;
  DownloadedNetworkBook? _testBook;
  String? _message;
  String? _testError;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _titleController = TextEditingController();
    _authorizationController = TextEditingController();
    _urlController.addListener(_autosave);
    _titleController.addListener(_autosave);
    _authorizationController.addListener(_autosave);
    unawaited(_load());
  }

  @override
  void dispose() {
    _urlController
      ..removeListener(_autosave)
      ..dispose();
    _titleController
      ..removeListener(_autosave)
      ..dispose();
    _authorizationController
      ..removeListener(_autosave)
      ..dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await LocalAppStore.instance.loadNetworkImportSettings();
    if (!mounted) {
      return;
    }
    setState(() {
      _urlController.text = settings.url;
      _titleController.text = settings.title;
      _authorizationController.text = settings.authorization;
      _isLoading = false;
    });
  }

  Future<void> _persistSettings() {
    return LocalAppStore.instance.saveNetworkImportSettings(
      url: _urlController.text,
      title: _titleController.text,
      authorization: _authorizationController.text,
    );
  }

  void _autosave() {
    if (!_isLoading) {
      unawaited(_persistSettings());
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _testApi() async {
    if (_isTesting) {
      return;
    }
    final url = _urlController.text.trim();
    final uri = Uri.tryParse(url);
    if (url.isEmpty ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() {
        _testError = '请先填写有效的 http:// 或 https:// API 地址，再进行测试。';
        _testBook = null;
      });
      return;
    }
    await _persistSettings();
    if (!mounted) return;
    if (_testCancellationToken.isCancelled) {
      _testCancellationToken = DownloadCancellationToken();
    }
    setState(() {
      _isTesting = true;
      _testProgress = null;
      _testBook = null;
      _testError = null;
      _message = '正在测试 API 连通性与响应可用性…';
    });
    try {
      final book = await NetworkBookImporter.downloadWithProgress(
        url: url,
        titleFallback: _titleController.text,
        authorization: _authorizationController.text,
        cancellationToken: _testCancellationToken,
        onProgress: (progress) {
          if (mounted) setState(() => _testProgress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _isTesting = false;
        _testBook = book;
        _message = 'API 连通，响应可用且已通过正文完整性校验。';
      });
    } on DownloadCancelledException {
      if (mounted) {
        setState(() {
          _isTesting = false;
          _testError = 'API 测试已取消。';
          _message = null;
        });
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _isTesting = false;
          _testError = error.message.toString();
          _message = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isTesting = false;
          _testError = '无法连接或验证 API：$error';
          _message = null;
        });
      }
    }
  }

  void _cancelTest() {
    if (_isTesting) {
      _testCancellationToken.cancel();
      setState(() => _message = '正在取消 API 测试…');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('API 导入详情')),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '此页面只保存 API 导入详情。实际导入请从“导入图书 → 网络导入图书 → 从已配置 API 导入”进入，并在查看详情后确认下载。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '图书 API 地址',
                      hintText: 'https://example.com/book.txt 或 JSON API',
                      prefixIcon: Icon(Icons.link_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: '书名回退（可选）',
                      helperText: '接口未提供书名时使用；留空时会使用“网络图书”。',
                      prefixIcon: Icon(Icons.title_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _authorizationController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Authorization（可选）',
                      hintText: '例如 Bearer <token>',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '支持直接返回纯文本，或返回包含 title/name 与 content/text/body 字段的 JSON。导入时会校验响应、正文、UTF-8 解码和文件长度。',
                      ),
                    ),
                  ),
                  if (_isTesting) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: _testProgress?.fraction),
                    const SizedBox(height: 8),
                    Text(
                      _testProgress == null
                          ? '正在连接 API…'
                          : _testProgress!.fraction == null
                          ? '已接收 ${_formatBytes(_testProgress!.receivedBytes)}'
                          : '${_formatBytes(_testProgress!.receivedBytes)} / ${_formatBytes(_testProgress!.totalBytes!)}  ${(_testProgress!.fraction! * 100).toStringAsFixed(1)}%',
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (_testBook != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '测试结果：可用于导入',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            Text('书名：${_testBook!.title}'),
                            Text(
                              '正文：${_testBook!.text.runes.length} 个字符 · ${_formatBytes(_testBook!.byteLength)}',
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '✓ HTTP 成功响应与非 HTML 文本\n✓ 流式长度、UTF-8 和有效正文校验通过',
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _testBook!.text.runes.take(160).join() +
                                  (_testBook!.text.runes.length > 160
                                      ? '…'
                                      : ''),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (_testError != null) ...[
                    const SizedBox(height: 12),
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _testError!,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _message!,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (_isTesting)
                    OutlinedButton.icon(
                      onPressed: _cancelTest,
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('取消测试'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _testApi,
                      icon: const Icon(Icons.network_check_outlined),
                      label: const Text('测试连接与响应'),
                    ),
                  const SizedBox(height: 10),
                  Text(
                    '修改会自动保存；测试前也会再次保存当前输入。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
      ),
    );
  }
}

class NetworkApiImportDetailPage extends StatelessWidget {
  const NetworkApiImportDetailPage({required this.request, super.key});

  final NetworkImportRequest request;

  String get _configuredTitle =>
      request.title.trim().isEmpty ? '网络图书' : request.title.trim();

  String get _host => Uri.tryParse(request.url)?.host ?? request.url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('查看 API 导入详情')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _configuredTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text('来源：$_host'),
                      const SizedBox(height: 8),
                      Text(
                        'API 地址：${request.url}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        request.authorization.trim().isEmpty
                            ? 'Authorization：未配置'
                            : 'Authorization：已配置（为保护凭据不显示内容）',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '实际连通性与响应可用性测试请在“设置 → API 导入详情”中执行。确认后将下载图书、显示进度、校验完整性，并自动导入本地书库。',
                  ),
                ),
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('返回导入界面'),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.download_outlined),
                label: const Text('确认下载并导入'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NetworkBookStoragePage extends StatefulWidget {
  const NetworkBookStoragePage({
    required this.books,
    required this.selectedBookId,
    required this.onDelete,
    super.key,
  });

  final List<StoredLibraryBook> books;
  final String? selectedBookId;
  final Future<void> Function(StoredLibraryBook book) onDelete;

  @override
  State<NetworkBookStoragePage> createState() => _NetworkBookStoragePageState();
}

class _NetworkBookStoragePageState extends State<NetworkBookStoragePage> {
  late List<StoredLibraryBook> _books;
  String? _deletingBookId;

  @override
  void initState() {
    super.initState();
    _books = List<StoredLibraryBook>.of(widget.books);
  }

  Future<void> _delete(StoredLibraryBook book) async {
    final metadata = BookMetadataResolver.resolve(
      fileName: book.fileName,
      text: book.text,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const Text('删除已下载图书？'),
        content: Text(
          '将从本地书库移除《${metadata.title}》及其发送断点。此操作不会影响在线书源，可以日后重新下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _deletingBookId = book.id);
    try {
      await widget.onDelete(book);
      if (!mounted) {
        return;
      }
      setState(() => _books.removeWhere((item) => item.id == book.id));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已删除《${metadata.title}》。')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    } finally {
      if (mounted) {
        setState(() => _deletingBookId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('书源下载管理')),
      body: SafeArea(
        child: _books.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.inventory_2_outlined,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text('暂未保存书源下载图书', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      const Text(
                        '从网络 API 或公共领域目录完成下载、校验和导入后，图书会自动出现在这里。',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _books.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Card(
                        color: theme.colorScheme.secondaryContainer,
                        child: const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            '这里仅管理通过书源下载并导入的图书。删除会同时清理该书的发送断点；本地导入图书不受影响。',
                          ),
                        ),
                      ),
                    );
                  }
                  final book = _books[index - 1];
                  final metadata = BookMetadataResolver.resolve(
                    fileName: book.fileName,
                    text: book.text,
                  );
                  final deleting = _deletingBookId == book.id;
                  final selected = widget.selectedBookId == book.id;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: theme.colorScheme.primaryContainer,
                        foregroundColor: theme.colorScheme.onPrimaryContainer,
                        child: const Icon(Icons.cloud_download_outlined),
                      ),
                      title: Text(
                        metadata.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${book.text.runes.length} 个字符 · ${book.fileName ?? '网络图书.txt'}${selected ? ' · 当前选中' : ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      isThreeLine: false,
                      trailing: deleting
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              tooltip: '删除已下载图书',
                              onPressed: _deletingBookId == null
                                  ? () => _delete(book)
                                  : null,
                              icon: const Icon(Icons.delete_outline),
                            ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class CatalogBookDownloadPage extends StatefulWidget {
  const CatalogBookDownloadPage({
    required this.book,
    required this.onImport,
    super.key,
  }) : request = null;

  const CatalogBookDownloadPage.forApi({
    required this.request,
    required this.onImport,
    super.key,
  }) : book = null;

  final PublicDomainBookResult? book;
  final NetworkImportRequest? request;
  final Future<void> Function(DownloadedNetworkBook book) onImport;

  bool get isApiImport => request != null;

  String get title =>
      book?.title ??
      (request!.title.trim().isEmpty ? '网络图书' : request!.title.trim());

  String get subtitle {
    if (book != null) {
      return book!.author;
    }
    return Uri.tryParse(request!.url)?.host ?? request!.url;
  }

  @override
  State<CatalogBookDownloadPage> createState() =>
      _CatalogBookDownloadPageState();
}

class _CatalogBookDownloadPageState extends State<CatalogBookDownloadPage> {
  DownloadCancellationToken _cancellationToken = DownloadCancellationToken();
  DownloadProgress? _progress;
  DownloadedNetworkBook? _downloaded;
  String _stage = '正在连接公共领域图书源…';
  String? _errorMessage;
  bool _isDownloading = false;
  bool _isImporting = false;

  bool get _isBusy => _isDownloading || _isImporting;

  String get _sourceLabel => widget.isApiImport ? '已配置 API' : '公共领域图书源';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _downloadAndImport());
  }

  Future<void> _downloadAndImport() async {
    if (_isBusy || _downloaded != null) {
      return;
    }
    if (_cancellationToken.isCancelled) {
      _cancellationToken = DownloadCancellationToken();
    }
    setState(() {
      _isDownloading = true;
      _errorMessage = null;
      _stage = '正在下载《${widget.title}》…';
      _progress = null;
    });
    try {
      final downloaded = widget.isApiImport
          ? await NetworkBookImporter.downloadWithProgress(
              url: widget.request!.url,
              titleFallback: widget.request!.title,
              authorization: widget.request!.authorization,
              cancellationToken: _cancellationToken,
              onProgress: (progress) {
                if (mounted) {
                  setState(() {
                    _progress = progress;
                    final fraction = progress.fraction;
                    _stage = fraction == null
                        ? '正在下载图书内容…'
                        : '正在下载图书内容 ${(fraction * 100).toStringAsFixed(1)}%';
                  });
                }
              },
            )
          : await PublicDomainBookCatalog.downloadWithProgress(
              widget.book!,
              cancellationToken: _cancellationToken,
              onProgress: (progress) {
                if (mounted) {
                  setState(() {
                    _progress = progress;
                    final fraction = progress.fraction;
                    _stage = fraction == null
                        ? '正在下载图书内容…'
                        : '正在下载图书内容 ${(fraction * 100).toStringAsFixed(1)}%';
                  });
                }
              },
            );
      if (!mounted) {
        return;
      }
      setState(() {
        _isDownloading = false;
        _downloaded = downloaded;
        _stage = '下载完成，正在校验文件完整性与正文内容…';
      });
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) {
        return;
      }
      setState(() {
        _isImporting = true;
        _stage = '完整性校验通过，正在导入本地书库并切换到新图书…';
      });
      await widget.onImport(downloaded);
      if (!mounted) {
        return;
      }
      setState(() {
        _isImporting = false;
        _stage = '已完成下载、校验并导入本地书库。';
      });
    } on DownloadCancelledException {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _isImporting = false;
          _errorMessage = '下载已取消，未将任何内容写入本地书库。';
          _stage = '下载已取消';
        });
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _isImporting = false;
          _errorMessage = error.message.toString();
          _stage = '下载或完整性校验未通过';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _isImporting = false;
          _errorMessage = '下载或导入失败：$error';
          _stage = '流程未完成';
        });
      }
    }
  }

  void _cancelDownload() {
    if (!_isDownloading) {
      return;
    }
    _cancellationToken.cancel();
    setState(() => _stage = '正在取消下载…');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final progress = _progress;
    final fraction = progress?.fraction;
    final isSuccess = _downloaded != null && !_isBusy && _errorMessage == null;
    return PopScope(
      canPop: !_isBusy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('下载并导入图书'),
          automaticallyImplyLeading: !_isBusy,
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text('$_sourceLabel · ${widget.subtitle}'),
                        const SizedBox(height: 12),
                        Text(
                          '流程：确认下载 → 下载进度 → 完整性校验 → 自动导入本地书库 → 自动选中图书',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Icon(
                  isSuccess
                      ? Icons.check_circle_outline
                      : _errorMessage != null
                      ? Icons.error_outline
                      : Icons.downloading_outlined,
                  size: 56,
                  color: isSuccess
                      ? colorScheme.primary
                      : _errorMessage != null
                      ? colorScheme.error
                      : colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  _stage,
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (_isDownloading || _isImporting) ...[
                  LinearProgressIndicator(
                    value: _isImporting ? null : fraction,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    progress == null
                        ? '正在准备下载…'
                        : fraction == null
                        ? '已下载 ${_formatBytes(progress.receivedBytes)}'
                        : '${_formatBytes(progress.receivedBytes)} / ${_formatBytes(progress.totalBytes!)}  ${(fraction * 100).toStringAsFixed(1)}%',
                    textAlign: TextAlign.center,
                  ),
                ],
                if (_downloaded != null && !_isBusy) ...[
                  Card(
                    color: colorScheme.secondaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '完整性检查结果',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '✓ HTTP 成功响应与纯文本类型\n✓ 流式下载完成与长度校验\n✓ UTF-8 解码和有效正文校验\n✓ 已写入本地书库并自动选中',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '已导入 ${_formatBytes(_downloaded!.byteLength)}，正文 ${_downloaded!.text.runes.length} 个字符。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Card(
                    color: colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: colorScheme.onErrorContainer),
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (_isDownloading)
                  OutlinedButton.icon(
                    onPressed: _cancelDownload,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('取消下载'),
                  )
                else if (_errorMessage != null)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).pop(false),
                          icon: const Icon(Icons.arrow_back_outlined),
                          label: const Text('返回书库'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _downloadAndImport,
                          icon: const Icon(Icons.refresh_outlined),
                          label: const Text('重试下载'),
                        ),
                      ),
                    ],
                  )
                else if (isSuccess)
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.library_books_outlined),
                    label: const Text('返回书库'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PublicDomainBookSearchPage extends StatefulWidget {
  const PublicDomainBookSearchPage({super.key});

  @override
  State<PublicDomainBookSearchPage> createState() =>
      _PublicDomainBookSearchPageState();
}

class _PublicDomainBookSearchPageState
    extends State<PublicDomainBookSearchPage> {
  final TextEditingController _queryController = TextEditingController();
  List<PublicDomainBookResult> _results = const [];
  String? _errorMessage;
  String? _lastQuery;
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_refreshSearchInput);
  }

  void _refreshSearchInput() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _queryController
      ..removeListener(_refreshSearchInput)
      ..dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_isSearching) {
      return;
    }
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      setState(() => _errorMessage = '请输入书名、作者或关键词后再搜索。');
      return;
    }
    setState(() {
      _isSearching = true;
      _errorMessage = null;
      _lastQuery = query;
    });
    try {
      final results = await PublicDomainBookCatalog.search(query);
      if (!mounted) {
        return;
      }
      setState(() => _results = results);
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _errorMessage = error.message.toString());
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = '搜索失败，请检查网络连接后重试。');
      }
    } finally {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _openDetail(PublicDomainBookResult book) async {
    final shouldImport = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PublicDomainBookDetailPage(book: book)),
    );
    if (shouldImport == true && mounted) {
      Navigator.of(context).pop(book);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('搜索开源图书目录')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SearchBar(
                controller: _queryController,
                autoFocus: true,
                hintText: '书名、作者或关键词',
                leading: const Icon(Icons.search_outlined),
                trailing: [
                  if (_queryController.text.isNotEmpty && !_isSearching)
                    IconButton(
                      tooltip: '清除搜索词',
                      icon: const Icon(Icons.clear_outlined),
                      onPressed: () {
                        _queryController.clear();
                        setState(() {
                          _results = const [];
                          _errorMessage = null;
                          _lastQuery = null;
                        });
                      },
                    ),
                  IconButton(
                    tooltip: '开始搜索',
                    onPressed: _isSearching ? null : _search,
                    icon: const Icon(Icons.arrow_forward_outlined),
                  ),
                ],
                onSubmitted: (_) => _isSearching ? null : _search(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                '结果来自 Gutendex / Project Gutenberg 公共领域目录，仅显示可直接下载的纯文本图书。点击结果先查看详情，再确认导入。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_isSearching) const LinearProgressIndicator(),
            Expanded(child: _buildResults(context, colorScheme)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context, ColorScheme colorScheme) {
    if (_isSearching && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 48,
                color: colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _isSearching ? null : _search,
                icon: const Icon(Icons.refresh_outlined),
                label: const Text('重试搜索'),
              ),
            ],
          ),
        ),
      );
    }
    if (_lastQuery == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.menu_book_outlined,
                size: 56,
                color: colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                '输入书名、作者或关键词开始搜索',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                '例如：Sherlock Holmes、Frankenstein 或 Jane Austen',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off_outlined, size: 48),
              const SizedBox(height: 12),
              Text(
                '没有找到可直接下载的公共领域纯文本图书',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text('请更换关键词、使用英文书名或尝试作者姓名。', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: _results.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              '“$_lastQuery” 的 ${_results.length} 条可下载结果',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          );
        }
        final book = _results[index - 1];
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            leading: CircleAvatar(
              backgroundColor: colorScheme.secondaryContainer,
              foregroundColor: colorScheme.onSecondaryContainer,
              child: const Icon(Icons.auto_stories_outlined),
            ),
            title: Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${book.author}\n${book.language} · 目录下载 ${book.downloadCount}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            isThreeLine: true,
            trailing: IconButton(
              tooltip: '查看详情',
              icon: const Icon(Icons.arrow_forward_ios_outlined),
              onPressed: () => _openDetail(book),
            ),
            onTap: () => _openDetail(book),
          ),
        );
      },
    );
  }
}

class PublicDomainBookDetailPage extends StatelessWidget {
  const PublicDomainBookDetailPage({required this.book, super.key});

  final PublicDomainBookResult book;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('开源图书详情')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Icon(
              Icons.auto_stories_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(book.title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(book.author, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.language_outlined),
                    title: const Text('语言'),
                    trailing: Text(book.language),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: const Text('目录下载次数'),
                    trailing: Text('${book.downloadCount}'),
                  ),
                  const Divider(height: 1),
                  const ListTile(
                    leading: Icon(Icons.verified_outlined),
                    title: Text('来源'),
                    subtitle: Text('Project Gutenberg 公共领域目录'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('内容简介', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(book.summary),
            if (book.subjects.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('主题', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final subject in book.subjects.take(8))
                    Chip(label: Text(subject)),
                ],
              ),
            ],
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.download_outlined),
              label: const Text('下载并导入纯文本图书'),
            ),
          ],
        ),
      ),
    );
  }
}

class ImportedLocalBook {
  const ImportedLocalBook({required this.title, required this.text});

  final String title;
  final String text;
}

class LocalBookImporter {
  LocalBookImporter._();

  static const supportedExtensions = <String>[
    'txt',
    'text',
    'md',
    'markdown',
    'log',
    'json',
    'epub',
  ];

  static Future<ImportedLocalBook> decode(PlatformFile file) async {
    final bytes = await file.readAsBytes();
    final extension = _extensionOf(file.name);
    final fallbackTitle = _baseName(file.name);
    if (!supportedExtensions.contains(extension)) {
      final readableExtension = extension.isEmpty ? '无扩展名' : '.$extension';
      throw FormatException(
        '不支持 $readableExtension 格式。请重新选择 TXT、TEXT、Markdown、LOG、JSON 或 EPUB 图书文件。',
      );
    }
    if (extension == 'epub') {
      return _decodeEpub(bytes, fallbackTitle);
    }
    final raw = NovelTextFileDecoder.decode(bytes);
    final text = extension == 'json' ? _extractJsonText(raw) ?? raw : raw;
    if (text.trim().isEmpty) {
      throw FormatException('《$fallbackTitle》未包含可导入的文本内容。');
    }
    return ImportedLocalBook(title: fallbackTitle, text: text.trim());
  }

  static Future<ImportedLocalBook> _decodeEpub(
    Uint8List bytes,
    String fallbackTitle,
  ) async {
    try {
      final book = await EpubReader.readBook(bytes);
      final buffer = StringBuffer();
      void appendChapter(EpubChapter chapter) {
        final html = chapter.HtmlContent;
        if (html != null && html.trim().isNotEmpty) {
          final text = _stripHtml(html);
          if (text.isNotEmpty) {
            buffer.writeln(text);
            buffer.writeln();
          }
        }
        for (final child in chapter.SubChapters ?? const <EpubChapter>[]) {
          appendChapter(child);
        }
      }

      for (final chapter in book.Chapters ?? const <EpubChapter>[]) {
        appendChapter(chapter);
      }
      final text = buffer.toString().trim();
      if (text.isEmpty) {
        throw const FormatException('EPUB 中未找到可导入的章节文本。');
      }
      return ImportedLocalBook(
        title: (book.Title ?? '').trim().isEmpty
            ? fallbackTitle
            : book.Title!.trim(),
        text: text,
      );
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('无法解析 EPUB：$error');
    }
  }

  static String _stripHtml(String html) {
    return html
        .replaceAll(
          RegExp(
            r'<(script|style)[^>]*>[\\s\\S]*?</\\1>',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\\s+'), ' ')
        .trim();
  }

  static String? _extractJsonText(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return _findText(decoded);
    } on FormatException {
      return null;
    }
  }

  static String? _findText(Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      return value;
    }
    if (value is Map) {
      for (final key in const ['content', 'text', 'body', 'bookText', 'data']) {
        final found = _findText(value[key]);
        if (found != null) {
          return found;
        }
      }
    }
    return null;
  }

  static String _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  }

  static String _baseName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return (dot <= 0 ? fileName : fileName.substring(0, dot)).trim().isEmpty
        ? '本地图书'
        : (dot <= 0 ? fileName : fileName.substring(0, dot)).trim();
  }
}

class NovelTextFileDecoder {
  const NovelTextFileDecoder._();

  static String decode(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(
        bytes.sublist(2),
        littleEndian: true,
      ).replaceFirst('\uFEFF', '');
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(
        bytes.sublist(2),
        littleEndian: false,
      ).replaceFirst('\uFEFF', '');
    }
    return utf8.decode(bytes, allowMalformed: true).replaceFirst('\uFEFF', '');
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (var index = 0; index + 1 < bytes.length; index += 2) {
      final value = littleEndian
          ? bytes[index] | (bytes[index + 1] << 8)
          : (bytes[index] << 8) | bytes[index + 1];
      units.add(value);
    }
    return String.fromCharCodes(units);
  }
}

class NovelTextSplitter {
  const NovelTextSplitter._();

  /// 按 Unicode 代码点计数，保证每个分片不超过 [maxCharacters]。
  /// 优先在段落、句末标点和空白处切分，避免把汉语句子生硬截断。
  static List<String> split(
    String source, {
    required int maxCharacters,
    bool compactContent = false,
    bool removeEmoji = false,
    bool richContent = false,
  }) {
    if (maxCharacters <= 0) {
      throw ArgumentError.value(maxCharacters, 'maxCharacters', '必须大于 0。');
    }
    final normalized = normalize(
      source,
      compactContent: compactContent,
      removeEmoji: removeEmoji,
      richContent: richContent,
    );
    if (normalized.isEmpty) {
      return const [];
    }

    final runes = normalized.runes.toList();
    final result = <String>[];
    var start = 0;

    while (start < runes.length) {
      var end = math.min(start + maxCharacters, runes.length);
      if (end < runes.length && !richContent) {
        final preferredBreak = _findPreferredBreak(runes, start, end);
        if (preferredBreak != null) {
          end = preferredBreak;
        }
      }

      final chunk = String.fromCharCodes(runes.sublist(start, end));
      if (chunk.trim().isNotEmpty) {
        result.add(chunk);
      }
      start = end;
    }
    return result;
  }

  static String normalize(
    String source, {
    bool compactContent = false,
    bool removeEmoji = false,
    bool richContent = false,
  }) {
    var normalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (removeEmoji || richContent) {
      normalized = normalized.replaceAll(_emojiPattern, '');
    }
    if (richContent) {
      normalized = normalized.replaceAll(_richContentPunctuationPattern, '');
    }
    if (compactContent) {
      normalized = normalized
          .replaceAll(RegExp(r'[ \t]+\n'), '\n')
          .replaceAll(RegExp(r'\n[ \t]+'), '\n')
          .replaceAll(RegExp(r'\n[ \t]*\n[ \t]*(?:\n[ \t]*)+'), '\n\n');
    }
    return normalized.trim();
  }

  static final RegExp _emojiPattern = RegExp(
    r'[\u{1F000}-\u{1FAFF}\u{1FC00}-\u{1FFFD}\u{2600}-\u{27BF}\u{2300}-\u{23FF}\u{200D}\u{FE0F}\u{FE0E}]',
    unicode: true,
  );

  static final RegExp _richContentPunctuationPattern = RegExp(
    r'[，、,:：;；]',
    unicode: true,
  );

  static int? _findPreferredBreak(List<int> runes, int start, int end) {
    // 过早断句会产生很多非常短的通知，因此仅在分片后半段寻找断点。
    final minimumBreak = start + ((end - start) * 0.5).floor();
    const preferredBreaks = <int>{
      0x0A, // \n
      0x3002, // 。
      0xFF01, // ！
      0xFF1F, // ？
      0xFF1B, // ；
      0x0021, // !
      0x003F, // ?
      0x003B, // ;
    };
    const secondaryBreaks = <int>{
      0x3001, // 、
      0xFF0C, // ，
      0x002C, // ,
      0x0020, // space
      0x09, // tab
    };

    for (var index = end - 1; index >= minimumBreak; index--) {
      if (preferredBreaks.contains(runes[index])) {
        return index + 1;
      }
    }
    for (var index = end - 1; index >= minimumBreak; index--) {
      if (secondaryBreaks.contains(runes[index])) {
        return index + 1;
      }
    }
    return null;
  }
}
