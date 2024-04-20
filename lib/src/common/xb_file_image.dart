import 'dart:io';
import 'package:flutter/material.dart';

class XBFileImage extends FileImage {
  final int fileSize;
  XBFileImage(File file, {double scale = 1.0})
      : fileSize = file.lengthSync(),
        super(file, scale: scale);

  @override
  int get hashCode => file.hashCode & scale.hashCode;

  @override
  // ignore: non_nullable_equals_parameter
  bool operator ==(dynamic other) {
    if (other.runtimeType != runtimeType) return false;
    final XBFileImage typedOther = other;
    return file.path == typedOther.file.path &&
        scale == typedOther.scale &&
        fileSize == typedOther.fileSize;
  }
}
