import 'package:flutter/material.dart';

bool isXBFile(dynamic value) => false;

String? getXBFilePath(dynamic file) => null;

Widget buildXBFileImage({
  required dynamic file,
  double? width,
  double? height,
  BoxFit? fit,
}) {
  return const SizedBox.shrink();
}

Widget buildXBSvgFile({
  required dynamic file,
  double? width,
  double? height,
  BoxFit fit = BoxFit.contain,
  Color? color,
  Widget? placeholderWidget,
}) {
  return placeholderWidget ?? const SizedBox.shrink();
}
