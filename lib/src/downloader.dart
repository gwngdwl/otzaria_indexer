import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const latestSeforimReleaseApi =
    'https://api.github.com/repos/Otzaria/SeforimLibrary/releases/latest';

class DownloadAsset {
  final String name;
  final String downloadUrl;
  final String? releaseTag;

  const DownloadAsset({
    required this.name,
    required this.downloadUrl,
    this.releaseTag,
  });

  static DownloadAsset? fromReleaseJson(Map<String, dynamic> json) {
    final assets = json['assets'] as List<dynamic>? ?? [];
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      final name = asset['name'] as String? ?? '';
      final url = asset['browser_download_url'] as String? ?? '';
      if (name == 'seforim.db.zst' && url.isNotEmpty) {
        return DownloadAsset(
          name: name,
          downloadUrl: url,
          releaseTag: json['tag_name']?.toString(),
        );
      }
    }
    return null;
  }
}

/// Fetches the latest seforim.db.zst asset info from GitHub Releases.
Future<DownloadAsset> fetchLatestDbAsset({
  http.Client? client,
  String apiUrl = latestSeforimReleaseApi,
}) async {
  final c = client ?? http.Client();
  final response = await c.get(
    Uri.parse(apiUrl),
    headers: const {
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    },
  );

  if (response.statusCode != 200) {
    throw Exception('GitHub API error: ${response.statusCode}');
  }

  final json = jsonDecode(utf8.decode(response.bodyBytes));
  if (json is! Map<String, dynamic>) {
    throw Exception('Invalid GitHub release JSON');
  }

  final asset = DownloadAsset.fromReleaseJson(json);
  if (asset == null) {
    throw Exception('seforim.db.zst not found in latest release');
  }
  return asset;
}

/// Resolves HTTP redirects manually so that Range headers survive.
Future<String> resolveRedirect(String url, {http.Client? client}) async {
  final c = client ?? http.Client();
  var current = Uri.parse(url);
  for (var i = 0; i < 5; i++) {
    final request = http.Request('HEAD', current)..followRedirects = false;
    final response = await c.send(request);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      final location = response.headers['location'];
      if (location == null) break;
      current = current.resolve(location);
    } else {
      break;
    }
  }
  return current.toString();
}

/// Downloads [url] to [destPath] with resume support.
/// [onProgress] receives (downloaded, total) in bytes; total may be 0 if unknown.
Future<void> downloadWithResume(
  String url,
  String destPath, {
  http.Client? client,
  void Function(int downloaded, int total)? onProgress,
}) async {
  final c = client ?? http.Client();
  final tempFile = File(destPath);
  var alreadyDownloaded = await tempFile.exists() ? await tempFile.length() : 0;

  final resolvedUrl = await resolveRedirect(url, client: c);
  final request = http.Request('GET', Uri.parse(resolvedUrl));
  if (alreadyDownloaded > 0) {
    request.headers['Range'] = 'bytes=$alreadyDownloaded-';
  }

  final response = await c.send(request);

  if (response.statusCode == 200) {
    alreadyDownloaded = 0;
    if (await tempFile.exists()) await tempFile.delete();
  } else if (response.statusCode == 206) {
    final contentRange = response.headers['content-range'];
    if (contentRange != null) {
      final match = RegExp(r'bytes (\d+)-').firstMatch(contentRange);
      if (match != null) {
        final serverStart = int.tryParse(match.group(1)!) ?? 0;
        if (serverStart == 0 && alreadyDownloaded > 0) {
          alreadyDownloaded = 0;
          if (await tempFile.exists()) await tempFile.delete();
        }
      }
    }
  } else {
    throw Exception('HTTP ${response.statusCode} downloading $url');
  }

  final contentLength = response.contentLength ?? 0;
  final total = contentLength > 0 ? contentLength + alreadyDownloaded : 0;
  var downloaded = alreadyDownloaded;

  final sink = tempFile.openWrite(
    mode: alreadyDownloaded > 0 ? FileMode.append : FileMode.write,
  );
  try {
    await for (final chunk in response.stream) {
      sink.add(chunk);
      downloaded += chunk.length;
      onProgress?.call(downloaded, total);
    }
  } finally {
    await sink.close();
  }
}

/// Decompresses a .zst file to [outputPath].
Future<void> decompressZst(String zstPath, String outputPath) async {
  final result = await Process.run('zstd', [
    '-d',
    '--force',
    zstPath,
    '-o',
    outputPath,
  ], runInShell: true);
  if (result.exitCode != 0) {
    throw Exception(
      'zstd failed with exit ${result.exitCode}\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
}
