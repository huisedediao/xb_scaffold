import 'dart:io';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';
import 'common/xb_legacy_pop_scope.dart';

class XBRootWidget extends XBWidget<XBRootWidgetVM> {
  final Widget child;
  final String? willExitTip;

  /// param 1 : context
  /// param 2 : notify function address
  final VoidCallback onLoaded;
  final VoidCallback? onAppPaused;
  final VoidCallback? onAppResumed;
  const XBRootWidget(
      {required this.child,
      required this.onLoaded,
      this.willExitTip,
      this.onAppPaused,
      this.onAppResumed,
      super.key});

  @override
  generateVM(BuildContext context) {
    return XBRootWidgetVM(context: context);
  }

  @override
  Widget buildWidget(BuildContext context) {
    final vm = vmOf(context);
    return XBLegacyPopScope(onWillPop: vm.onWillPop, child: child);
  }
}

class XBRootWidgetVM extends XBVM<XBRootWidget> with WidgetsBindingObserver {
  XBRootWidgetVM({required super.context}) {
    widget.onLoaded();
    WidgetsBinding.instance.addObserver(this);
  }

  DateTime? lastWillPop;

  bool paused = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive: // 处于这种状态的应用程序应该假设它们可能在任何时候暂停。
        xbError("AppLifecycleState.inactive");
        break;
      case AppLifecycleState.resumed: // 应用程序可见，前台
        {
          if (paused) {
            xbError("应用程序进入前台");
            paused = false;
            widget.onAppResumed?.call();
          }
          break;
        }
      case AppLifecycleState.paused: // 应用程序不可见，后台
        {
          xbError("应用程序进入后台");
          paused = true;
          widget.onAppPaused?.call();
          break;
        }
      case AppLifecycleState.detached: // 申请将暂时暂停
        xbError("AppLifecycleState.detached");
        break;
      case AppLifecycleState.hidden:
        xbError("AppLifecycleState.hidden");
    }
  }

  Future<bool> onWillPop() async {
    if (lastWillPop == null ||
        DateTime.now().difference(lastWillPop!) > const Duration(seconds: 2)) {
      lastWillPop = DateTime.now();
      toast(widget.willExitTip ?? "再按一次退出应用");
      return false;
    } else {
      exit(0);
      // return true;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
