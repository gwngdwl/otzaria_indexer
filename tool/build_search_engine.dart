import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final packageRoot = await _findPackageRoot('search_engine');
  final manifestPath = p.join(packageRoot, 'rust', 'Cargo.toml');
  if (!File(manifestPath).existsSync()) {
    throw StateError('Cargo manifest not found: $manifestPath');
  }

  if (args.contains('--check')) {
    stdout.writeln(manifestPath);
    return;
  }

  stdout.writeln('Building native search_engine library...');
  stdout.writeln('Package root: $packageRoot');

  final result = await Process.run(
    'cargo',
    ['build', '--manifest-path', manifestPath, '--release'],
    runInShell: true,
    workingDirectory: p.join(packageRoot, 'rust'),
  );

  stdout.write(result.stdout);
  stderr.write(result.stderr);

  if (result.exitCode != 0) {
    throw StateError('cargo build failed with exit ${result.exitCode}');
  }
}

Future<String> _findPackageRoot(String packageName) async {
  final configFile = File(p.join('.dart_tool', 'package_config.json'));
  if (!await configFile.exists()) {
    throw StateError('Run flutter pub get before building native packages.');
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
