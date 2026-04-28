import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'dart:typed_data';

class XBImgSizeUtil {
  /// key:url value:size
  static final Map<String, Size> _map = {};

  /// 从url获取图片宽高
  static Future<Size> getImageSizeFromUrl(String url) async {
    if (url.isEmpty) return Future.value(Size.zero);
    if (_map[url] != null) {
      return _map[url]!;
    }
    try {
      final size = await getImageSize(Image.network(url));
      _map[url] = size;
      return size;
    } catch (e) {
      return Future.value(Size.zero);
    }
  }

  /// 从asset获取图片宽高
  static Future<Size> getImageSizeFromAsset(String assetPath) async {
    if (assetPath.isEmpty) return Future.value(Size.zero);
    if (_map[assetPath] != null) {
      return _map[assetPath]!;
    }
    final size = await getImageSize(Image.asset(assetPath));
    _map[assetPath] = size;
    return size;
  }

  /// 从File获取图片宽高（路径）
  static Future<Size> getImageSizeFromFile(File file) async {
    if (await file.length() == 0) return Future.value(Size.zero);
    String key = file.path;
    if (_map[key] != null) {
      return _map[key]!;
    }
    final size = await getImageSize(Image(image: XBFileImage(file)));
    _map[key] = size;
    return size;
  }

  /// 从File获取图片宽高（二进制数据）
  static Future<Size> getImageSizeFromMemory(Uint8List bytes) async {
    if (bytes.isEmpty) return Future.value(Size.zero);
    String key = "${bytes.first}${bytes.length}${bytes.hashCode}${bytes.last}";
    if (_map[key] != null) {
      return _map[key]!;
    }
    final size = await getImageSize(Image.memory(bytes));
    _map[key] = size;
    return size;
  }

  /// 从url获取图片宽高
  static Future<Size> getImageSize(Image image) async {
    try {
      ImageStreamListener? listener;
      final size = await _getImageSize(
        image: image,
        onListenerInited: (value) {
          listener = value;
        },
      );
      // 移除监听器，释放资源
      image.image.resolve(const ImageConfiguration()).removeListener(listener!);
      return size;
    } catch (e) {
      return Future.value(Size.zero);
    }
  }

/*
注意需要移除监听：
参考：
    Image image = Image.network(url);
    ImageStreamListener? listener;
    final size = await getImageSize(
      image: image,
      onListenerInited: (value) {
        listener = value;
      },
    );
    // 移除监听器，释放资源
    image.image.resolve(const ImageConfiguration()).removeListener(listener!);
**/
  static Future<Size> _getImageSize(
      {required Image image,
      required ValueChanged<ImageStreamListener> onListenerInited}) {
    try {
      Completer<Size> completer = Completer<Size>();
      ImageStreamListener listener = ImageStreamListener(
        (ImageInfo info, bool synchronousCall) {
          var myImage = info.image;
          Size size = Size(myImage.width.toDouble(), myImage.height.toDouble());
          completer.complete(size);
        },
      );
      onListenerInited(listener);
      image.image.resolve(const ImageConfiguration()).addListener(listener);

      return completer.future;
    } catch (e) {
      return Future.value(Size.zero);
    }
  }
}
