import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'conversation_file_store.dart';
import '../runtime/runtime_trace.dart';

class MediaVisualMatch {
  const MediaVisualMatch(this.messageId, this.path, this.partial, this.score);
  final String messageId;
  final String path;
  final bool partial;
  final double score;
}

/// Pixel correspondence, not semantic similarity or a fuzzy media hash. Only
/// this customer's same-clock/turn representations are candidates. Real resends
/// at another verified sender clock always remain separate messages.
class MediaVisualMatcher {
  MediaVisualMatcher(this.store, {this.record = RuntimeTrace.record});
  final void Function(String, Map<String, Object?>) record;
  final ConversationFileStore store;
  final _decoded = <String, Future<_Raster?>>{};

  /// Strict raster correspondence for two already customer-owned card
  /// representations. Callers must separately establish card geometry/clock
  /// candidate ownership; this is never a global asset-hash deduplicator.
  static Future<double?> correspondenceScore(
      Uint8List candidate, Uint8List reference,
      {bool ignorePlayOverlay = false}) async {
    final a = (await _Raster.decode(candidate))?.photoContent();
    final b = (await _Raster.decode(reference))?.photoContent();
    if (a == null || b == null) return null;
    return Isolate.run(() => math.min(
        _distance(a, b, ignorePlayOverlay: ignorePlayOverlay),
        _distance(b, a, ignorePlayOverlay: ignorePlayOverlay)));
  }

  /// A gray loading cover has no pixels that can identify its eventual video.
  /// Instead require the same immutable incoming-card location and identical
  /// transcript prefix outside that card. Later outgoing delivery badges are
  /// below the card and cannot establish or invalidate this association.
  static Future<bool> loadingCardTransition({
    required Uint8List previousCard,
    required Uint8List currentCard,
    required Uint8List previousFrame,
    required Uint8List currentFrame,
    required List<double> previousRegion,
    required List<double> currentRegion,
    required List<double> transcript,
  }) =>
      _cardFrameContinuation(
          previousCard: previousCard,
          currentCard: currentCard,
          previousFrame: previousFrame,
          currentFrame: currentFrame,
          previousRegion: previousRegion,
          currentRegion: currentRegion,
          transcript: transcript,
          requireLoading: true);

  /// A headerless card may be reobserved without inventing a sender clock.
  /// Both its pixels and the immutable transcript prefix outside its rectangle
  /// must agree; matching asset bytes alone cannot merge two real resends.
  static Future<bool> frozenCardContinuation({
    required Uint8List previousCard,
    required Uint8List currentCard,
    required Uint8List previousFrame,
    required Uint8List currentFrame,
    required List<double> previousRegion,
    required List<double> currentRegion,
    required List<double> transcript,
    bool ignorePlayOverlay = false,
    bool verifiedSenderClock = false,
  }) async {
    final score = await correspondenceScore(previousCard, currentCard,
        ignorePlayOverlay: ignorePlayOverlay);
    // Full-frame continuation also proves a clipped subregion of the card.
    // A cache/file resemblance by itself is never sufficient.
    if (score == null) return false;
    return _cardFrameContinuation(
        previousCard: previousCard,
        currentCard: currentCard,
        previousFrame: previousFrame,
        currentFrame: currentFrame,
        previousRegion: previousRegion,
        currentRegion: currentRegion,
        transcript: transcript,
        requireLoading: false,
        stationaryCardMatches: score <= .018,
        verifiedSenderClock: verifiedSenderClock);
  }

