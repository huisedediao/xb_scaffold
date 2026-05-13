import 'dart:async';

import 'package:flutter/foundation.dart';

class XBUmeNotice {
  const XBUmeNotice({
    required this.id,
    required this.message,
  });

  final int id;
  final String message;
}

class XBUmeNoticeService {
  XBUmeNoticeService._();

  static final XBUmeNoticeService instance = XBUmeNoticeService._();

  final ValueNotifier<XBUmeNotice?> current = ValueNotifier<XBUmeNotice?>(null);

  Timer? _dismissTimer;
  int _seed = 0;

  void show(
    String message, {
    Duration duration = const Duration(milliseconds: 1800),
  }) {
    _dismissTimer?.cancel();
    _seed += 1;
    current.value = XBUmeNotice(id: _seed, message: message);
    _dismissTimer = Timer(duration, () {
      clear();
    });
  }

  void clear() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    current.value = null;
  }
}
