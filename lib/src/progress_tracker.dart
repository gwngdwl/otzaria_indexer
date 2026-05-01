import 'dart:io';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

/// Mirrors TantivyDataProvider's Hive-based state persistence exactly so that
/// the index produced by this tool is immediately usable by Otzaria without
/// triggering a full re-index.
///
/// Hive box: "books_indexed"  (same name as the app)
/// Location: `<indexDir>/../tantivy.lock/`.
///
/// Keys written:
///   'key-books-done'               — `List<String>` of indexed book keys
///   'key-index-state-version'      — int, must equal 5
///   'key-catalogue-order-signature'— String SHA1 of catalogue order
class ProgressTracker {
  static const String _booksDoneKey = 'key-books-done';
  static const String _indexStateVersionKey = 'key-index-state-version';
  static const String _catalogueOrderSignatureKey =
      'key-catalogue-order-signature';
  static const int _indexStateVersion = 5;

  final String _lockDir;
  final Set<String> _done;
  Box? _box;

  ProgressTracker._(this._lockDir, this._done);

  /// Opens (or creates) the Hive box in the correct tantivy.lock directory.
  static Future<ProgressTracker> load(String indexDir) async {
    final lockDir = p.join(p.dirname(indexDir), 'tantivy.lock');
    await Directory(lockDir).create(recursive: true);

    Hive.init(lockDir);
    final box = await Hive.openBox<dynamic>('books_indexed', path: lockDir);

    final dynamic raw = box.get(_booksDoneKey, defaultValue: <dynamic>[]);
    final done = raw is List
        ? raw.map<String>((e) => e.toString()).toSet()
        : <String>{};

    final tracker = ProgressTracker._(lockDir, done);
    tracker._box = box;
    return tracker;
  }

  Set<String> get done => Set.unmodifiable(_done);

  void markDone(String key) => _done.add(key);

  /// Writes all state to Hive, including the index-state-version and
  /// catalogue-order-signature so Otzaria won't invalidate the index on startup.
  Future<void> save({String catalogueOrderSignature = ''}) async {
    final box = _box ?? await _reopenBox();
    await box.put(_booksDoneKey, _done.toList());
    await box.put(_indexStateVersionKey, _indexStateVersion);
    await box.put(_catalogueOrderSignatureKey, catalogueOrderSignature);
  }

  Future<void> clear() async {
    _done.clear();
    final box = _box ?? await _reopenBox();
    await box.delete(_booksDoneKey);
    await box.delete(_indexStateVersionKey);
    await box.delete(_catalogueOrderSignatureKey);
  }

  Future<void> close() async {
    await _box?.close();
    _box = null;
  }

  Future<Box> _reopenBox() async {
    Hive.init(_lockDir);
    final box = await Hive.openBox<dynamic>('books_indexed', path: _lockDir);
    _box = box;
    return box;
  }
}
