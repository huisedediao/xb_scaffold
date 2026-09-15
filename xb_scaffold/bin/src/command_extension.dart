part of xb_cli;

void _writeThemeExtensionFiles(String basePath) {
  final normalizedBase = (basePath.endsWith('/') || basePath.endsWith('\\'))
      ? basePath.substring(0, basePath.length - 1)
      : basePath;
  final targetDirPath = '$normalizedBase/$_themeExtensionDirName';
  final dir = Directory(targetDirPath);

  final files = <String, String>{
    'app_theme_color.dart': """import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeColor on XBThemeColor {
  /// 添加需要的颜色
  Color get exampleColor => const Color.fromARGB(255, 172, 72, 72);
}
""",
    'app_theme_font_size.dart':
        """import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeFontSize on XBThemeFontSize {
  /// 添加需要的字号
  double get s50 => 50;
}
""",
    'app_theme_font_family.dart':
        """import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeFontFamily on XBThemeFontFamily {
  /// 添加需要的字体族
  // String get pingFang => 'PingFang SC';
}
""",
    'app_theme_font_weights.dart': """import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeFontWeight on XBThemeFontWeight {
  /// 添加需要的字重
  FontWeight get thin100 => FontWeight.w100;
}
""",
    'app_theme_image.dart': """import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeImage on XBThemeImage {
  // 添加需要的图片路径，使用脚本生成
}
""",
    'app_theme_space.dart': """import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeSpace on XBThemeSpace {
  /// 添加需要的间距
  double get j4 => 4;
}
""",
  };

  // 文件级判断：已存在的文件保留不动，仅补齐缺失的文件
  dir.createSync(recursive: true);
  for (final entry in files.entries) {
    final file = File('${dir.path}/${entry.key}');
    if (file.existsSync()) {
      stderr.writeln('Target file already exists, skip: ${file.path}');
      continue;
    }
    file.writeAsStringSync(_withOuterBlankLines(entry.value));
    stdout.writeln('Generated: ${file.path}');
  }
}
