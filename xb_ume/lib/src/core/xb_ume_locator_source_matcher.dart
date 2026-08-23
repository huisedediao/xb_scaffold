class XBUmeLocatorSourceMatcher {
  const XBUmeLocatorSourceMatcher._();

  /// Returns the configured package that owns [file], if any.
  ///
  /// Flutter may report creation locations as a `package:` URI, an absolute
  /// path dependency path, or a hosted pub-cache path containing a versioned
  /// directory. All three forms are supported here.
  static String? findInspectablePackage(
    String? file,
    Set<String> inspectablePackages,
  ) {
    if (file == null || file.isEmpty || inspectablePackages.isEmpty) {
      return null;
    }

    final normalizedFile = file.replaceAll('\\', '/');
    final uri = Uri.tryParse(file);
    final uriPackage = uri?.scheme == 'package' && uri!.pathSegments.isNotEmpty
        ? uri.pathSegments.first
        : null;

    for (final configuredName in inspectablePackages) {
      final packageName = _normalizePackageName(configuredName);
      if (packageName.isEmpty) continue;

      if (uriPackage == packageName) {
        return packageName;
      }

      final escapedName = RegExp.escape(packageName);
      final packageDirectory = RegExp(
        '/$escapedName(?:-[0-9][^/]*)?/lib/',
        caseSensitive: false,
      );
      if (packageDirectory.hasMatch(normalizedFile)) {
        return packageName;
      }
    }

    return null;
  }

  static String _normalizePackageName(String value) {
    var result = value.trim();
    if (result.startsWith('package:')) {
      result = result.substring('package:'.length);
    }
    final slash = result.indexOf('/');
    if (slash >= 0) {
      result = result.substring(0, slash);
    }
    return result;
  }
}
