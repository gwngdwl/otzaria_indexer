/// Mirrors Otzaria's IndexingDocumentBuilder text-processing logic.
class PreparedDocument {
  final String reference;
  final String text;
  final int segment;
  final int ordinal;

  const PreparedDocument({
    required this.reference,
    required this.text,
    required this.segment,
    required this.ordinal,
  });
}

class TextBuilder {
  static final RegExp _htmlStripper = RegExp(r'<[^>]*>|&[^;]+;');
  static final RegExp _vowelsAndCantillation = RegExp(r'[\u0591-\u05C7]');

  /// Splits a text book (newline-separated HTML lines) into index documents.
  static List<PreparedDocument> buildTextBookDocuments(String text) {
    final lines = text.split('\n');
    final documents = <PreparedDocument>[];
    final referenceTrail = <String>[];
    var ordinal = 0;

    for (var i = 0; i < lines.length; i++) {
      final rawLine = lines[i];
      if (rawLine.startsWith('<h')) {
        updateReferenceTrail(referenceTrail, rawLine);
        final headerLine = removeVowels(stripHtml(rawLine));
        documents.add(
          PreparedDocument(
            reference: stripHtml(referenceTrail.join(', ')),
            text: headerLine,
            segment: i,
            ordinal: ordinal++,
          ),
        );
      } else {
        final line = removeVowels(stripHtml(rawLine));
        documents.add(
          PreparedDocument(
            reference: stripHtml(referenceTrail.join(', ')),
            text: line,
            segment: i,
            ordinal: ordinal++,
          ),
        );
      }
    }

    return documents;
  }

  static String stripHtml(String input) {
    final withSpaces = input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&thinsp;', ' ')
        .replaceAll('&ensp;', ' ')
        .replaceAll('&emsp;', ' ');
    return withSpaces.replaceAll(_htmlStripper, '').trim();
  }

  static String removeVowels(String input) {
    return input
        .replaceAll('־', ' ')
        .replaceAll('׀', ' ')
        .replaceAll('|', ' ')
        .replaceAll(_vowelsAndCantillation, '');
  }

  static void updateReferenceTrail(List<String> trail, String line) {
    if (line.length < 4) {
      trail.add(line);
      return;
    }

    final prefix = line.substring(0, 4);
    final existingIndex = trail.indexWhere(
      (e) => e.length >= 4 && e.substring(0, 4) == prefix,
    );
    if (existingIndex != -1) {
      trail.removeRange(existingIndex, trail.length);
    }
    trail.add(line);
  }
}
