class BookMetadata {
  const BookMetadata({required this.title, required this.introduction});

  final String title;
  final String introduction;
}

class BookMetadataResolver {
  BookMetadataResolver._();

  /// 优先依据导入文件名解析书名；文件名不存在时回退到通用书名。
  static BookMetadata resolve({
    required String? fileName,
    required String text,
  }) {
    final title = _titleFromFileName(fileName);
    return BookMetadata(
      title: title,
      introduction: _introductionFromText(text),
    );
  }

  static String _titleFromFileName(String? fileName) {
    if (fileName == null || fileName.trim().isEmpty) {
      return '未命名小说';
    }
    var value = fileName.trim().replaceFirst(RegExp(r'\.[Tt][Xx][Tt]$'), '');
    value = value.replaceAll('_', ' ').replaceAll('-', ' ');
    value = value.replaceAll(
      RegExp(r'\[(?:完结|全本|精校|校对|TXT)\]', caseSensitive: false),
      '',
    );
    value = value.replaceAll(
      RegExp(r'\((?:完结|全本|精校|校对|TXT)\)', caseSensitive: false),
      '',
    );
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return value.isEmpty ? '未命名小说' : value;
  }

  static String _introductionFromText(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return '导入小说后，将在这里自动生成正文简介。';
    }
    final characters = normalized.runes.toList();
    const limit = 110;
    if (characters.length <= limit) {
      return normalized;
    }
    return '${String.fromCharCodes(characters.take(limit))}…';
  }
}
