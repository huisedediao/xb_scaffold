import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBToastItem {
  OverlayEntry entry;
  GlobalKey<XBFadeWidgetState> key;
  XBToastItem({required this.entry, required this.key});
}

final List<XBToastItem> _items = [];

toast(String msg,
    {int duration = 3,
    double bottom = 150,
    Color? backgroundColor,
    TextStyle? msgStyle}) {
  toastWidget(
    bottom: bottom,
    duration: duration,
    backgroundColor: backgroundColor,
    widget: Padding(
      padding: EdgeInsets.only(
          left: spaces.gapLess,
          right: spaces.gapLess,
          top: spaces.gapLess * 0.5,
          bottom: spaces.gapLess * 0.5),
      child: Text(
        msg,
        style: msgStyle ?? const TextStyle(color: Colors.white),
      ),
    ),
  );
}

toastWidget(
    {required Widget widget,
    int duration = 3,
    double bottom = 150,
    Color? backgroundColor}) {
  try {
    _toastWidget(
        widget: widget,
        duration: duration,
        bottom: bottom,
        backgroundColor: backgroundColor);
  } catch (e) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _toastWidget(
          widget: widget,
          duration: duration,
          bottom: bottom,
          backgroundColor: backgroundColor);
    });
  }
}

_toastWidget(
    {required Widget widget,
    int duration = 3,
    double bottom = 150,
    Color? backgroundColor}) {
  _hideLast();
  final overlay = Overlay.of(xbGlobalContext);
  final GlobalKey<XBFadeWidgetState> key = GlobalKey();
  final overlayEntry = OverlayEntry(
    builder: (context) => Positioned(
      bottom: bottom,
      child: IgnorePointer(
        ignoring: true,
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
                    color: backgroundColor ?? Colors.black87,
                    child: widget,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  overlay.insert(overlayEntry);
  _items.add(XBToastItem(entry: overlayEntry, key: key));

  Future.delayed(Duration(seconds: duration)).then((value) {
    if (overlayEntry == _items.last.entry) {
      _hideLast();
    }
  });
}

_hideLast() {
  if (_items.isNotEmpty) {
    final lastItem = _items.removeLast();
    if (lastItem.key.currentState != null) {
      lastItem.key.currentState?.hide(() {
        lastItem.entry.remove();
      });
    } else {
      lastItem.entry.remove();
    }
  }
}
