import 'package:flutter/material.dart';
import 'xb_theme/xb_theme_vm.dart';

abstract class XBState<T extends StatefulWidget> extends State<T> {
  XBTheme get app => XBThemeVM().theme;

  get endEditing => FocusScope.of(context).requestFocus(FocusNode());
}
