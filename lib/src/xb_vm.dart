import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
export 'xb_sys_space.dart';
export 'xb_dialog.dart';
export 'xb_action_sheet.dart';
export 'xb_toast.dart';

class XBVM<T> extends ChangeNotifier {
  final BuildContext context;

  T get widget => context.widget as T;

  late XBWidgetState state;

  XBVM({required this.context});

  /// 已经完成创建
  @mustCallSuper
  void didCreate() {}

  /// 通知刷新
  notify() {
    try {
      notifyListeners();
      // ignore: empty_catches
    } catch (e) {}
  }

  @override
  void dispose() {
    debugPrint("$runtimeType dispose");
    super.dispose();
  }
}
