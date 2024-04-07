import 'dart:io';
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/xb_file_image.dart';
import '../configs/color_config.dart';

/*
 * 自动适配网络图片或者本地图片的image
 * */
class XBImage extends StatelessWidget {
  /// 图片，可以是文件、url、asset路径
  final dynamic img;
  final double? height;
  final double? width;
  final BoxFit? fit;
  final Widget? placeholderWidget;

  const XBImage(this.img,
      {super.key, this.height, this.width, this.placeholderWidget, this.fit});

  @override
  Widget build(BuildContext context) {
    return _create();
  }

  Widget _create() {
    if (img == "" || img == null) {
      if (placeholderWidget != null) {
        return placeholderWidget!;
      } else {
        return Container();
      }
    }

    if (img is File) {
      return Image(
        image: XBFileImage(img),
        width: width,
        height: height,
        fit: fit,
        gaplessPlayback: true,
      );
    }

    if (img is Uint8List) {
      return Image.memory(
        img,
        width: width,
        height: height,
        fit: fit,
        gaplessPlayback: true,
      );
    }

    if (img.startsWith("http")) {
      return CachedNetworkImage(
        fadeInDuration: const Duration(milliseconds: 0),
        fadeOutDuration: const Duration(milliseconds: 0),
        width: width,
        height: height,
        fit: fit,
        imageUrl: img,
        placeholder: (context, url) {
          return placeholderWidget ?? Container();
        },
        errorWidget: (context, url, error) => Container(
          color: viewBG,
        ),
      );
    } else {
      return Image.asset(
        img,
        width: width,
        height: height,
        fit: fit,
        gaplessPlayback: true,
      );
    }
  }
}
