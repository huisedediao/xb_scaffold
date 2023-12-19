import 'package:flutter/material.dart';

mixin XBOperaMixin {
  BuildContext get context;

  void pop<O extends Object?>([O? result]) {
    Navigator.of(context, rootNavigator: false).pop(result);
  }

  get endEditing => FocusScope.of(context).requestFocus(FocusNode());
}
