class XBThemeImage {
  final String? prefix;

  XBThemeImage({String? prefix}) : prefix = prefix ?? "assets/images/default/";

  String imgPath(name, {String type = 'png'}) {
    return "$prefix$name.$type";
  }
}
