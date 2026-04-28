import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'xb_image_file_adapter.dart';

import '../../configs/xb_color_config.dart';

/*
 * 自动适配网络图片或者本地图片的image
 * */
class XBImage extends StatelessWidget {
  /// 图片，可以是文件、Uint8List、url、asset路径
  /// Web 不支持 File
  final dynamic img;
  final double? height;
  final double? width;
  final BoxFit? fit;
  final Widget? placeholderWidget;
  final Widget? errWidget;
  final bool isInPackage;
  final Color? svgColor;

  const XBImage(this.img,
      {super.key,
      this.height,
      this.width,
      this.placeholderWidget,
      this.errWidget,
      this.isInPackage = false,
      this.svgColor,
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

    if (isXBFile(img)) {
      final path = getXBFilePath(img);
      if (path != null && _isSvgPath(path)) {
        return buildXBSvgFile(
          file: img,
          width: width,
          height: height,
          fit: fit ?? BoxFit.contain,
          color: svgColor,
          placeholderWidget: placeholderWidget,
        );
      }

      return buildXBFileImage(
        file: img,
        width: width,
        height: height,
        fit: fit,
      );
    }

    if (img is Uint8List) {
      if (_isSvgBytes(img)) {
        return _svgMemory(img);
      }
      return Image.memory(
        img,
        width: width,
        height: height,
        fit: fit,
        gaplessPlayback: true,
      );
    }

    if (img is String) {
      final svgData = _svgData(img);
      if (svgData != null) {
        return _svgString(svgData);
      }

      if (isInPackage) {
        if (_isSvgPath(img)) {
          return _svgAsset(img);
        }
        return Image(
          image: AssetImage(img),
          width: width,
          height: height,
          fit: fit,
          gaplessPlayback: true,
        );
      }
      if (img.startsWith("http")) {
        if (_isSvgPath(img)) {
          return _svgNetwork(img);
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
          errorWidget: (context, url, error) => _error(error),
        );
      } else {
        if (_isSvgPath(img)) {
          return _svgAsset(img);
        }
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

  Widget _svgAsset(String assetName) {
    return SvgPicture.asset(
      assetName,
      width: width,
      height: height,
      fit: fit ?? BoxFit.contain,
      color: svgColor,
      placeholderBuilder: (context) => placeholderWidget ?? Container(),
    );
  }

  Widget _svgMemory(Uint8List bytes) {
    return SvgPicture.memory(
      bytes,
      width: width,
      height: height,
      fit: fit ?? BoxFit.contain,
      color: svgColor,
      placeholderBuilder: (context) => placeholderWidget ?? Container(),
    );
  }

  Widget _svgNetwork(String url) {
    return SvgPicture.network(
      url,
      width: width,
      height: height,
      fit: fit ?? BoxFit.contain,
      color: svgColor,
      placeholderBuilder: (context) => placeholderWidget ?? Container(),
    );
  }

  Widget _svgString(String data) {
    return SvgPicture.string(
      data,
      width: width,
      height: height,
      fit: fit ?? BoxFit.contain,
      color: svgColor,
      placeholderBuilder: (context) => placeholderWidget ?? Container(),
    );
  }

  Widget _error(Object error) {
    return errWidget ??
        Container(
          color: viewBG,
          alignment: Alignment.center,
          child: Text(
            error.toString(),
            style: TextStyle(fontSize: fontSizes.s12, color: Colors.grey),
          ),
        );
  }

  bool _isSvgPath(String value) {
    final path = Uri.tryParse(value)?.path ?? value;
    return path.toLowerCase().endsWith('.svg');
  }

  bool _isSvgBytes(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final length = bytes.length < 512 ? bytes.length : 512;
    final prefix = utf8.decode(
      bytes.sublist(0, length),
      allowMalformed: true,
    );
    return _isSvgXml(prefix);
  }

  String? _svgData(String value) {
    if (_isSvgXml(value)) {
      return value;
    }

    final lowerValue = value.toLowerCase();
    if (!lowerValue.startsWith('data:image/svg+xml')) {
      return null;
    }

    final commaIndex = value.indexOf(',');
    if (commaIndex < 0) {
      return null;
    }

    final metadata = value.substring(0, commaIndex).toLowerCase();
    final data = value.substring(commaIndex + 1);
    if (metadata.contains(';base64')) {
      return utf8.decode(base64.decode(data), allowMalformed: true);
    }
    return Uri.decodeFull(data);
  }

  bool _isSvgXml(String value) {
    final data = value.trimLeft();
    return data.startsWith('<svg') ||
        (data.startsWith('<?xml') && data.contains('<svg'));
  }
}
