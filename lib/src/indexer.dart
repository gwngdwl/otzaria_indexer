import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:search_engine/search_engine.dart';
import 'db_reader.dart';
import 'facet_builder.dart';
import 'text_builder.dart';

class IndexStats {
  int booksIndexed = 0;
  int booksSkipped = 0;
  int booksErrored = 0;
  int totalDocuments = 0;
  int totalBooks = 0;
  String catalogueOrderSignature = '';
}

/// Builds a Tantivy search index from seforim.db.
///
/// Call [run] to perform a full index build. Progress is reported via [onProgress].
class Indexer {
  final DbReader _db;
  final SearchEngine _engine;

  Indexer({required DbReader db, required SearchEngine engine})
    : _db = db,
      _engine = engine;

  /// Indexes all books. Returns statistics when complete.
  Future<IndexStats> run({
    void Function(int processed, int total, String bookTitle)? onProgress,
    Set<String>? alreadyIndexed,
    void Function(String key)? onBookDone,
  }) async {
    final stats = IndexStats();
    final categories = _db.getAllCategories();
    final facetBuilder = FacetBuilder(categories);
    final allTopics = _db.getAllBookTopics();
    final books = _db.getAllBooks();
    final total = books.length;
    stats.totalBooks = total;

    // Compute SHA1 of the catalogue order — matches IndexingRepository.buildCatalogueOrderSignature
    final orderedKeys = books.map(_catalogueKey).toList();
    stats.catalogueOrderSignature =
        sha1.convert(utf8.encode(orderedKeys.join('\n'))).toString();

    for (var i = 0; i < books.length; i++) {
      final book = books[i];
      final key = _catalogueKey(book);

      onProgress?.call(i, total, book.title);

      if (alreadyIndexed != null && alreadyIndexed.contains(key)) {
        stats.booksSkipped++;
        continue;
      }

      // Skip PDF and external books — only text books are in the DB lines table
      final fileType = (book.fileType ?? 'txt').toLowerCase();
      if (fileType == 'pdf' || book.isFileBacked) {
        stats.booksSkipped++;
        continue;
      }

      try {
        final text = _db.getBookText(book.id);
        if (text == null || text.isEmpty) {
          stats.booksSkipped++;
          continue;
        }

        final topics = allTopics[book.id] ?? '';
        final facetPath = facetBuilder.buildFacetPath(book, topics);
        final documents = TextBuilder.buildTextBookDocuments(text);
        final catalogueOrder = i;

        final docs = [
          for (final doc in documents)
            DocumentInput(
              id: _buildDocumentId(catalogueOrder, doc.ordinal),
              title: book.title,
              reference: doc.reference,
              topics: facetPath,
              text: doc.text,
              segment: BigInt.from(doc.segment),
              isPdf: false,
              filePath: 'id:${book.id}',
            ),
        ];

        await _engine.upsertDocumentsBatch(docs: docs);
        stats.booksIndexed++;
        stats.totalDocuments += documents.length;
        onBookDone?.call(key);
      } catch (e) {
        stats.booksErrored++;
        print('ERROR indexing book ${book.id} "${book.title}": $e');
      }

      // Commit every 25 books to persist progress
      if ((i + 1) % 25 == 0) {
        await _engine.commit();
      }
    }

    await _engine.commit();
    await _engine.optimize();

    return stats;
  }

  /// Same encoding as IndexingRepository.buildCatalogueDocumentId
  static BigInt buildDocumentId(int catalogueOrder, int ordinal) {
    return (BigInt.from(catalogueOrder + 1) << 32) + BigInt.from(ordinal + 1);
  }

  static BigInt _buildDocumentId(int catalogueOrder, int ordinal) =>
      buildDocumentId(catalogueOrder, ordinal);

  static String _catalogueKey(BookRow book) {
    if (book.externalLibraryId != null && book.externalLibraryId!.isNotEmpty) {
      return 'ext:${book.externalLibraryId}';
    }
    return 'id:${book.id}';
  }
}

extension on BookRow {
  bool get isFileBacked {
    final path = filePath?.trim();
    if (path == null || path.isEmpty) return false;
    final type = (fileType ?? 'txt').toLowerCase();
    return type != 'link' && type != 'url';
  }
}
