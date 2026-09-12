import 'package:flutter/material.dart';

/// Web 平台不支持 File，恒返回 Size.zero
Future<Size> getXBImageSizeFromFile(dynamic file) async {
  return Size.zero;
}
