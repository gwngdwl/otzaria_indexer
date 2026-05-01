import 'db_reader.dart';

/// Builds the Tantivy facet path for a book, matching Otzaria's BookFacet logic.
///
/// Format: /category1/category2/.../bookKey
class FacetBuilder {
  final Map<int, CategoryRow> _categories;

  FacetBuilder(this._categories);

  /// Builds the full facet path for a book.
  String buildFacetPath(BookRow book, String topics) {
    final categoryPath = _buildCategoryPath(book.categoryId);
    final bookKey = _bookKey(book);
    return categoryPath.isEmpty ? '/$bookKey' : '$categoryPath/$bookKey';
  }

  /// Builds /cat1/cat2/... from category hierarchy
  String _buildCategoryPath(int categoryId) {
    final parts = <String>[];
    int? currentId = categoryId;

    while (currentId != null) {
      final cat = _categories[currentId];
      if (cat == null) break;
      parts.insert(0, cat.title);
      currentId = cat.parentId;
    }

    if (parts.isEmpty) return '';
    return '/${parts.join('/')}';
  }

  /// Unique book key — matches IndexingRepository.catalogueOrderKey
  String _bookKey(BookRow book) {
    if (book.externalLibraryId != null && book.externalLibraryId!.isNotEmpty) {
      return 'ext:${book.externalLibraryId}';
    }
    return 'id:${book.id}';
  }
}
