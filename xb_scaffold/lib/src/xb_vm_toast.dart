import 'package:flutter/material.dart';

import 'xb_vm.dart';

extension XBVMToast on XBVM {
  toastWidget(Widget widget, {int duration = 2}) {
    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: 50.0 + safeAreaBottom,
        child: Material(
          color: Colors.transparent,
          child: Container(
            // color: Colors.green,
            alignment: Alignment.center,
            width: MediaQuery.of(context).size.width,
            child: Padding(
              padding: EdgeInsets.only(
                  left: app.spaces.leftLess,
                  right: app.spaces.leftLess,
                  top: app.spaces.j6,
                  bottom: app.spaces.j6),
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

  /// time,秒
  toast(String msg, {int duration = 2}) {
    toastWidget(Padding(
      padding: EdgeInsets.only(
          left: app.spaces.leftLess,
          right: app.spaces.leftLess,
          top: app.spaces.j6,
          bottom: app.spaces.j6),
      child: Text(
        msg,
        style: const TextStyle(color: Colors.white),
      ),
    ));
  }
}
