import 'package:flutter/material.dart';

mixin XBOperaMixin {
  BuildContext get context;

  /// 用新页面替换当前页
  void replace(Widget newPage) {
    pop();
    push(newPage);
  }

  /// 进入新页面
  Future<T?> push<T extends Object?>(Widget newPage) {
    return Navigator.push(
        context, MaterialPageRoute<T>(builder: (context) => newPage));
  }

  /// 回到上一页
  void pop<O extends Object?>([O? result]) {
    Navigator.of(context, rootNavigator: false).pop(result);
  }

  /// 结束编辑
  get endEditing => FocusScope.of(context).requestFocus(FocusNode());
}
