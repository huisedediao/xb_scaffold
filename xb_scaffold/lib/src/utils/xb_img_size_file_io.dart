import 'dart:io';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// key:path value:size
final Map<String, Size> _fileSizeMap = {};

/// 从File获取图片宽高（路径），仅非 Web 平台可用
Future<Size> getXBImageSizeFromFile(dynamic file) async {
  if (file is! File) return Future.value(Size.zero);
  if (await file.length() == 0) return Future.value(Size.zero);
  String key = file.path;
  if (_fileSizeMap[key] != null) {
    return _fileSizeMap[key]!;
  }
  final size = await XBImgSizeUtil.getImageSize(Image(image: XBFileImage(file)));
  _fileSizeMap[key] = size;
  return size;
}
