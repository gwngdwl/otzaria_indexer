import 'dart:convert';

import 'package:otzaria_indexer/otzaria_indexer.dart';
import 'package:test/test.dart';

void main() {
  test('parses latest database asset from GitHub release JSON', () {
    final release =
        jsonDecode('''
      {
        "tag_name": "v1",
        "assets": [
          {
            "name": "other-file.txt",
            "browser_download_url": "https://example.invalid/other"
          },
          {
            "name": "seforim.db.zst",
            "browser_download_url": "https://example.invalid/seforim.db.zst"
          }
        ]
      }
    ''')
            as Map<String, dynamic>;

    final asset = DownloadAsset.fromReleaseJson(release);

    expect(asset, isNotNull);
    expect(asset!.name, 'seforim.db.zst');
    expect(asset.releaseTag, 'v1');
    expect(asset.downloadUrl, 'https://example.invalid/seforim.db.zst');
  });

  test('normalizes text like Otzaria indexing', () {
    final normalized = TextBuilder.removeVowels(
      TextBuilder.stripHtml('<h1>בְּרֵאשִׁית&nbsp;בָּרָא</h1>'),
    );

    expect(normalized, 'בראשית ברא');
  });

  test('replaces existing heading level in reference trail', () {
    final trail = <String>[];

    TextBuilder.updateReferenceTrail(trail, '<h1>ספר</h1>');
    TextBuilder.updateReferenceTrail(trail, '<h2>פרק א</h2>');
    TextBuilder.updateReferenceTrail(trail, '<h2>פרק ב</h2>');

    expect(trail, ['<h1>ספר</h1>', '<h2>פרק ב</h2>']);
  });

  test('builds catalogue document id', () {
    expect(Indexer.buildDocumentId(0, 0), (BigInt.one << 32) + BigInt.one);
  });
}
