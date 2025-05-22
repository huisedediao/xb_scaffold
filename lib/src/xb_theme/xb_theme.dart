import 'package:flutter/material.dart';

import 'xb_theme_color.dart';
import 'xb_theme_font_size.dart';
import 'xb_theme_font_weight.dart';
import 'xb_theme_image.dart';
import 'xb_theme_space.dart';

export 'xb_theme_color.dart';
export 'xb_theme_font_size.dart';
export 'xb_theme_font_weight.dart';
export 'xb_theme_image.dart';
export 'xb_theme_space.dart';

class XBThemeConfig {
  final Color primaryColor;
  final String imagesPath;

  XBThemeConfig({required this.primaryColor, required this.imagesPath});
}

/// 要替换原来主题中的内容，继承相应的类，在创建主题的时候传入
/// 要新增原来主题中没有的内容，需通过extension来实现

class XBTheme {
  final XBThemeColor colors;
  final XBThemeSpace spaces;
  final XBThemeFontSize fontSizes;
  final XBThemeFontWeight fontWeights;
  final XBThemeImage images;

  XBTheme({XBThemeConfig? config})
      : colors = XBThemeColor(primaryColor: config?.primaryColor),
        spaces = XBThemeSpace(),
        fontSizes = XBThemeFontSize(),
        fontWeights = XBThemeFontWeight(),
        images = XBThemeImage(prefix: config?.imagesPath);
}
