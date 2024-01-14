import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/xb_fade_widget.dart';

import 'xb_theme/xb_theme_mixin.dart';
import 'xb_vm.dart';

class XBVMToastItem {
  OverlayEntry entry;
  GlobalKey<XBFadeWidgetState> key;
  XBVMToastItem({required this.entry, required this.key});
}

extension XBVMToast on XBVM {
  static final List<XBVMToastItem> _items = [];

  static _hideLast() {
    if (_items.isNotEmpty) {
      final lastItem = _items.removeLast();
      lastItem.key.currentState?.hide(() {
        lastItem.entry.remove();
      });
    }
  }

  static toastWidgetStatic(
      {required BuildContext context,
      required Widget widget,
      int duration = 3,
      double bottom = 150}) {
    _hideLast();
    final overlay = Overlay.of(context);
    final GlobalKey<XBFadeWidgetState> key = GlobalKey();
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: bottom,
        child: Material(
          color: Colors.transparent,
          child: XBFadeWidget(
            key: key,
            autoShowAnimation: true,
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
      ),
    );

    overlay.insert(overlayEntry);
    _items.add(XBVMToastItem(entry: overlayEntry, key: key));

    Future.delayed(Duration(seconds: duration)).then((value) {
      if (overlayEntry == _items.last.entry) {
        _hideLast();
      }
    });
  }

  /// toast的形式展示一个widget
  toastWidget({required Widget widget, int duration = 3, double bottom = 150}) {
    toastWidgetStatic(
        context: context, widget: widget, duration: duration, bottom: bottom);
  }

  static toastStatic(String msg, BuildContext context,
      {int duration = 3, double bottom = 150}) {
    toastWidgetStatic(
      context: context,
      bottom: bottom,
      duration: duration,
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
  toast(String msg, {int duration = 3, double bottom = 150}) {
    toastStatic(msg, context, duration: duration, bottom: bottom);
  }
}
