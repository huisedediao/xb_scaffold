import 'xb_theme_vm.dart';

mixin XBThemeMixin {
  static XBTheme get appStatic => XBThemeVM().theme;

  XBTheme get app => XBThemeVM().theme;
  XBThemeColor get colors => app.colors;
  XBThemeSpace get spaces => app.spaces;
  XBThemeFontSize get fontSizes => app.fontSizes;
  XBThemeFontWeight get fontWeights => app.fontWeights;
  XBThemeImage get images => app.images;
}
