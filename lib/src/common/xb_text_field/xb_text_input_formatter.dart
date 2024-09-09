import 'dart:io';

import 'package:flutter/services.dart';

/// 限制只能输入数字
class XBNumberTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    // 清除掉非数字的内容
    String text = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    return newValue.copyWith(
        text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

/// 限制最大最小值
class XBNumberLimitTextInputFormatter extends TextInputFormatter {
  final int min;
  final int max;
  XBNumberLimitTextInputFormatter({required this.min, required this.max});

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) {
      return newValue;
    }
    int? parsedValue = int.tryParse(newValue.text);

    if (parsedValue == null) {
      // 如果无法解析为数字，则返回旧的输入值
      return oldValue;
    }

    // 检查输入是否超出范围
    if (parsedValue < min) {
      parsedValue = min;
    } else if (parsedValue > max) {
      parsedValue = max;
    }

    String newText = parsedValue.toString();

    return newValue.copyWith(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length));
  }
}

/// 去除头尾的空格
class XBTrimTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    //ios完成输入或者是安卓
    if (!newValue.composing.isValid || Platform.isAndroid) {
      final newValueTrim = newValue.text.trim();
      return TextEditingValue(
        text: newValueTrim,
        selection: (oldValue.text.trim().length == newValueTrim.length)
            ? oldValue.selection
            : newValue.selection,
      );
    } else {
      return newValue;
    }
  }
}

/// 限制最大输入字数
class XBMaxLengthTextInputFormatter extends TextInputFormatter {
  final int maxLength;
  XBMaxLengthTextInputFormatter(this.maxLength);

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.length <= maxLength) {
      return newValue;
    } else {
      return oldValue;
    }
  }
}
