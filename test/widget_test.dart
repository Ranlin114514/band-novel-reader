import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelnotifier/book_metadata.dart';
import 'package:novelnotifier/local_app_store.dart';
import 'package:novelnotifier/main.dart';
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
      expect(document.maxCharacters, 180);
      expect(document.customChunks, const ['测试', '正文']);
      expect(session?.nextIndex, 1);
      expect(session?.canResume, isTrue);
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
    });

    test('完成后清除断点不会影响已保存书籍', () async {
      await LocalAppStore.instance.saveDocument(
        text: '保留的书籍',
        fileName: '保留.txt',
        maxCharacters: 120,
        modeIndex: 0,
        intervalMilliseconds: 15000,
        customChunks: null,
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
      expect((await LocalAppStore.instance.loadDocument()).text, '保留的书籍');
    });
  });
}
