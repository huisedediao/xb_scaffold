import 'package:flutter/material.dart';

class XBTextSizeUtil {
  /// 计算文字大小
  static Size textSize(
      {required String text,
      required TextStyle textStyle,
      required double maxWidth,
      int maxLines = 10000}) {
    return spanSize(
        textSpan: TextSpan(text: text, style: textStyle),
        maxWidth: maxWidth,
        maxLines: maxLines);
  }

  /// 计算文字大小
  static Size spanSize(
      {required TextSpan textSpan,
      required double maxWidth,
      int maxLines = 10000}) {
    TextPainter textPainter = TextPainter(
      text: textSpan,
      maxLines: maxLines,
      textDirection: TextDirection.ltr,
    );

    textPainter.layout(minWidth: 0, maxWidth: maxWidth);
    return textPainter.size;
  }
}
