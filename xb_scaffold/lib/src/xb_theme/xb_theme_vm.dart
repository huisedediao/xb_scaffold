import 'package:flutter/material.dart';
import 'xb_theme.dart';
export 'xb_theme.dart';

class XBThemeVM extends ChangeNotifier {
  static final XBThemeVM _singleton = XBThemeVM._internal();

  factory XBThemeVM() {
    return _singleton;
  }

  XBThemeVM._internal();

  final Map<int, XBTheme> _themeMap = {};

  int _themeIndex = 0;

  XBTheme get theme {
    var theme = _themeMap[_themeIndex];
    if (theme == null) {
      theme = XBTheme();
      _themeMap[_themeIndex] = theme;
    }
    return theme;
  }

  int get themeIndex => _themeIndex;

  changeTheme(int themeIndex) {
    _themeIndex = themeIndex;
    notifyListeners();
  }

  setThemeForIndex(XBTheme theme, int themeIndex) async {
    _themeMap[themeIndex] = theme;
    notifyListeners();
  }
}
