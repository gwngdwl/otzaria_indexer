import 'package:sqlite3/sqlite3.dart';

/// A single book row from seforim.db
class BookRow {
  final int id;
  final int categoryId;
  final String title;
  final String? fileType;
  final String? filePath;
  final String? externalLibraryId;
  final int orderIndex;
  final int totalLines;

  const BookRow({
    required this.id,
    required this.categoryId,
    required this.title,
    this.fileType,
    this.filePath,
    this.externalLibraryId,
    required this.orderIndex,
    required this.totalLines,
  });
}

/// A single category row from seforim.db
class CategoryRow {
  final int id;
  final int? parentId;
  final String title;

  const CategoryRow({required this.id, this.parentId, required this.title});
}

class DbReader {
  final Database _db;

  DbReader(this._db) {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA synchronous=NORMAL');
    _db.execute('PRAGMA cache_size=50000');
    _db.execute('PRAGMA temp_store=MEMORY');
    _db.execute('PRAGMA mmap_size=268435456');
  }

  factory DbReader.open(String path) {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    return DbReader(db);
  }

  void close() => _db.dispose();

  bool _columnExists(String table, String column) {
    final rows = _db.select('PRAGMA table_info($table)');
    return rows.any((r) => r['name'] as String == column);
  }

  List<BookRow> getAllBooks() {
    final hasExternalLibraryId = _columnExists('book', 'externalLibraryId');
    final extCol = hasExternalLibraryId ? 'externalLibraryId,' : 'NULL AS externalLibraryId,';
    return _db
        .select('''
      SELECT id, categoryId, title, fileType, filePath,
             $extCol COALESCE(orderIndex, 999) AS orderIndex,
             COALESCE(totalLines, 0) AS totalLines
      FROM book
      WHERE COALESCE(fileType, 'txt') NOT IN ('link', 'url')
      ORDER BY orderIndex, title
    ''')
        .map(
          (row) => BookRow(
            id: row['id'] as int,
            categoryId: row['categoryId'] as int,
            title: row['title'] as String,
            fileType: row['fileType'] as String?,
            filePath: row['filePath'] as String?,
            externalLibraryId: row['externalLibraryId'] as String?,
            orderIndex: row['orderIndex'] as int,
            totalLines: row['totalLines'] as int,
          ),
        )
        .toList();
  }

  Map<int, CategoryRow> getAllCategories() {
    final rows = _db.select('SELECT id, parentId, title FROM category');
    return {
      for (final row in rows)
        row['id'] as int: CategoryRow(
          id: row['id'] as int,
          parentId: row['parentId'] as int?,
          title: row['title'] as String,
        ),
    };
  }

  /// Returns the topics string for a book (joined topic names)
  String getBookTopics(int bookId) {
    final rows = _db.select(
      '''
      SELECT t.name FROM topic t
      JOIN book_topic bt ON bt.topicId = t.id
      WHERE bt.bookId = ?
      ORDER BY bt.rowid
    ''',
      [bookId],
    );
    return rows.map((r) => r['name'] as String).join(', ');
  }

  /// Returns the full text of a book as newline-separated lines
  String? getBookText(int bookId) {
    final rows = _db.select(
      'SELECT content FROM line WHERE bookId = ? ORDER BY lineIndex',
      [bookId],
    );
    if (rows.isEmpty) return null;
    return rows.map((r) => r['content'] as String? ?? '').join('\n');
  }

  /// Returns a map of bookId -> topics string for all books in one query
  Map<int, String> getAllBookTopics() {
    final rows = _db.select('''
      SELECT bt.bookId, GROUP_CONCAT(t.name, ', ') AS topics
      FROM book_topic bt
      JOIN topic t ON t.id = bt.topicId
      GROUP BY bt.bookId
    ''');
    return {
      for (final row in rows)
        row['bookId'] as int: row['topics'] as String? ?? '',
    };
  }
}
