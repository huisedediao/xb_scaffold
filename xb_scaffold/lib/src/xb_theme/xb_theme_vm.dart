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

  /// 当前显示的主题的编号
  int _themeIndex = 0;
  int get themeIndex => _themeIndex;

  /// 获取主题
  XBTheme get theme {
    var theme = _themeMap[_themeIndex];
    if (theme == null) {
      theme = XBTheme();
      _themeMap[_themeIndex] = theme;
    }
    return theme;
  }

  /// 修改主题
  changeTheme(int themeIndex) {
    _themeIndex = themeIndex;
    notifyListeners();
  }

  /// 设置主题
  /// theme：主题
  /// themeIndex：主题编号
  setThemeForIndex(XBTheme theme, int themeIndex) {
    _themeMap[themeIndex] = theme;
    notifyListeners();
  }
}
