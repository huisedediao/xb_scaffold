import 'dart:async';

import '../xb_task/xb_task.dart';
export '../xb_task/xb_task.dart';

class XBRefreshTasKUtil {
  final Duration duration;

  XBTask? _task;
  Timer? _timer;

  XBRefreshTasKUtil({
    required this.duration,
  });

  refresh(XBTask task) {
    _task = task;
    _startTimer();
  }

  _startTimer() {
    _stopTimer();
    _timer = Timer(duration, () {
      if (_task != null) {
        _task!.execute(_task!.params);
      }
      _stopTimer();
    });
  }

  _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  dispose() {
    _stopTimer();
  }
}