  static Future<bool> _cardFrameContinuation({
    required Uint8List previousCard,
    required Uint8List currentCard,
    required Uint8List previousFrame,
    required Uint8List currentFrame,
    required List<double> previousRegion,
    required List<double> currentRegion,
    required List<double> transcript,
    required bool requireLoading,
    bool stationaryCardMatches = true,
    bool verifiedSenderClock = false,
  }) async {
    if (previousRegion.length != 4 ||
        currentRegion.length != 4 ||
        transcript.length != 4) {
      return false;
    }
    final a = previousRegion, b = currentRegion;
    final overlapWidth =
        math.min(a[0] + a[2], b[0] + b[2]) - math.max(a[0], b[0]);
    final overlapHeight =
        math.min(a[1] + a[3], b[1] + b[3]) - math.max(a[1], b[1]);
    final smallerArea = math.min(a[2] * a[3], b[2] * b[3]);
    final nested = overlapWidth > 0 &&
        overlapHeight > 0 &&
        smallerArea > 0 &&
        overlapWidth * overlapHeight / smallerArea >= .90;
    if ([...a, ...b, ...transcript].any((v) => !v.isFinite) ||
        a[2] <= 0 ||
        a[3] <= 0 ||
        b[2] <= 0 ||
        b[3] <= 0 ||
        (!nested &&
            ((a[0] + a[2] / 2 - b[0] - b[2] / 2).abs() > .01 ||
                a[2] / b[2] < .75 ||
                a[2] / b[2] > 1.34 ||
                a[3] / b[3] < .25 ||
                a[3] / b[3] > 4))) {
      return false;
    }
    final old = await _Raster.decode(previousCard);
    final next = await _Raster.decode(currentCard);
    if (old == null ||
        next == null ||
        (requireLoading &&
            !old.loadingCover &&
            !old.blankImageCover &&
            !next.loadingCover &&
            !next.blankImageCover)) {
      return false;
    }
    final before = await _Raster.decode(previousFrame, targetWidth: null);
    final after = await _Raster.decode(currentFrame, targetWidth: null);
    if (before == null ||
        after == null ||
        before.width != after.width ||
        before.height != after.height) {
      return false;
    }
    return Isolate.run(() {
      final width = before.width, height = before.height;
      final left = (transcript[0] * width).ceil();
      final top = (transcript[1] * height).ceil();
      final right = (transcript[2] * width).floor();
      final bottom = (transcript[3] * height).floor();
      final maskLeft = (math.min(a[0], b[0]) * width).floor() - 2;
      final maskTop = (math.min(a[1], b[1]) * height).floor() - 2;
      final maskRight = (math.max(a[0] + a[2], b[0] + b[2]) * width).ceil() + 2;
      final maskBottom =
          (math.max(a[1] + a[3], b[1] + b[3]) * height).ceil() + 2;
      if (left < 0 ||
          top < 0 ||
          right > width ||
          bottom > height ||
          maskLeft < left ||
          maskTop < top ||
          maskRight > right ||
          right <= left ||
          maskBottom <= top) {
        return false;
      }
      // Preserve the original byte-exact stationary proof. Scrolling uses a
      // separate, foreground/context proof because JD's pale watermark stays
      // fixed to the viewport while the actual messages move.
      var compared = 0;
      var exact = true;
      for (var y = top; y < math.min(maskBottom, bottom) && exact; y++) {
        for (var x = left; x < right; x++) {
          if (x >= maskLeft && x < maskRight && y >= maskTop) continue;
          final offset = (y * width + x) * 4;
          for (var c = 0; c < 4; c++) {
            if (before.rgba[offset + c] != after.rgba[offset + c]) {
              exact = false;
              break;
            }
          }
          compared++;
        }
      }
      if (exact &&
          stationaryCardMatches &&
          compared >= 1000 &&
          (a[1] + a[3] / 2 - b[1] - b[3] / 2).abs() <= .01) {
        return true;
      }
      return _translatedCardContext(
          before, after, a, b, [left, top, right, bottom],
          requireLoading: requireLoading,
          verifiedSenderClock: verifiedSenderClock);
    });
  }

