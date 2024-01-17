import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBVMToastItem {
  OverlayEntry entry;
  GlobalKey<XBFadeWidgetState> key;
  XBVMToastItem({required this.entry, required this.key});
}

final List<XBVMToastItem> _items = [];

_hideLast() {
  if (_items.isNotEmpty) {
    final lastItem = _items.removeLast();
    lastItem.key.currentState?.hide(() {
      lastItem.entry.remove();
    });
  }
}

toastWidget({required Widget widget, int duration = 3, double bottom = 150}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _hideLast();
    final overlay = Overlay.of(xbGlobalContext);
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
                    left: spaces.gapLess,
                    right: spaces.gapLess,
                    top: spaces.gapLess * 0.5,
                    bottom: spaces.gapLess * 0.5),
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
  });
}

toast(String msg, {int duration = 3, double bottom = 150}) {
  toastWidget(
    bottom: bottom,
    duration: duration,
    widget: Padding(
      padding: EdgeInsets.only(
          left: spaces.gapLess,
          right: spaces.gapLess,
          top: spaces.gapLess * 0.5,
          bottom: spaces.gapLess * 0.5),
      child: Text(
        msg,
        style: const TextStyle(color: Colors.white),
      ),
    ),
  );
}
