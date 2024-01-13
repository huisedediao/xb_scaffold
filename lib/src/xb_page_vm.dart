import 'dart:async';

import 'package:xb_scaffold/xb_scaffold.dart';

abstract class XBPageVM<T> extends XBVM<T> {
  XBPageVM({required super.context, bool initLoading = false})
      : _opicity = initLoading ? 1 : 0;

  bool get isLoading => _opicity > 0;

  double _opicity = 0;

  double get opacity => _opicity;

  Timer? _timer;

  showLoading() {
    _startShowTimer();
    notify();
  }

  hideLoading() {
    _startHideTimer();
    notify();
  }

  int get _animationTime => 33;

  double get _animationStep => 0.25;

  _startShowTimer() {
    _stopTimer();
    _timer = Timer.periodic(Duration(milliseconds: _animationTime), (timer) {
      _opicity += _animationStep;
      if (_opicity >= 1) {
        _opicity = 1;
        _stopTimer();
      }
      notify();
    });
  }

  _startHideTimer() {
    _stopTimer();
    _timer = Timer.periodic(Duration(milliseconds: _animationTime), (timer) {
      _opicity -= _animationStep;
      if (_opicity <= 0) {
        _opicity = 0;
        _stopTimer();
      }
      notify();
    });
  }

  _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }
}
