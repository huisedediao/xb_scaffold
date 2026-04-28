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
    color: color,
    placeholderBuilder: (context) => placeholderWidget ?? Container(),
  );
}
