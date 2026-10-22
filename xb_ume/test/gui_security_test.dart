import 'package:flutter_test/flutter_test.dart';

import '../bin/ide_gui.dart' as gui;

void main() {
  group('escapeEvalString', () {
    test('escapes Dart string literal specials', () {
      expect(gui.escapeEvalString(r'a\b'), r'a\\b');
      expect(gui.escapeEvalString(r'$x'), r'\$x');
      expect(gui.escapeEvalString("a'b"), r"a\'b");
      expect(gui.escapeEvalString('a\nb\rc\td'), r'a\nb\rc\td');
    });

    test('path uses the same complete escaping', () {
      expect(gui.escapeEvalPath(r"/tmp/$x/it's"), r"/tmp/\$x/it\'s");
    });
  });

  group('isLocalGuiHost', () {
    test('accepts loopback hosts with the current port', () {
      expect(gui.isLocalGuiHost('127.0.0.1:46129', 46129), isTrue);
      expect(gui.isLocalGuiHost('localhost:46129', 46129), isTrue);
      expect(gui.isLocalGuiHost('[::1]:46129', 46129), isTrue);
      expect(gui.isLocalGuiHost('127.0.0.1', 46129), isTrue);
    });

    test('rejects rebinding hosts and wrong ports', () {
      expect(gui.isLocalGuiHost('evil.com:46129', 46129), isFalse);
      expect(gui.isLocalGuiHost('127.0.0.1:46130', 46129), isFalse);
      expect(gui.isLocalGuiHost('', 46129), isFalse);
      expect(gui.isLocalGuiHost(null, 46129), isFalse);
    });
  });

  group('isAllowedGuiOrigin', () {
    test('allows absent origin for non-browser clients', () {
      expect(gui.isAllowedGuiOrigin(null, 46129), isTrue);
      expect(gui.isAllowedGuiOrigin('', 46129), isTrue);
    });

    test('allows loopback origins on the current port', () {
      expect(gui.isAllowedGuiOrigin('http://127.0.0.1:46129', 46129), isTrue);
      expect(gui.isAllowedGuiOrigin('http://localhost:46129', 46129), isTrue);
    });

    test('rejects cross-site origins and wrong ports', () {
      expect(gui.isAllowedGuiOrigin('http://evil.com:46129', 46129), isFalse);
      expect(gui.isAllowedGuiOrigin('http://127.0.0.1:46130', 46129), isFalse);
      expect(gui.isAllowedGuiOrigin('null', 46129), isFalse);
      expect(gui.isAllowedGuiOrigin('file://', 46129), isFalse);
    });
  });

  group('constantTimeEquals', () {
    test('compares content', () {
      expect(gui.constantTimeEquals('abc', 'abc'), isTrue);
      expect(gui.constantTimeEquals('abc', 'abd'), isFalse);
      expect(gui.constantTimeEquals('abc', 'ab'), isFalse);
      expect(gui.constantTimeEquals('', ''), isTrue);
    });
  });

  group('maskVmTokens', () {
    test('masks VM service auth token in http/ws URLs', () {
      expect(
        gui.maskVmTokens(
          'listening on http://127.0.0.1:61829/AbCdEf0123456789ABCDEF/',
        ),
        'listening on http://127.0.0.1:61829/***/',
      );
      expect(
        gui.maskVmTokens('ws://localhost:61829/AbCdEf0123456789ABCDEF/ws'),
        'ws://localhost:61829/***/ws',
      );
    });

    test('leaves short path segments and normal files alone', () {
      expect(
        gui.maskVmTokens('http://127.0.0.1:61829/api/logs'),
        contains('/api/logs'),
      );
      expect(
        gui.maskVmTokens('/Users/me/project/file.dart'),
        '/Users/me/project/file.dart',
      );
    });
  });

  group('replayCrossHost', () {
    test('detects scheme/host/port changes', () {
      expect(
          gui.replayCrossHost('https://a.com/x', 'https://a.com/y'), isFalse);
      expect(gui.replayCrossHost('https://a.com/x', 'https://b.com/x'), isTrue);
      expect(gui.replayCrossHost('https://a.com/x', 'http://a.com/x'), isTrue);
      expect(
        gui.replayCrossHost('https://a.com/x', 'https://a.com:8443/x'),
        isTrue,
      );
      expect(gui.replayCrossHost('not a url', 'https://a.com/x'), isTrue);
    });
  });

  group('stripReplayHeaders', () {
    test('removes sensitive headers that still carry the original value', () {
      final headers = <String, String>{
        'authorization': 'Bearer old',
        'cookie': 'sid=1',
        'X-Trace': 't',
      };
      gui.stripReplayHeaders(headers, <String>['Bearer old', 'sid=1']);
      expect(headers, <String, String>{'X-Trace': 't'});
    });

    test('keeps sensitive headers rewritten for the new host', () {
      final headers = <String, String>{
        'authorization': 'Bearer new',
        'cookie': 'sid=2',
      };
      gui.stripReplayHeaders(headers, <String>['Bearer old', 'sid=1']);
      expect(headers, <String, String>{
        'authorization': 'Bearer new',
        'cookie': 'sid=2',
      });
    });

    test('ignores empty original values and name casing', () {
      final headers = <String, String>{'AUTHORIZATION': 'x', 'host': 'a.com'};
      gui.stripReplayHeaders(headers, <String>['', 'x', 'a.com']);
      expect(headers, isEmpty);
    });
  });

  group('generateGuiToken', () {
    test('produces a url-safe random token', () {
      final a = gui.generateGuiToken();
      final b = gui.generateGuiToken();
      expect(a, isNot(equals(b)));
      expect(a.length, greaterThanOrEqualTo(40));
      expect(a, isNot(contains('=')));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a), isTrue);
    });
  });
}
