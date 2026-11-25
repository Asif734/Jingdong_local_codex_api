/// Classification applies only after the caller has established one physical
/// text bubble. It must never be used to discover or merge customer messages.
enum OcrTextChange { identical, equivalent, material }

class OcrTextRefinement {
  const OcrTextRefinement._();

  /// A later viewport can show only a continuous remainder of this text.
  /// This is evidence loss, not a claim that the two questions mean the same.
  /// A caller with exact same-frame correction proof must not use this guard.
  static bool isStrictVisibleFragment(String previous, String observed) {
    final before = _presentation(previous);
    final after = _presentation(observed);
    return after.isNotEmpty &&
        after.length < before.length &&
        before.contains(after);
  }

  static bool isViewportFragment(String previous, String observed) {
    if (isStrictVisibleFragment(previous, observed)) return true;
    final before = _presentation(previous);
    final after = _presentation(observed);
    // A line assembled at the viewport edge may gain a short grammatical
    // prefix while losing its original tail: "not finding the machine" ->
    // "am not finding". Require an exact continuous original prefix with at
    // least two whole words, not word overlap or a similarity threshold.
    const grammaticalPrefix = {
      'i',
      "i'm",
      'am',
      'is',
      'are',
      'was',
      'were',
      'it',
      "it's",
      'a',
      'an',
      'the'
    };
    final word = RegExp(r"[A-Za-z]+(?:['’][A-Za-z]+)?");
    var offset = 0;
    for (var count = 0; count < 3; count++) {
      final match = word.matchAsPrefix(after, offset);
      if (match == null ||
          !grammaticalPrefix
              .contains(match.group(0)!.toLowerCase().replaceAll('’', "'")) ||
          match.end == after.length ||
          !RegExp(r'\s').hasMatch(after[match.end])) {
        break;
      }
      offset = match.end;
      while (offset < after.length && RegExp(r'\s').hasMatch(after[offset])) {
        offset++;
      }
      final core = after.substring(offset);
      if (core.isEmpty ||
          core.length >= before.length ||
          !before.startsWith(core) ||
          word.allMatches(core).length < 2) {
        continue;
      }
      // Do not turn a partially matched identifier/word into clipping proof.
      if (!RegExp(r'[A-Za-z0-9]').hasMatch(before[core.length])) return true;
    }
    return false;
  }

  static OcrTextChange classify(String previous, String observed) {
    if (previous == observed) return OcrTextChange.identical;
    final before = _presentation(previous);
    final after = _presentation(observed);
    if (before == after) return OcrTextChange.equivalent;

    // A narrowly defined nominalizer in a result clause. Every other code
    // point, including numbers, model identifiers, negation, orientation and
    // ordered instructions, must be identical. This is deliberately not a
    // global removal of 的, a word bag, edit distance or topic keyword rule.
    final resultClause = RegExp(r'^([\s\S]+出来)(的?)(都是[\s\S]+)$');
    final left = resultClause.firstMatch(before);
    final right = resultClause.firstMatch(after);
    if (left != null &&
        right != null &&
        left.group(1) == right.group(1) &&
        left.group(3) == right.group(3) &&
        left.group(2) != right.group(2)) {
      return OcrTextChange.equivalent;
    }
    // Unproved equivalence is a real input change. In particular, shortening
    // text or changing an equal-length identifier cannot silently retain an
    // answer generated for the previous reading.
    return OcrTextChange.material;
  }

  static String _presentation(String value) =>
      value.trim().replaceAll('\r\n', '\n');
}
