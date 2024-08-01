import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBTimer {
  /// 跟随vm生命周期
  final XBVM? listeningVM;
  XBTimer({this.listeningVM});

  Timer? _timer;

  void once({required Duration duration, required VoidCallback onTick}) {
    cancel();
    _timer = Timer(duration, () {
      _timer = null;
      if (listeningVM != null && listeningVM!.disposed) {
        return;
      }
      onTick();
    });
  }

  void repeat({required Duration duration, required VoidCallback onTick}) {
    cancel();
    _timer = Timer.periodic(duration, (timer) {
      if (listeningVM != null && listeningVM!.disposed) {
        cancel();
        return;
      }
      onTick();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