  // Same occurrence proof for a scrolled viewport. At least three adjacent
  // text-line bands must move together with this card. A repeated file, a
  // matching clock/header or empty background cannot satisfy this proof.
  static bool _translatedCardContext(_Raster before, _Raster after,
      List<double> a, List<double> b, List<int> chat,
      {required bool requireLoading, required bool verifiedSenderClock}) {
    final w = before.width, h = before.height;
    final l = chat[0] + 2, t = chat[1], r = chat[2] - 8, bot = chat[3];
    final at = (a[1] * h).round(), ab = ((a[1] + a[3]) * h).round();
    final bt = (b[1] * h).round(), bb = ((b[1] + b[3]) * h).round();
    final centerShift = ((bt + bb - at - ab) / 2).round();
    final clipped = (a[3] / b[3] < .75 || a[3] / b[3] > 1.34);
    final radius = clipped ? ((ab - at).abs() / 2).ceil() : 8;
    // An inner crop with an independently verified same clock/slot retains
    // the actual sender header plus corresponding card pixels. Headerless
    // observations still require three independent surrounding text bands.
    final requiredBands =
        clipped && verifiedSenderClock && !requireLoading ? 1 : 3;
    final shifts = <int>{
      for (final nominal in [bt - at, bb - ab, centerShift])
        for (var delta = -radius; delta <= radius; delta++) nominal + delta
    }.toList()
      ..sort(
          (x, y) => (x - centerShift).abs().compareTo((y - centerShift).abs()));
    bool ink(_Raster image, int x, int y) {
      final p = (y * w + x) * 4;
      final red = image.rgba[p],
          green = image.rgba[p + 1],
          blue = image.rgba[p + 2];
      return (red + green + blue) < 540 &&
          math.max(red, math.max(green, blue)) -
                  math.min(red, math.min(green, blue)) <
              42;
    }

    bool context(int dy, bool prefix) {
      final start =
          prefix ? math.min(at + dy, bt) - 4 : math.max(ab + dy, bb) + 4;
      final end = prefix ? math.max(t, t + dy) : math.min(bot, bot + dy) - 1;
      if (start < t || start >= bot || (prefix ? start <= end : start >= end)) {
        return false;
      }
      var bands = 0, bandInk = 0, gap = 0, totalInk = 0;
      int? firstInk, lastInk;
      bool enough() =>
          bands >= requiredBands &&
          totalInk >= 1000 &&
          firstInk != null &&
          lastInk != null &&
          (lastInk - firstInk).abs() >= (requiredBands == 1 ? 12 : 72);
      for (var y = start; prefix ? y >= end : y <= end; y += prefix ? -1 : 1) {
        final oy = y - dy;
        if (oy < t || oy >= bot) break;
        var union = 0, different = 0;
        for (var x = l; x < r; x++) {
          final oldInk = ink(before, x, oy), newInk = ink(after, x, y);
          if (oldInk || newInk) union++;
          if (oldInk != newInk) different++;
        }
        // Antialiasing over the fixed pale watermark can alter a few edge
        // pixels. Content changes and non-matching text fail this row.
        if (different > math.max(2, (union * .01).floor())) {
          return enough();
        }
        if (union >= 3) {
          gap = 0;
          bandInk += union;
          totalInk += union;
          firstInk ??= y;
          lastInk = y;
        } else {
          gap++;
          if (gap == 4 && bandInk >= 50) {
            bands++;
            bandInk = 0;
          }
        }
        if (enough()) return true;
      }
      if (bandInk >= 50) bands++;
      return enough();
    }

    bool sameVisibleCard(int dy) {
      if (requireLoading) return true;
      final left = math.max((a[0] * w).ceil(), (b[0] * w).ceil());
      final right =
          math.min(((a[0] + a[2]) * w).floor(), ((b[0] + b[2]) * w).floor());
      final top = math.max(at + dy, bt), bottom = math.min(ab + dy, bb);
      if (right <= left ||
          bottom <= top ||
          (right - left) * (bottom - top) <
              math.min(a[2] * a[3], b[2] * b[3]) * w * h * .80) {
        return false;
      }
      var error = 0, count = 0;
      for (var y = math.max(top, t); y < math.min(bottom, bot); y += 2) {
        final oy = y - dy;
        if (oy < t || oy >= bot) continue;
        for (var x = left; x < right; x += 2) {
          final old = (oy * w + x) * 4, next = (y * w + x) * 4;
          for (var c = 0; c < 3; c++) {
            error += (before.rgba[old + c] - after.rgba[next + c]).abs();
          }
          count += 3;
        }
      }
      return count >= 3000 && error / (count * 255) <= .025;
    }

    for (final dy in shifts) {
      // Stationary captures must pass the byte-exact proof above; do not
      // relax it into a partial-context match after a differing pixel.
      if (dy.abs() < 2 || dy.abs() >= bot - t) continue;
      if ((context(dy, true) || context(dy, false)) && sameVisibleCard(dy)) {
        return true;
      }
    }
    return false;
  }

