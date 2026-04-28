class XBThemeImage {
  final String? prefix;

  XBThemeImage({String? prefix}) : prefix = prefix ?? "assets/images/default/";

  String imgPath(name) {
    return "$prefix$name";
  }
}
