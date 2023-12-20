import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/xb_opera_mixin.dart';
import 'xb_sys_space_mixin.dart';
import 'xb_theme/xb_theme_mixin.dart';
export 'xb_sys_space_mixin.dart';
export 'xb_vm_dialog.dart';
export 'xb_vm_action_sheet.dart';
export 'xb_vm_toast.dart';

class XBVM<T> extends ChangeNotifier
    with XBSysSpaceMixin, XBThemeMixin, XBOperaMixin {
  @override
  final BuildContext context;

  T get widget => context.widget as T;

  XBVM({required this.context});

  /// 通知刷新
  notify() {
    try {
      notifyListeners();
      // ignore: empty_catches
    } catch (e) {}
  }
}