  static Future<bool> isLoadingCover(Uint8List bytes) async {
    final image = await _Raster.decode(bytes);
    return image != null && (image.loadingCover || image.blankImageCover);
  }

  Future<MediaVisualMatch?> find({
    required String customer,
    required Uint8List bytes,
    required DateTime observedAt,
    DateTime? sentAt,
    String? turnKey,
    bool candidateOriginal = false,
  }) async {
    try {
      return await _find(
          customer: customer,
          bytes: bytes,
          observedAt: observedAt,
          sentAt: sentAt,
          turnKey: turnKey,
          candidateOriginal: candidateOriginal);
    } catch (error, stack) {
      record('media.representation_match_failed', {
        'customer': customer,
        'error': '$error',
        'stack': '$stack',
        'action': 'preserve_new_capture_without_merging',
      });
      return null;
    }
  }

  Future<MediaVisualMatch?> _find({
    required String customer,
    required Uint8List bytes,
    required DateTime observedAt,
    DateTime? sentAt,
    String? turnKey,
    bool candidateOriginal = false,
  }) async {
    final document = await store.read(customer);
    final rows = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final raster = (await _Raster.decode(bytes))?.photoContent();
    if (raster == null) {
      record('media.condition', {
        'stage': 'media.representation_match',
        'sourceFile': 'lib/storage/media_visual_matcher.dart',
        'sourceSymbol': 'MediaVisualMatcher._find',
        'conditionId': 'representation.decode',
        'expression': 'decodedCandidate != null',
        'customer': customer,
        'observedAt': observedAt.toUtc().toIso8601String(),
        'turnKey': turnKey,
        'actual': {'decodedCandidate': false, 'byteCount': bytes.length},
        'threshold': const <String, Object?>{},
        'passed': false,
        'outcome': 'blocked',
      });
      return null;
    }
    final matches = <MediaVisualMatch>[];
    final seen = <String>{};
    for (final row in rows.reversed.take(80)) {
      if (row['direction'] != 'incoming') continue;
      final clock = DateTime.tryParse(row['sent_at']?.toString() ?? '');
      final captured = DateTime.tryParse(row['captured_at']?.toString() ?? '');
      if (sentAt != null) {
        if (clock == null || !clock.isAtSameMomentAs(sentAt)) continue;
      } else {
        if (turnKey != null && row['observation_turn_key'] != turnKey) continue;
        if (captured == null ||
            observedAt.difference(captured).abs() >
                const Duration(minutes: 5)) {
          continue;
        }
      }
      for (final media
          in (row['media'] as List<Object?>? ?? const []).whereType<Map>()) {
        if ((candidateOriginal && media['is_partial'] != true) ||
            media['type'] != 'image' ||
            media['capture_source'] == 'jd_video_frame_1fps') {
          continue;
        }
        final path = media['path']?.toString() ?? '';
        if (path.isEmpty || !seen.add(path)) continue;
        final file = File(path);
        if (!await file.exists()) continue;
        final key =
            '$path:${(await file.stat()).modified.microsecondsSinceEpoch}';
        if (_decoded.length >= 32 && !_decoded.containsKey(key)) {
          _decoded.remove(_decoded.keys.first);
        }
        final decodedReference =
            await (_decoded[key] ??= file.readAsBytes().then(_Raster.decode));
        final original = decodedReference?.photoContent();
        if (original == null) continue;
        // Either side can be a decorated thumbnail; originals never acquire
        // UI-derived identity. Require a unique strong correspondence.
        final score = await _compareMediaPixels(raster, original);
        record('media.representation_compared', {
          'customer': customer,
          'referenceMessageId': row['id'],
          'messageId': row['id'],
          'path': path,
          'pixelError': score,
          'maximumPixelError': .025,
          'passed': score <= .025,
          'sameVerifiedClock': sentAt != null,
          'candidatePartial': media['is_partial'],
        });
        record('media.condition', {
          'stage': 'media.representation_match',
          'sourceFile': 'lib/storage/media_visual_matcher.dart',
          'sourceSymbol': 'MediaVisualMatcher._find',
          'conditionId': 'representation.pixel_error',
          'expression': 'pixelError <= 0.025',
          'customer': customer,
          'messageId': row['id'],
          'referenceMessageId': row['id'],
          'path': path,
          'observedAt': observedAt.toUtc().toIso8601String(),
          'turnKey': turnKey,
          'actual': {'pixelError': score, 'sameVerifiedClock': sentAt != null},
          'threshold': {'maximumPixelError': .025},
          'passed': score <= .025,
          'outcome': score <= .025 ? 'pass' : 'blocked',
        });
        if (score <= .025) {
          matches.add(MediaVisualMatch(
              row['id'] as String, path, media['is_partial'] == true, score));
        }
        if (seen.length >= 12) break;
      }
      if (seen.length >= 12) break;
    }
    final originals = matches.where((m) => !m.partial).toList();
    final rankedScores = matches.map((m) => m.score).toList()..sort();
    final uniqueSource = originals.length == 1 ||
        (rankedScores.isNotEmpty &&
            (rankedScores.length == 1 ||
                rankedScores[1] - rankedScores.first >= .008));
    record('media.condition', {
      'stage': 'media.representation_match',
      'sourceFile': 'lib/storage/media_visual_matcher.dart',
      'sourceSymbol': 'MediaVisualMatcher._find',
      'conditionId': 'representation.unique_source',
      'expression':
          'originalMatches == 1 || (matches > 0 && (matches == 1 || secondScore-bestScore >= 0.008))',
      'customer': customer,
      'observedAt': observedAt.toUtc().toIso8601String(),
      'turnKey': turnKey,
      'actual': {
        'originalMatches': originals.length,
        'matches': matches.length,
        'candidateMessageIds': matches.map((m) => m.messageId).toList(),
        'scoresAscending': rankedScores,
      },
      'threshold': {'minimumScoreMargin': .008},
      'passed': uniqueSource,
      'outcome': uniqueSource
          ? 'selected'
          : matches.isEmpty
              ? 'no_visual_match'
              : 'ambiguous',
    });
    if (originals.length == 1) return originals.single;
    matches.sort((a, b) => a.score.compareTo(b.score));
    if (matches.isEmpty ||
        (matches.length > 1 && matches[1].score - matches.first.score < .008)) {
      return null;
    }
    return matches.first;
  }

