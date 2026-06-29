class XBThemeImage {
  final String prefix;
  final Set<String> _availableAssets = {};
  String? _fallbackPrefix;

  XBThemeImage({String? prefix})
      : prefix = prefix ?? "assets/images/default/";

  void setAvailableAssets(Set<String> assets) {
    _availableAssets.addAll(assets);
  }

  void setFallbackPrefix(String? fallbackPrefix) {
    if (fallbackPrefix == null) {
      _fallbackPrefix = null;
      return;
    }
    _fallbackPrefix = fallbackPrefix.endsWith("/")
        ? fallbackPrefix
        : "$fallbackPrefix/";
  }

  String imgPath(name) {
    if (_fallbackPrefix != null &&
        _fallbackPrefix != prefix &&
        !_availableAssets.contains(name)) {
      return "$_fallbackPrefix$name";
    }
    return "$prefix$name";
  }
}
