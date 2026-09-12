import 'package:flutter/material.dart';

/// Web 平台不支持 File 图片，保留 API 形状，构造/使用时抛出异常
class XBFileImage extends ImageProvider<XBFileImage> {
  final dynamic file;
  final double scale;

  XBFileImage(this.file, {this.scale = 1.0});

  @override
  Future<XBFileImage> obtainKey(ImageConfiguration configuration) {
    throw UnsupportedError('XBFileImage is not supported on web');
  }

  @override
  bool operator ==(Object other) =>
      other is XBFileImage && file == other.file && scale == other.scale;

  @override
  int get hashCode => Object.hash(file, scale);

  @override
  String toString() => 'XBFileImage(web unsupported)';
}
