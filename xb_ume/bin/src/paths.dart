// xb_ume 数据目录与跨 bin 脚本共用的路径工具。
library;

import 'dart:io';

/// xb_ume 数据目录：$XB_UME_HOME 优先，否则 $HOME/.xb_ume_ide。
String xbUmeHome() {
  final env = Platform.environment['XB_UME_HOME'];
  if (env != null && env.trim().isNotEmpty) return env.trim();
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;
  return '$home/.xb_ume_ide';
}
