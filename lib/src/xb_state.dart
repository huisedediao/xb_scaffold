import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
export 'xb_sys_space_mixin.dart';

abstract class XBState<T extends StatefulWidget> extends State<T>
    with XBSysSpaceMixin {
  XBTheme get app => XBThemeVM().theme;

  static XBTheme get appStatic => XBThemeVM().theme;

  get endEditing => FocusScope.of(context).requestFocus(FocusNode());

  void pop<O extends Object?>([O? result]) {
    Navigator.of(context, rootNavigator: false).pop(result);
  }
}