  static double _distance(_Raster decorated, _Raster reference,
      {bool ignorePlayOverlay = false}) {
    const pads = [0, 1, 2, 3, 4, 5, 6, 8, 10, 12];
    const tops = [0, 2, 4, 6, 8, 10, 12, 16];
    const bottoms = [0, 1, 2, 3, 4, 6, 8];
    final ref = reference.samples(0, 0, reference.width, reference.height);
    final luminance = <double>[
      for (var i = 0; i < ref.length; i += 3)
        .2126 * ref[i] + .7152 * ref[i + 1] + .0722 * ref[i + 2]
    ];
    final mean = luminance.reduce((a, b) => a + b) / luminance.length;
    final variance =
        luminance.fold<double>(0, (v, c) => v + (c - mean) * (c - mean)) /
            luminance.length;
    if (variance < 200) return 1; // Flat thumbnails cannot establish identity.
    var best = 1.0;
    var bestWindow = <double>[
      0,
      0,
      decorated.width.toDouble(),
      decorated.height.toDouble()
    ];
    for (final left in pads) {
      for (final right in pads) {
        final width = decorated.width - left - right;
        if (width < decorated.width * .65) continue;
        for (final top in tops) {
          for (final bottom in bottoms) {
            final height = decorated.height - top - bottom;
            if (height < decorated.height * .65 ||
                ((width / height) / (reference.width / reference.height) - 1)
                        .abs() >
                    .045) {
              continue;
            }
            final actual = decorated.samples(left, top, width, height);
            final score =
                _pixelError(ref, actual, ignorePlayOverlay: ignorePlayOverlay);
            if (score < best) {
              best = score;
              bestWindow = [
                left.toDouble(),
                top.toDouble(),
                width.toDouble(),
                height.toDouble()
              ];
            }
          }
        }
      }
    }
    final window = bestWindow;
    for (final dl in [-.5, -.25, 0.0, .25, .5]) {
      for (final dt in [-.5, -.25, 0.0, .25, .5]) {
        for (final dw in [-.5, -.25, 0.0, .25, .5]) {
          for (final dh in [-.5, -.25, 0.0, .25, .5]) {
            final left = window[0] + dl, top = window[1] + dt;
            final width = window[2] + dw, height = window[3] + dh;
            if (left < 0 ||
                top < 0 ||
                left + width > decorated.width ||
                top + height > decorated.height) {
              continue;
            }
            final values = decorated.samples(left, top, width, height);
            best = math.min(best,
                _pixelError(ref, values, ignorePlayOverlay: ignorePlayOverlay));
          }
        }
      }
    }
    return best;
  }

