import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// Runs [fn] in a zone that captures all `print` output into a single string.
String captureOutput(void Function() fn) {
  final captured = <String>[];
  runZoned(
    fn,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        captured.add(line);
      },
    ),
  );
  return captured.join('');
}

/// Returns the number of PrettyPrinter box blocks in the captured output.
/// Each call to _print produces one block starting with "┌──" or "┌─".
int countBlocks(String output) {
  return '┌'.allMatches(output).length;
}

void main() {
  group('xb_print - all methods smoke test', () {
    test('xbLog does not throw', () {
      expect(() => xbLog('test log message'), returnsNormally);
    });

    test('xbError does not throw', () {
      expect(() => xbError('test error message'), returnsNormally);
    });

    test('xbUnDisappear does not throw', () {
      expect(() => xbUnDisappear('test undisappear message'), returnsNormally);
    });

    test('xbDebug does not throw', () {
      expect(() => xbDebug('test debug message'), returnsNormally);
    });

    test('xbInfo does not throw', () {
      expect(() => xbInfo('test info message'), returnsNormally);
    });

    test('xbWarn does not throw', () {
      expect(() => xbWarn('test warn message'), returnsNormally);
    });

    test('xbFatal does not throw', () {
      expect(() => xbFatal('test fatal message'), returnsNormally);
    });
  });

  group('xb_print - edge cases', () {
    test('empty string does not throw', () {
      expect(() => xbLog(''), returnsNormally);
      expect(() => xbError(''), returnsNormally);
      expect(() => xbUnDisappear(''), returnsNormally);
      expect(() => xbDebug(''), returnsNormally);
      expect(() => xbInfo(''), returnsNormally);
      expect(() => xbWarn(''), returnsNormally);
      expect(() => xbFatal(''), returnsNormally);
    });

    test('null object.toString() handling', () {
      final obj = _NullableToString();
      expect(() => xbLog(obj), returnsNormally);
    });

    test('special characters do not throw', () {
      const special = '!@#\$%^&*()_+-=[]{}|;:\'",.<>?/~`\n\t\r';
      expect(() => xbLog(special), returnsNormally);
    });

    test('unicode/emoji characters do not throw', () {
      const unicode = '你好世界 🌍🎉 café naïve 日本語';
      expect(() => xbLog(unicode), returnsNormally);
    });
  });

  group('xb_print - long text chunking verification', () {
    test('800 chars (exact 1 chunk) prints 1 block with full content', () {
      const marker = 'MARK_1CHUNK';
      const half = 394; // (800 - 12) ~/ 2
      final text = '${'a' * half}$marker${'b' * half}';

      final output = captureOutput(() => xbLog(text));

      expect(countBlocks(output), 1,
          reason: '800 chars fits in exactly 1 chunk');
      expect(output, contains(marker));
    });

    test('801 chars produces 2 blocks with content split correctly', () {
      // 801 chars: chunk 0 = 800, chunk 1 = 1
      // Use a 1-char tail so the last chunk is just that char
      const headMarker = 'H801';
      final text = '$headMarker${'x' * 796}Z'; // 4 + 796 + 1 = 801

      final output = captureOutput(() => xbLog(text));

      expect(countBlocks(output), 2,
          reason: '801 chars should produce 2 chunks (800 + 1)');
      expect(output, contains(headMarker),
          reason: 'Head marker should be in chunk 0');
      // The letter 'Z' should appear in the second block — the
      // PrettyPrinter renders it on its own line with a timestamp.
      expect(output, contains('Z'),
          reason: 'The 801st char Z should be in chunk 1');
    });

    test('1600 chars (exact 2 chunks) prints 2 blocks with full content', () {
      const headMarker = 'HEAD_2CHUNKS';
      const tailMarker = 'TAIL_2CHUNKS';
      const paddingLen = 1600 - headMarker.length - tailMarker.length;
      final text = '$headMarker${'m' * paddingLen}$tailMarker';

      final output = captureOutput(() => xbLog(text));

      expect(countBlocks(output), 2,
          reason: '1600 chars = exactly 2 chunks');
      expect(output, contains(headMarker));
      expect(output, contains(tailMarker),
          reason: 'Tail marker should be fully in chunk 1 (800 chars)');
    });

    test('1601 chars produces 3 blocks with content split correctly', () {
      // 1601 chars: chunk 0 = 800, chunk 1 = 800, chunk 2 = 1
      const headMarker = 'H1601';
      // 1601 = 5 (headMarker) + 1595 (padding) + 1 (Z)
      final text = '$headMarker${'x' * 1595}Z';

      final output = captureOutput(() => xbLog(text));

      expect(countBlocks(output), 3,
          reason: '1601 chars should produce 3 chunks (800 + 800 + 1)');
      expect(output, contains(headMarker));
      expect(output, contains('Z'),
          reason: 'The 1601st char Z should be in chunk 2');
    });

    test('very long text (100000 chars) all content printed', () {
      const headMarker = 'VLONG_HEAD';
      const tailMarker = 'VLONG_TAIL';
      const paddingLen = 100000 - headMarker.length - tailMarker.length;
      final text = '$headMarker${'y' * paddingLen}$tailMarker';

      final output = captureOutput(() => xbLog(text));

      // 100000 / 800 = 125 exact chunks
      expect(countBlocks(output), 125,
          reason: '100000 / 800 = 125 exact chunks');
      expect(output, contains(headMarker),
          reason: 'Head marker should be in chunk 0');
      expect(output, contains(tailMarker),
          reason: 'Tail marker should be fully in last chunk');
    });

    test('chunk boundary: remainder tail fully printed', () {
      // Text with 3-char remainder to verify last chunk prints correctly
      // 800 + 800 + 3 = 1603 chars → 3 chunks
      const headMarker = 'BOUNDARY';
      const tailMarker = 'END'; // 3 chars, fits entirely in the 3-char remainder
      // 1603 - 7 - 3 = 1593 padding
      final text = '$headMarker${'p' * 1593}$tailMarker';

      final output = captureOutput(() => xbLog(text));

      expect(countBlocks(output), 3,
          reason: '1603 chars = 3 chunks (800 + 800 + 3)');
      expect(output, contains(headMarker));
      expect(output, contains(tailMarker),
          reason: '3-char tail marker should be fully in the 3-char last chunk');
    });
  });

  group('xb_print - long text with all methods', () {
    test('all 7 methods print 2000-char text completely', () {
      const headMarker = 'ALL7_HEAD';
      const tailMarker = 'ALL7_TAIL';
      const paddingLen = 2000 - headMarker.length - tailMarker.length;
      final text = '$headMarker${'z' * paddingLen}$tailMarker';

      final output = captureOutput(() {
        xbLog(text);
        xbDebug(text);
        xbInfo(text);
        xbWarn(text);
        xbError(text);
        xbFatal(text);
        xbUnDisappear(text);
      });

      // 2000 / 800 = 2 remainder 400 → 3 chunks per method × 7 methods = 21
      expect(countBlocks(output), 21);
      // head and tail should each appear 7 times
      expect(headMarker.allMatches(output).length, greaterThanOrEqualTo(7));
      expect(tailMarker.allMatches(output).length, greaterThanOrEqualTo(7));
    });
  });

  group('xb_print - kDebugMode behavior', () {
    test('debug-gated methods run in test mode (kDebugMode is true)', () {
      expect(kDebugMode, isTrue,
          reason: 'Tests run in debug mode, kDebugMode should be true');
    });
  });
}

class _NullableToString {
  @override
  String toString() => 'nullable-object';
}
