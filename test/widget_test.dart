import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelnotifier/ai_summary_service.dart';
import 'package:novelnotifier/app_update_service.dart';
import 'package:novelnotifier/book_metadata.dart';
import 'package:novelnotifier/local_app_store.dart';
import 'package:novelnotifier/main.dart';
import 'package:novelnotifier/network_book_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('NovelTextSplitter', () {
    test('每个分片均不超过指定字符数，且拼接后保持正文完整', () {
      const source = '第一章：夜雨敲窗。林舟没有开灯，静静听着远处的钟声。\n\n第二章：风停了，信封却自己滑进门缝。';

      final chunks = NovelTextSplitter.split(source, maxCharacters: 18);

      expect(chunks, isNotEmpty);
      expect(chunks.every((chunk) => chunk.runes.length <= 18), isTrue);
      expect(chunks.join(), source);
    });

    test('会优先在句末标点处切分', () {
      const source = '春雨落在石阶上。书店的灯还亮着，门口没有客人。';

      final chunks = NovelTextSplitter.split(source, maxCharacters: 15);

      expect(chunks.first, '春雨落在石阶上。');
      expect(chunks.every((chunk) => chunk.runes.length <= 15), isTrue);
    });

    test('内容紧凑会合并分段前的连续空白行', () {
      const source = '第一段\n\n\n   \n第二段\n\t\n\n第三段';

      final chunks = NovelTextSplitter.split(
        source,
        maxCharacters: 200,
        compactContent: true,
      );

      expect(chunks, ['第一段\n\n第二段\n\n第三段']);
    });

    test('自动删除 Emoji 会保留普通文本和换行', () {
      const source = '第一段🙂\n第二段❤️\n第三段🚀';

      final chunks = NovelTextSplitter.split(
        source,
        maxCharacters: 200,
        removeEmoji: true,
      );

      expect(chunks, ['第一段\n第二段\n第三段']);
    });

    test('内容丰富模式会删除 Emoji 与弱标点并填满非末尾分段', () {
      const source = '甲，乙🙂、丙：丁；戊己';

      final chunks = NovelTextSplitter.split(
        source,
        maxCharacters: 3,
        richContent: true,
      );

      expect(chunks, ['甲乙丙', '丁戊己']);
      expect(chunks.every((chunk) => chunk.runes.length == 3), isTrue);
    });

    test('空文本不会生成通知分片', () {
      expect(NovelTextSplitter.split('  \n\t ', maxCharacters: 120), isEmpty);
    });

    test('非法分段上限会抛出明确异常', () {
      expect(
        () => NovelTextSplitter.split('小说正文', maxCharacters: 0),
        throwsArgumentError,
      );
    });
  });

  group('NovelTextFileDecoder', () {
    test('可解析 UTF-8 BOM 文本', () {
      final bytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('第一章'),
      ]);
      expect(NovelTextFileDecoder.decode(bytes), '第一章');
    });

    test('可解析 UTF-16 little-endian BOM 文本', () {
      final units = '夜雨'.codeUnits;
      final bytes = <int>[0xFF, 0xFE];
      for (final unit in units) {
        bytes
          ..add(unit & 0xFF)
          ..add((unit >> 8) & 0xFF);
      }
      expect(NovelTextFileDecoder.decode(Uint8List.fromList(bytes)), '夜雨');
    });
  });

  group('SegmentBatchAdjuster', () {
    test('只重新切分指定区间，并保持区间外段落与全文完整', () {
      const chunks = [
        '前缀内容保持不变',
        '甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥',
        '天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏',
      ];

      final adjusted = SegmentBatchAdjuster.adjust(
        chunks,
        startSegment: 2,
        endSegment: 3,
        maxCharacters: 20,
      );

      expect(adjusted.first, '前缀内容保持不变');
      expect(adjusted.skip(1).every((item) => item.runes.length <= 20), isTrue);
      expect(adjusted.join(), chunks.join());
    });
  });

  group('BookMetadataResolver', () {
    test('优先从 TXT 文件名清理得到书名，并生成正文简介', () {
      final metadata = BookMetadataResolver.resolve(
        fileName: '星河回响_[完结]_精校.txt',
        text: List<String>.filled(30, '这是开篇简介。').join(),
      );

      expect(metadata.title, '星河回响 精校');
      expect(metadata.introduction.endsWith('…'), isTrue);
    });

    test('没有文件名时使用未命名小说', () {
      final metadata = BookMetadataResolver.resolve(fileName: null, text: '正文');
      expect(metadata.title, '未命名小说');
    });
  });

  group('AiSummaryService', () {
    test('读取兼容模型列表并携带深度思考参数完成单段总结', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer ai-test-key');
        if (request.uri.path == '/v1/models') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {'id': 'story-model', 'owned_by': 'test-provider'},
              ],
            }),
          );
        } else if (request.uri.path == '/v1/chat/completions') {
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          expect(body['model'], 'story-model');
          expect(body['reasoning_effort'], 'medium');
          final messages = body['messages'] as List;
          expect(messages.first['content'], contains('情节完整'));
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '林舟收到信封，决定在雨停前出门。'},
                },
              ],
            }),
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write('{}');
        }
        await request.response.close();
      });
      addTearDown(server.close);
      final settings = StoredAiSettings(
        providerIndex: 1,
        apiName: '本地测试服务',
        apiKey: 'ai-test-key',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        chatPath: '/chat/completions',
        model: 'story-model',
        useReasoning: true,
        customPrompt: '保留雨夜氛围。',
      );
      final service = AiSummaryService();
      addTearDown(service.dispose);

      final models = await service.fetchModels(settings);
      final summary = await service.summarizeSegment(
        settings: settings,
        content: '林舟在雨夜收到一封没有署名的信，他决定在雨停前出门寻找寄信人。',
        targetCharacters: 60,
        richness: SummaryRichness.balanced,
      );

      expect(models.single.id, 'story-model');
      expect(summary, '林舟收到信封，决定在雨停前出门。');
    });
  });

  group('AppUpdateService', () {
    test('当前版本已是最新时不返回更新提示', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode([
            {
              'tag_name': '2.2Alpha4',
              'name': 'Band Novel Reader 2.2Alpha4',
              'draft': false,
              'assets': [
                {
                  'name': 'band-novel-reader.apk',
                  'browser_download_url':
                      'https://example.invalid/2.2Alpha4.apk',
                },
              ],
            },
          ]),
        );
        await request.response.close();
      });
      addTearDown(server.close);

      final update = await AppUpdateService.checkForUpdate(
        currentTag: '2.2Alpha4',
        endpoint: Uri.parse(
          'http://${server.address.address}:${server.port}/releases',
        ),
      );

      expect(update, isNull);
    });

    test('识别最高的可下载 Alpha 更新包', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode([
            {
              'tag_name': '2.2Alpha2',
              'name': 'Band Novel Reader 2.2Alpha2',
              'draft': false,
              'html_url': 'https://example.invalid/releases/2.2Alpha2',
              'body': '更新内容',
              'assets': [
                {
                  'name': 'band-novel-reader.apk',
                  'browser_download_url':
                      'https://example.invalid/2.2Alpha2.apk',
                },
              ],
            },
            {
              'tag_name': '2.2Alpha1',
              'name': 'Band Novel Reader 2.2Alpha1',
              'draft': false,
              'assets': const [],
            },
          ]),
        );
        await request.response.close();
      });
      addTearDown(server.close);

      final update = await AppUpdateService.checkForUpdate(
        currentTag: '2.2Alpha1',
        endpoint: Uri.parse(
          'http://${server.address.address}:${server.port}/releases',
        ),
      );

      expect(update?.tag, '2.2Alpha2');
      expect(update?.apkUrl, 'https://example.invalid/2.2Alpha2.apk');
    });
  });

  group('NetworkBookImporter', () {
    test('API 验证可携带授权并解析 JSON 图书响应', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const text = '这是由 API JSON 响应返回的完整图书正文，用于验证授权、连通性和可导入内容。';
      server.listen((request) async {
        expect(
          request.headers.value('authorization'),
          'Bearer verification-token',
        );
        final body = jsonEncode({'title': 'API 验证图书', 'content': text});
        final bytes = utf8.encode(body);
        request.response.headers.contentType = ContentType(
          'application',
          'json',
          charset: 'utf-8',
        );
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      addTearDown(server.close);

      final downloaded = await NetworkBookImporter.downloadWithProgress(
        url: 'http://${server.address.address}:${server.port}/book.json',
        titleFallback: '回退书名',
        authorization: 'Bearer verification-token',
      );

      expect(downloaded.title, 'API 验证图书');
      expect(downloaded.text, text);
    });

    test('流式下载报告进度并在完整文本校验后返回图书', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const text = '这是用于验证下载完整性与流式进度回调的公共领域测试正文，长度超过最小正文限制。';
      server.listen((request) {
        final bytes = utf8.encode(text);
        request.response.headers.contentType = ContentType(
          'text',
          'plain',
          charset: 'utf-8',
        );
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        request.response.close();
      });
      addTearDown(server.close);

      final progress = <DownloadProgress>[];
      final downloaded = await NetworkBookImporter.downloadWithProgress(
        url: 'http://${server.address.address}:${server.port}/book.txt',
        titleFallback: '本地测试图书',
        onProgress: progress.add,
      );

      expect(downloaded.title, '本地测试图书');
      expect(downloaded.text, text);
      expect(downloaded.byteLength, utf8.encode(text).length);
      expect(progress, isNotEmpty);
      expect(progress.last.receivedBytes, utf8.encode(text).length);
      expect(progress.last.fraction, 1.0);
    });
  });

  group('LocalAppStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('保存书籍、统一设置和断点后可以恢复', () async {
      await LocalAppStore.instance.saveDocument(
        text: '测试正文',
        fileName: '测试书.txt',
        maxCharacters: 180,
        modeIndex: 1,
        intervalMilliseconds: 25000,
        customChunks: const ['测试', '正文'],
        compactSegmentContent: true,
        removeEmojiFromSegments: true,
        richSegmentContent: true,
      );
      await LocalAppStore.instance.saveSendingSession(
        chunks: const ['测试', '正文'],
        nextIndex: 1,
        modeIndex: 1,
        intervalMilliseconds: 25000,
        notificationBaseId: 99,
      );

      final document = await LocalAppStore.instance.loadDocument();
      final session = await LocalAppStore.instance.loadSendingSession();

      expect(document.text, '测试正文');
      expect(document.fileName, '测试书.txt');
      expect(document.intervalMilliseconds, 25000);
      expect(document.customChunks, const ['测试', '正文']);
      expect(document.compactSegmentContent, isTrue);
      expect(document.removeEmojiFromSegments, isTrue);
      expect(document.richSegmentContent, isTrue);
      expect(session?.nextIndex, 1);
      expect(session?.canResume, isTrue);
    });

    test('API 导入详情可以持久化恢复', () async {
      await LocalAppStore.instance.saveNetworkImportSettings(
        url: ' https://example.com/book.json ',
        title: ' 网络测试图书 ',
        authorization: ' Bearer demo-token ',
      );

      final settings = await LocalAppStore.instance.loadNetworkImportSettings();

      expect(settings.url, 'https://example.com/book.json');
      expect(settings.title, '网络测试图书');
      expect(settings.authorization, 'Bearer demo-token');
    });

    test('启动推荐和 AI 设置可以持久化恢复', () async {
      await LocalAppStore.instance.saveStartupContentRecommendation(9);
      await LocalAppStore.instance.saveAiSettings(
        providerIndex: 1,
        apiName: '兼容服务',
        apiKey: 'local-key',
        baseUrl: 'https://example.com/v1',
        chatPath: '/chat/completions',
        model: 'story-model',
        useReasoning: true,
        customPrompt: '保留关键线索。',
      );

      final recommendation = await LocalAppStore.instance
          .loadStartupContentRecommendation();
      final ai = await LocalAppStore.instance.loadAiSettings();

      expect(recommendation, 9);
      expect(ai.apiName, '兼容服务');
      expect(ai.model, 'story-model');
      expect(ai.useReasoning, isTrue);
      expect(ai.customPrompt, '保留关键线索。');
    });

    test('多书库与当前选择可以持久化恢复', () async {
      const books = [
        StoredLibraryBook(
          id: 'book-one',
          text: '第一本正文',
          fileName: '第一本.txt',
          customChunks: null,
        ),
        StoredLibraryBook(
          id: 'book-two',
          text: '第二本正文',
          fileName: '第二本.txt',
          customChunks: ['第二本', '正文'],
          source: BookStorageSource.network,
        ),
      ];
      await LocalAppStore.instance.saveLibrary(
        books: books,
        selectedBookId: 'book-two',
      );

      final library = await LocalAppStore.instance.loadLibrary();

      expect(library.books.map((book) => book.id), ['book-one', 'book-two']);
      expect(library.selectedBookId, 'book-two');
      expect(library.books.last.customChunks, const ['第二本', '正文']);
      expect(library.books.last.source, BookStorageSource.network);
    });

    test('不匹配书本标识的进度与清理不会影响活动会话', () async {
      await LocalAppStore.instance.saveSendingSession(
        bookId: 'book-one',
        chunks: const ['第一段', '第二段'],
        nextIndex: 0,
        modeIndex: 1,
        intervalMilliseconds: 1000,
        notificationBaseId: 88,
      );

      await LocalAppStore.instance.updateSendingProgress(
        1,
        expectedBookId: 'book-two',
      );
      expect((await LocalAppStore.instance.loadSendingSession())?.nextIndex, 0);

      await LocalAppStore.instance.clearActiveSendingSession(
        expectedBookId: 'book-two',
      );
      expect(
        (await LocalAppStore.instance.loadSendingSession())?.bookId,
        'book-one',
      );

      await LocalAppStore.instance.updateSendingProgress(
        1,
        expectedBookId: 'book-one',
      );
      expect((await LocalAppStore.instance.loadSendingSession())?.nextIndex, 1);
      await LocalAppStore.instance.clearActiveSendingSession(
        expectedBookId: 'book-one',
      );
      expect(await LocalAppStore.instance.loadSendingSession(), isNull);
    });

    test('完成后清除断点不会影响已保存书籍', () async {
      await LocalAppStore.instance.saveDocument(
        text: '正文',
        fileName: '书.txt',
        maxCharacters: 120,
        modeIndex: 0,
        intervalMilliseconds: 1000,
        customChunks: null,
        compactSegmentContent: false,
        removeEmojiFromSegments: false,
        richSegmentContent: false,
      );
      await LocalAppStore.instance.saveSendingSession(
        chunks: const ['保留'],
        nextIndex: 0,
        modeIndex: 0,
        intervalMilliseconds: 15000,
        notificationBaseId: 12,
      );
      await LocalAppStore.instance.clearSendingSession();

      expect(await LocalAppStore.instance.loadSendingSession(), isNull);
      expect((await LocalAppStore.instance.loadDocument()).text, '正文');
    });
  });
}
