# Otzaria Indexer

Builds a downloadable Tantivy search index for Otzaria from the latest
`seforim.db` release used by the app.

The index format and document layout follow Otzaria's current use of
`otzaria_search_engine`:

- one search document per text line
- Hebrew vowels and cantillation removed before indexing
- HTML tags stripped before indexing
- document IDs encode catalogue order and line ordinal
- facets use the same category/book-key shape as Otzaria

## Local build

Requirements:

- Flutter
- Rust/Cargo
- `zstd` available on `PATH`

```bash
flutter pub get
dart run tool/build_search_engine.dart
dart run bin/otzaria_indexer.dart --force
```

By default this downloads the latest `seforim.db.zst` from
`Otzaria/SeforimLibrary`, extracts it to `build/library/seforim.db`, and writes
the search index to `build/index`.

To build from an existing database:

```bash
dart run bin/otzaria_indexer.dart --db /path/to/seforim.db --index-dir build/index --force
```

## GitHub Actions

`.github/workflows/build_index.yml` builds the native search engine, downloads
the latest database, creates the index, and uploads:

- `otzaria-search-index.tar.zst`
- `manifest.json`

Run the workflow manually with `publish_release=true` to publish a GitHub
release containing the generated index archive.
