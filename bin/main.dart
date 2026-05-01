import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:search_engine/search_engine.dart';
import 'package:otzaria_indexer/src/downloader.dart';
import 'package:otzaria_indexer/src/db_reader.dart';
import 'package:otzaria_indexer/src/indexer.dart';
import 'package:otzaria_indexer/src/progress_tracker.dart';

void main(List<String> arguments) async {
  await RustLib.init();
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage')
    ..addOption('db', help: 'Path to an existing seforim.db (skips download)')
    ..addOption(
      'output',
      abbr: 'o',
      defaultsTo: p.join(Directory.current.path, 'otzaria_index'),
      help: 'Output directory for the Tantivy index',
    )
    ..addFlag(
      'fresh',
      negatable: false,
      help: 'Ignore existing progress and reindex from scratch',
    )
    ..addFlag(
      'skip-download',
      negatable: false,
      help: 'Skip downloading seforim.db (requires --db or a local db file)',
    );

  final args = parser.parse(arguments);

  if (args['help'] as bool) {
    _printUsage(parser);
    return;
  }

  final outputDir = args['output'] as String;
  final fresh = args['fresh'] as bool;
  final skipDownload = args['skip-download'] as bool;

  String dbPath;

  if (args['db'] != null) {
    dbPath = args['db'] as String;
    if (!File(dbPath).existsSync()) {
      stderr.writeln('Error: database not found at $dbPath');
      exitCode = 1;
      return;
    }
  } else if (!skipDownload) {
    final tempDir = Directory.systemTemp.path;
    final zstPath = p.join(tempDir, 'otzaria_seforim.db.zst');
    dbPath = p.join(tempDir, 'otzaria_seforim.db');

    await _downloadDb(zstPath: zstPath, dbPath: dbPath);
  } else {
    // --skip-download without --db: look for seforim.db in cwd
    dbPath = p.join(Directory.current.path, 'seforim.db');
    if (!File(dbPath).existsSync()) {
      stderr.writeln(
        'Error: seforim.db not found in current directory. '
        'Use --db to specify a path or remove --skip-download to download it.',
      );
      exitCode = 1;
      return;
    }
  }

  await _buildIndex(dbPath: dbPath, outputDir: outputDir, fresh: fresh);
}

Future<void> _downloadDb({
  required String zstPath,
  required String dbPath,
}) async {
  print('Fetching latest release info from GitHub...');
  final asset = await fetchLatestDbAsset();
  print('Downloading ${asset.name}...');

  var lastPrint = DateTime.fromMillisecondsSinceEpoch(0);

  await downloadWithResume(
    asset.downloadUrl,
    zstPath,
    onProgress: (downloaded, total) {
      final now = DateTime.now();
      if (now.difference(lastPrint).inSeconds < 2) return;
      lastPrint = now;
      if (total > 0) {
        final pct = (downloaded / total * 100).toStringAsFixed(1);
        final mb = (downloaded / 1024 / 1024).toStringAsFixed(1);
        final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
        stdout.write('\r  $mb / $totalMb MB ($pct%)   ');
      } else {
        final mb = (downloaded / 1024 / 1024).toStringAsFixed(1);
        stdout.write('\r  $mb MB downloaded   ');
      }
    },
  );
  stdout.writeln();
  print('Download complete. Decompressing...');
  await decompressZst(zstPath, dbPath);
  print('Decompression complete: $dbPath');
  // Clean up the compressed file
  await File(zstPath).delete().catchError((_) => File(zstPath));
}

Future<void> _buildIndex({
  required String dbPath,
  required String outputDir,
  required bool fresh,
}) async {
  final indexDir = Directory(outputDir);

  if (fresh) {
    print('--fresh: clearing existing index and progress...');
    if (indexDir.existsSync()) indexDir.deleteSync(recursive: true);
    final lockDir = Directory(p.join(p.dirname(outputDir), 'tantivy.lock'));
    if (lockDir.existsSync()) lockDir.deleteSync(recursive: true);
  }

  indexDir.createSync(recursive: true);

  final tracker = await ProgressTracker.load(outputDir);

  print('Opening database: $dbPath');
  final db = DbReader.open(dbPath);

  print('Opening search index: $outputDir');
  final engine = SearchEngine(path: outputDir);

  final indexer = Indexer(db: db, engine: engine);

  print('Starting indexing...');
  final stopwatch = Stopwatch()..start();
  var lastSave = DateTime.now();

  final stats = await indexer.run(
    alreadyIndexed: tracker.done,
    onProgress: (processed, total, title) {
      final pct = total > 0
          ? (processed / total * 100).toStringAsFixed(1)
          : '?';
      stdout.write('\r  [$processed/$total] $pct% — $title   ');

      final now = DateTime.now();
      if (now.difference(lastSave).inSeconds >= 30) {
        lastSave = now;
        tracker.save(); // fire-and-forget, best-effort
      }
    },
    onBookDone: (key) {
      tracker.markDone(key);
    },
  );

  stdout.writeln();
  await tracker.save(catalogueOrderSignature: stats.catalogueOrderSignature);
  await tracker.close();
  db.close();

  stopwatch.stop();
  final elapsed = stopwatch.elapsed;
  print('');
  print('Indexing complete in ${_formatDuration(elapsed)}');
  print('  Books indexed:   ${stats.booksIndexed}');
  print('  Books skipped:   ${stats.booksSkipped}');
  print('  Books errored:   ${stats.booksErrored}');
  print('  Total documents: ${stats.totalDocuments}');
  print('  Index written to: $outputDir');

  final processed = stats.booksIndexed + stats.booksSkipped + stats.booksErrored;
  if (processed < stats.totalBooks) {
    stderr.writeln(
      'ERROR: only $processed/${stats.totalBooks} books processed — index is incomplete',
    );
    exitCode = 1;
    return;
  }
  if (stats.booksErrored > 0) {
    stderr.writeln('WARNING: ${stats.booksErrored} books failed with errors');
  }
}

String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return '${h}h ${m}m ${s}s';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

void _printUsage(ArgParser parser) {
  print(
    'otzaria_indexer — builds a Tantivy search index for the Otzaria library',
  );
  print('');
  print('Usage: dart run bin/main.dart [options]');
  print('');
  print(parser.usage);
  print('');
  print('Examples:');
  print('  # Download latest DB and build index in ./otzaria_index');
  print('  dart run bin/main.dart');
  print('');
  print('  # Use an existing DB, write index to /data/index');
  print(
    '  dart run bin/main.dart --db /path/to/seforim.db --output /data/index',
  );
  print('');
  print('  # Rebuild from scratch');
  print('  dart run bin/main.dart --fresh');
}
