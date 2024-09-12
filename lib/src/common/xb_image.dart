import 'dart:io';
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/xb_file_image.dart';
import 'package:xb_scaffold/src/xb_sys_config.dart';
import '../configs/xb_color_config.dart';
import 'dart:ui' as ui;

/*
 * 自动适配网络图片或者本地图片的image
 * */
class XBImage extends StatelessWidget {
  /// 图片，可以是文件、Uint8List、url、asset路径
  final dynamic img;
  final double? height;
  final double? width;
  final BoxFit? fit;
  final Widget? placeholderWidget;
  final Widget? errWidget;
  final bool isInPackage;

  const XBImage(this.img,
      {super.key,
      this.height,
      this.width,
      this.placeholderWidget,
      this.errWidget,
      this.isInPackage = false,
      this.fit});

  @override
  Widget build(BuildContext context) {
    return _create();
  }

  Widget _def() {
    if (placeholderWidget != null) {
      return placeholderWidget!;
    } else {
      return Container();
    }
  }

  Widget _create() {
    if (img == "" || img == null) {
      return _def();
    }

    if (img is ui.Image) {
      return RawImage(
        image: img,
        width: width,
        height: height,
        fit: fit,
      );
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

    if (img is String) {
      if (isInPackage) {
        return Image(
          image: AssetImage(img),
          width: width,
          height: height,
          fit: fit,
          gaplessPlayback: true,
        );
      }
      if (img.startsWith("http")) {
        if (isHarmony) {
          return Image.network(
            img,
            width: width,
            height: height,
            fit: fit,
            gaplessPlayback: true,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) {
                return child; // 当图片加载完成时返回图片
              }
              return placeholderWidget ?? Container();
            },
            errorBuilder: (context, error, stackTrace) {
              return errWidget ??
                  Container(
                    color: viewBG,
                  );
            },
          );
        }
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
          errorWidget: (context, url, error) =>
              errWidget ??
              Container(
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

    return _def();
  }
}
