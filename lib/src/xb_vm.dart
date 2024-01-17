import 'package:flutter/material.dart';
export 'xb_sys_space.dart';
export 'xb_dialog.dart';
export 'xb_action_sheet.dart';
export 'xb_toast.dart';

class XBVM<T> extends ChangeNotifier {
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