  static double _pixelError(List<double> reference, List<double> candidate,
      {bool ignorePlayOverlay = false}) {
    bool ignored(int index) {
      if (!ignorePlayOverlay) return false;
      final pixel = index ~/ 3, x = pixel % 16, y = pixel ~/ 16;
      return x >= 6 && x < 10 && y >= 5 && y < 11;
    }

    final shifts = <double>[0, 0, 0];
    var samples = 0;
    for (var i = 0; i < reference.length; i++) {
      if (ignored(i)) continue;
      shifts[i % 3] += candidate[i] - reference[i];
      samples++;
    }
    for (var channel = 0; channel < 3; channel++) {
      shifts[channel] /= samples / 3;
      // A bounded display profile/brightness shift is permissible; a different
      // color layout is not. Correspondence must still hold at every sample.
      if (shifts[channel].abs() > 24) return 1;
    }
    var error = 0.0;
    for (var i = 0; i < reference.length; i++) {
      if (ignored(i)) continue;
      error += (candidate[i] - shifts[i % 3] - reference[i]).abs();
    }
    return error / (samples * 255);
  }
}

class _Raster {
  _Raster(this.width, this.height, this.rgba);
  final int width, height;
  final Uint8List rgba;
  static Future<_Raster?> decode(Uint8List bytes,
      {int? targetWidth = 64}) async {
    try {
      final codec =
          await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        try {
          final data =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          return data == null
              ? null
              : _Raster(
                  image.width,
                  image.height,
                  data.buffer
                      .asUint8List(data.offsetInBytes, data.lengthInBytes));
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  // A loading image can be a pure white rectangle, with JD's emoji toolbar
  // accidentally included at the bottom of the detector crop. Only its large
  // empty inner panel qualifies; callers still need the frozen-frame proof.
  bool get blankImageCover {
    var count = 0, white = 0;
    var sum = 0.0, squares = 0.0;
    for (var y = (height * .08).ceil(); y < height * .75; y++) {
      for (var x = (width * .12).ceil(); x < width * .88; x++) {
        final i = (y * width + x) * 4;
        final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
        final value = (r + g + b) / 3;
        count++;
        sum += value;
        squares += value * value;
        if (math.min(r, math.min(g, b)) >= 248 &&
            math.max(r, math.max(g, b)) - math.min(r, math.min(g, b)) <= 4) {
          white++;
        }
      }
    }
    return count > 100 &&
        white / count >= .995 &&
        squares / count - math.pow(sum / count, 2) < 10;
  }

  bool get loadingCover {
    var count = 0, flat = 0;
    var sum = 0.0, squares = 0.0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (x >= width * .3 &&
            x < width * .7 &&
            y >= height * .3 &&
            y < height * .7) {
          continue;
        }
        final i = (y * width + x) * 4;
        final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
        final luma = (r + g + b) / 3;
        count++;
        sum += luma;
        squares += luma * luma;
        if (luma >= 195 &&
            luma <= 255 &&
            math.max(r, math.max(g, b)) - math.min(r, math.min(g, b)) <= 18) {
          flat++;
        }
      }
    }
    return count > 100 &&
        flat / count >= .94 &&
        squares / count - math.pow(sum / count, 2) < 150;
  }

  _Raster photoContent() {
    // JD can place a white margin, rounded corner or sender title around the
    // image. Detect the dense photo rectangle before comparing source pixels.
    bool nonwhite(int x, int y) {
      final i = (y * width + x) * 4;
      return rgba[i] < 235 || rgba[i + 1] < 235 || rgba[i + 2] < 235;
    }

    final rows = <int>[];
    for (var y = 0; y < height; y++) {
      var count = 0;
      for (var x = 0; x < width; x++) {
        if (nonwhite(x, y)) count++;
      }
      if (count > width * .55) rows.add(y);
    }
    if (rows.isEmpty) return this;
    final top = rows.first, bottom = rows.last + 1;
    final columns = <int>[];
    for (var x = 0; x < width; x++) {
      var count = 0;
      for (var y = top; y < bottom; y++) {
        if (nonwhite(x, y)) count++;
      }
      if (count > (bottom - top) * .55) columns.add(x);
    }
    if (columns.isEmpty) return this;
    final left = columns.first, right = columns.last + 1;
    final w = right - left, h = bottom - top;
    if (w * h < width * height * .60 || w < 24 || h < 24) return this;
    final output = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      output.setRange(
          y * w * 4, (y + 1) * w * 4, rgba, ((top + y) * width + left) * 4);
    }
    return _Raster(w, h, output);
  }

