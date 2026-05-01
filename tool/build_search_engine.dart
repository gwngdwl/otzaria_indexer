import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final packageRoot = await _findPackageRoot('search_engine');
  final manifestDir = p.join(packageRoot, 'rust');
  final manifestPath = p.join(manifestDir, 'Cargo.toml');
  if (!File(manifestPath).existsSync()) {
    throw StateError('Cargo manifest not found: $manifestPath');
  }

  if (args.contains('--check')) {
    stdout.writeln(manifestPath);
    return;
  }

  final outputDir = p.join(manifestDir, 'target', 'release');
  Directory(outputDir).createSync(recursive: true);

  stdout.writeln('Building/downloading native search_engine library...');
  stdout.writeln('Package root: $packageRoot');

  // Try downloading the precompiled binary first (fast), fall back to cargo build.
  final downloaded = await _tryDownloadPrecompiled(manifestDir, outputDir);
  if (downloaded) {
    stdout.writeln('Precompiled binary downloaded successfully.');
    return;
  }

  stdout.writeln('Precompiled binary not available, building with cargo...');
  final result = await Process.run(
    'cargo',
    ['build', '--manifest-path', manifestPath, '--release'],
    runInShell: true,
    workingDirectory: manifestDir,
  );

  stdout.write(result.stdout);
  stderr.write(result.stderr);

  if (result.exitCode != 0) {
    throw StateError('cargo build failed with exit ${result.exitCode}');
  }

  stdout.writeln('Native library ready at: $outputDir');
}

/// Tries to download the precompiled binary from GitHub.
/// Returns true if successful, false if not available.
Future<bool> _tryDownloadPrecompiled(
    String manifestDir, String outputDir) async {
  // Read cargokit.yaml to get the URL prefix.
  final cargokitYaml = File(p.join(manifestDir, 'cargokit.yaml'));
  if (!cargokitYaml.existsSync()) return false;
  final urlPrefix = _extractYamlValue(cargokitYaml.readAsStringSync(), 'url_prefix');
  if (urlPrefix == null) return false;

  // Compute the crate hash (mirrors cargokit CrateHash.compute).
  final crateHash = _computeCrateHash(manifestDir);
  stdout.writeln('Crate hash: $crateHash');

  final rustTarget = _rustTarget();
  final libName = _nativeLibName('search_engine');
  final remoteFileName = '${rustTarget}_$libName';
  final url = '$urlPrefix${crateHash}/$remoteFileName';

  stdout.writeln('Attempting download: $url');

  try {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 404) {
      stdout.writeln('Precompiled binary not found for hash $crateHash.');
      return false;
    }
    if (response.statusCode != 200) {
      stderr.writeln('Download failed with HTTP ${response.statusCode}');
      return false;
    }
    final outPath = p.join(outputDir, libName);
    File(outPath).writeAsBytesSync(response.bodyBytes);
    stdout.writeln('Written: $outPath');
    return true;
  } catch (e) {
    stderr.writeln('Download error: $e');
    return false;
  }
}

/// Computes the crate hash exactly as cargokit does:
/// SHA-256 over all .rs files in src/ + Cargo.toml + Cargo.lock + build.rs +
/// cargokit.yaml, each file hashed line-by-line, truncated to 128 bits, hex.
String _computeCrateHash(String manifestDir) {
  final src = Directory(p.join(manifestDir, 'src'));
  final files = src
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final name in ['Cargo.toml', 'Cargo.lock', 'build.rs', 'cargokit.yaml']) {
    final f = File(p.join(manifestDir, name));
    if (f.existsSync()) files.add(f);
  }

  final allBytes = <int>[];
  final splitter = const LineSplitter();
  for (final file in files) {
    for (final line in splitter.convert(file.readAsStringSync())) {
      allBytes.addAll(utf8.encode(line));
    }
  }

  final bytes = sha256.convert(allBytes).bytes.sublist(0, 16);
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String? _extractYamlValue(String yaml, String key) {
  final pattern = RegExp('^\\s*${RegExp.escape(key)}:\\s*(.+)', multiLine: true);
  return pattern.firstMatch(yaml)?.group(1)?.trim();
}

String _rustTarget() {
  if (Platform.isLinux) return 'x86_64-unknown-linux-gnu';
  if (Platform.isWindows) return 'x86_64-pc-windows-msvc';
  if (Platform.isMacOS) return 'x86_64-apple-darwin';
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

String _nativeLibName(String stem) {
  if (Platform.isLinux) return 'lib$stem.so';
  if (Platform.isWindows) return '$stem.dll';
  if (Platform.isMacOS) return 'lib$stem.dylib';
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

Future<String> _findPackageRoot(String packageName) async {
  final configFile = File(p.join('.dart_tool', 'package_config.json'));
  if (!await configFile.exists()) {
    throw StateError('Run dart pub get before building native packages.');
  }

  final configUri = configFile.absolute.uri;
  final decoded = jsonDecode(await configFile.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw StateError('Invalid package_config.json');
  }

  final packages = decoded['packages'];
  if (packages is! List) {
    throw StateError('Invalid package_config.json: packages missing');
  }

  for (final rawPackage in packages) {
    if (rawPackage is! Map<String, dynamic>) continue;
    if (rawPackage['name'] != packageName) continue;

    final rootUriText = rawPackage['rootUri']?.toString();
    if (rootUriText == null || rootUriText.isEmpty) {
      throw StateError('$packageName has no rootUri in package_config.json');
    }

    final rootUri = configUri.resolve(rootUriText);
    return p.fromUri(rootUri);
  }

  throw StateError('Package $packageName not found in package_config.json');
}
