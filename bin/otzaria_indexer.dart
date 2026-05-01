import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:otzaria_indexer/otzaria_indexer.dart';
import 'package:path/path.dart' as p;
import 'package:search_engine/search_engine.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Print usage.')
    ..addOption(
      'db',
      help: 'Existing seforim.db path. Skips download and decompression.',
    )
    ..addOption(
      'archive',
      help: 'Existing seforim.db.zst path. Skips download.',
    )
    ..addOption(
      'library-dir',
      defaultsTo: p.join('build', 'library'),
      help: 'Directory used for downloaded/extracted database files.',
    )
    ..addOption(
      'index-dir',
      defaultsTo: p.join('build', 'index'),
      help: 'Output directory for the Tantivy index.',
    )
    ..addOption(
      'release-api',
      defaultsTo: latestSeforimReleaseApi,
      help: 'GitHub API URL for the latest SeforimLibrary release.',
    )
    ..addFlag(
      'force',
      negatable: false,
      help: 'Delete an existing non-empty index directory before building.',
    );

  final args = parser.parse(arguments);
  if (args.flag('help')) {
    _printUsage(parser);
    return;
  }

  final dbPath = args.option('db');
  final archivePath = args.option('archive');
  if (dbPath != null && archivePath != null) {
    stderr.writeln('Use either --db or --archive, not both.');
    exitCode = 64;
    return;
  }

  try {
    final resolvedDbPath = await _resolveDatabase(
      dbPath: dbPath,
      archivePath: archivePath,
      libraryDir: args.option('library-dir')!,
      releaseApi: args.option('release-api')!,
    );
    await _buildIndex(
      dbPath: resolvedDbPath,
      indexDir: args.option('index-dir')!,
      force: args.flag('force'),
    );
  } catch (error, stackTrace) {
    stderr.writeln('Index build failed: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

Future<String> _resolveDatabase({
  required String? dbPath,
  required String? archivePath,
  required String libraryDir,
  required String releaseApi,
}) async {
  if (dbPath != null) {
    if (!File(dbPath).existsSync()) {
      throw StateError('Database file does not exist: $dbPath');
    }
    return dbPath;
  }

  final library = Directory(libraryDir);
  if (!library.existsSync()) library.createSync(recursive: true);
  final outputDbPath = p.join(library.path, 'seforim.db');

  if (archivePath != null) {
    await decompressZst(archivePath, outputDbPath);
    return outputDbPath;
  }

  stdout.writeln('Fetching latest release info from GitHub...');
  final asset = await fetchLatestDbAsset(apiUrl: releaseApi);
  final zstPath = p.join(library.path, asset.name);

  stdout.writeln('Downloading ${asset.name}...');
  var lastPrint = DateTime.fromMillisecondsSinceEpoch(0);
  await downloadWithResume(
    asset.downloadUrl,
    zstPath,
    onProgress: (downloaded, total) {
      final now = DateTime.now();
      if (now.difference(lastPrint).inSeconds < 2) return;
      lastPrint = now;
      final mb = (downloaded / 1024 / 1024).toStringAsFixed(1);
      if (total > 0) {
        final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
        final pct = (downloaded / total * 100).toStringAsFixed(1);
        stdout.write('\r  $mb / $totalMb MB ($pct%)   ');
      } else {
        stdout.write('\r  $mb MB downloaded   ');
      }
    },
  );
  stdout.writeln();

  stdout.writeln('Decompressing...');
  await decompressZst(zstPath, outputDbPath);
  return outputDbPath;
}

Future<void> _buildIndex({
  required String dbPath,
  required String indexDir,
  required bool force,
}) async {
  final dir = Directory(indexDir);
  if (dir.existsSync()) {
    final isEmpty = dir.listSync().isEmpty;
    if (!isEmpty && !force) {
      throw StateError('Index directory is not empty. Pass --force: $indexDir');
    }
    if (!isEmpty) {
      dir.deleteSync(recursive: true);
    }
  }
  dir.createSync(recursive: true);

  await RustLib.init();
  final db = DbReader.open(dbPath);
  final engine = SearchEngine(path: indexDir);
  final tracker = await ProgressTracker.load(indexDir);
  await tracker.clear();

  try {
    final indexer = Indexer(db: db, engine: engine);
    stdout.writeln('Starting indexing...');
    final stopwatch = Stopwatch()..start();
    final stats = await indexer.run(
      onProgress: (processed, total, title) {
        final pct = total > 0
            ? (processed / total * 100).toStringAsFixed(1)
            : '?';
        stdout.write('\r  [$processed/$total] $pct% - $title   ');
      },
      onBookDone: tracker.markDone,
    );
    stdout.writeln();
    stopwatch.stop();
    await tracker.save(catalogueOrderSignature: stats.catalogueOrderSignature);

    final manifestPath = p.join(p.dirname(indexDir), 'manifest.json');
    final manifest = {
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'sourceDatabase': p.normalize(dbPath),
      'indexDir': p.normalize(indexDir),
      'booksIndexed': stats.booksIndexed,
      'booksSkipped': stats.booksSkipped,
      'booksErrored': stats.booksErrored,
      'documentsIndexed': stats.totalDocuments,
      'indexStateVersion': 5,
    };
    await File(
      manifestPath,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));

    stdout.writeln('Index build completed in ${stopwatch.elapsed}.');
    stdout.writeln('Index: $indexDir');
    stdout.writeln('Manifest: $manifestPath');
    stdout.writeln('Documents indexed: ${stats.totalDocuments}');
  } finally {
    await tracker.close();
    db.close();
    RustLib.dispose();
  }
}

void _printUsage(ArgParser parser) {
  stdout.writeln('Build an Otzaria search index from seforim.db.');
  stdout.writeln('');
  stdout.writeln('Usage: dart run bin/otzaria_indexer.dart [options]');
  stdout.writeln('');
  stdout.writeln(parser.usage);
}