  List<double> samples(num left, num top, num w, num h) {
    final result = <double>[];
    for (var y = 0; y < 16; y++) {
      for (var x = 0; x < 16; x++) {
        final sx =
            (left + (x + .5) * w / 16 - .5).clamp(0, width - 1).toDouble();
        final sy =
            (top + (y + .5) * h / 16 - .5).clamp(0, height - 1).toDouble();
        final x0 = sx.floor(), y0 = sy.floor();
        final x1 = math.min(width - 1, x0 + 1),
            y1 = math.min(height - 1, y0 + 1);
        final dx = sx - x0, dy = sy - y0;
        for (var channel = 0; channel < 3; channel++) {
          double pixel(int px, int py) =>
              rgba[(py * width + px) * 4 + channel].toDouble();
          result.add(
              (pixel(x0, y0) * (1 - dx) + pixel(x1, y0) * dx) * (1 - dy) +
                  (pixel(x0, y1) * (1 - dx) + pixel(x1, y1) * dx) * dy);
        }
      }
    }
    return result;
  }
}

// The dense crop search must not occupy Dart's UI/timer isolate. Only decoded
// numeric pixels cross this boundary; codecs and customer histories stay local.
Future<double> _compareMediaPixels(_Raster a, _Raster b) =>
    Isolate.run(() => math.min(MediaVisualMatcher._distance(a, b),
        MediaVisualMatcher._distance(b, a)));
