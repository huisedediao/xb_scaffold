import 'package:flutter/material.dart';
import 'xb_theme/xb_theme_vm.dart';
export 'xb_vm_sys_space.dart';
export 'xb_vm_dialog.dart';
export 'xb_vm_action_sheet.dart';
export 'xb_vm_toast.dart';

class XBVM<T> extends ChangeNotifier {
  XBTheme get app => XBThemeVM().theme;

  get endEditing => FocusScope.of(context).requestFocus(FocusNode());

  final BuildContext context;

  T get widget => context.widget as T;

  XBVM({required this.context});

  void pop<O extends Object?>([O? result]) {
    Navigator.of(context, rootNavigator: false).pop(result);
  }

  notify() {
    try {
      notifyListeners();
      // ignore: empty_catches
    } catch (e) {}
  }
}
