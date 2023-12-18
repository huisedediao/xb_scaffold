import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';

/*
 * 自动适配网络图片或者本地图片的image
 * */
import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/xb_stateless_widget.dart';

import '../configs/color_config.dart';

// ignore: must_be_immutable
class XBImage extends XBStatelessWidget {
  dynamic img;
  final double? height;
  final double? width;
  final BoxFit? fit;
  final Widget? placeholderWidget;

  XBImage(this.img,
      {super.key, this.height, this.width, this.placeholderWidget, this.fit})
  // : assert(img != null && (img is File || img is String),
  //       "img must be File or String")
  ;

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
      return Image.file(
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
