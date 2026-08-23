import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/core/xb_ume_locator_source_matcher.dart';

void main() {
  const packages = <String>{'flutter_quill', 'cached_network_image'};

  test('matches package URI', () {
    expect(
      XBUmeLocatorSourceMatcher.findInspectablePackage(
        'package:flutter_quill/src/editor/editor.dart',
        packages,
      ),
      'flutter_quill',
    );
  });

  test('matches hosted pub-cache path with a package version', () {
    expect(
      XBUmeLocatorSourceMatcher.findInspectablePackage(
        '/Users/me/.pub-cache/hosted/pub.dev/'
        'cached_network_image-3.4.1/lib/src/image_provider.dart',
        packages,
      ),
      'cached_network_image',
    );
  });

  test('matches path dependency source', () {
    expect(
      XBUmeLocatorSourceMatcher.findInspectablePackage(
        '/workspace/packages/flutter_quill/lib/src/editor/editor.dart',
        packages,
      ),
      'flutter_quill',
    );
  });

  test('does not match an unconfigured package', () {
    expect(
      XBUmeLocatorSourceMatcher.findInspectablePackage(
        'package:provider/src/provider.dart',
        packages,
      ),
      isNull,
    );
  });
}
