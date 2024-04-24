import 'dart:async';

import './xb_refresh_task.dart';
export 'xb_refresh_task.dart';

class XBRefreshTasKUtil {
  final Duration duration;

  XBRefreshTask? _task;
  Timer? _timer;

  XBRefreshTasKUtil({
    required this.duration,
  });

  refresh(XBRefreshTask task) {
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
