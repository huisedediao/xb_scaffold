import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

bool isXBFile(dynamic value) => value is File;

String? getXBFilePath(dynamic file) {
  if (file is File) return file.path;
  return null;
}

Widget buildXBFileImage({
  required dynamic file,
  double? width,
  double? height,
  BoxFit? fit,
}) {
  return Image(
    image: XBFileImage(file as File),
    width: width,
    height: height,
    fit: fit,
    gaplessPlayback: true,
  );
}

Widget buildXBSvgFile({
  required dynamic file,
  double? width,
  double? height,
  BoxFit fit = BoxFit.contain,
  Color? color,
  Widget? placeholderWidget,
}) {
  return SvgPicture.file(
    file as File,
    width: width,
    height: height,
    fit: fit,
    // flutter_svg 已废弃 color 参数，其内部实现等价于
    // ColorFilter.mode(color, BlendMode.srcIn)（color 为 null 时不做着色）
    colorFilter: color == null ? null : ColorFilter.mode(color, BlendMode.srcIn),
    placeholderBuilder: (context) => placeholderWidget ?? Container(),
  );
}
