import 'package:flutter/material.dart';

import 'xb_theme/xb_theme_mixin.dart';
import 'xb_vm.dart';

extension XBVMToast on XBVM {
  static toastWidgetStatic(
      {required BuildContext context,
      required Widget widget,
      int duration = 3,
      double bottom = 100}) {
    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: bottom,
        child: Material(
          color: Colors.transparent,
          child: Container(
            // color: Colors.green,
            alignment: Alignment.center,
            width: MediaQuery.of(context).size.width,
            child: Padding(
              padding: EdgeInsets.only(
                  left: XBThemeMixin.appStatic.spaces.gapLess,
                  right: XBThemeMixin.appStatic.spaces.gapLess,
                  top: XBThemeMixin.appStatic.spaces.gapLess * 0.5,
                  bottom: XBThemeMixin.appStatic.spaces.gapLess * 0.5),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  color: Colors.black87,
                  child: widget,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(overlayEntry);

    Future.delayed(Duration(seconds: duration)).then((value) {
      overlayEntry.remove();
    });
  }

  /// toast的形式展示一个widget
  toastWidget({required Widget widget, int duration = 3}) {
    toastWidgetStatic(context: context, widget: widget);
  }

  static toastStatic(String msg, BuildContext context, {int duration = 3}) {
    toastWidgetStatic(
      context: context,
      widget: Padding(
        padding: EdgeInsets.only(
            left: XBThemeMixin.appStatic.spaces.gapLess,
            right: XBThemeMixin.appStatic.spaces.gapLess,
            top: XBThemeMixin.appStatic.spaces.gapLess * 0.5,
            bottom: XBThemeMixin.appStatic.spaces.gapLess * 0.5),
        child: Text(
          msg,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  /// 展示一个toast
  /// time,秒
  toast(String msg, {int duration = 3}) {
    toastStatic(msg, context);
  }
}
