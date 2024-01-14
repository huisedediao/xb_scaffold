import 'dart:async';

import 'package:xb_scaffold/xb_scaffold.dart';

abstract class XBPageVM<T> extends XBVM<T> {
  XBPageVM({required super.context, bool initLoading = false})
      : _loadingOpicity = initLoading ? 1 : 0;

  bool get isLoading => _loadingOpicity > 0;

  double _loadingOpicity = 0;

  double get loadingOpacity => _loadingOpicity;

  Timer? _loadingAnimationTimer;

  showLoading() {
    _startShowLoadingTimer();
    notify();
  }

  hideLoading() {
    _startHideLoadingTimer();
    notify();
  }

  int get _loadingAnimationTime => 33;

  double get _loadingAnimationStep => 0.25;

  _startShowLoadingTimer() {
    _stopLoadingTimer();
    _loadingAnimationTimer =
        Timer.periodic(Duration(milliseconds: _loadingAnimationTime), (timer) {
      _loadingOpicity += _loadingAnimationStep;
      if (_loadingOpicity >= 1) {
        _loadingOpicity = 1;
        _stopLoadingTimer();
      }
      notify();
    });
  }

  _startHideLoadingTimer() {
    _stopLoadingTimer();
    _loadingAnimationTimer =
        Timer.periodic(Duration(milliseconds: _loadingAnimationTime), (timer) {
      _loadingOpicity -= _loadingAnimationStep;
      if (_loadingOpicity <= 0) {
        _loadingOpicity = 0;
        _stopLoadingTimer();
      }
      notify();
    });
  }

  _stopLoadingTimer() {
    _loadingAnimationTimer?.cancel();
    _loadingAnimationTimer = null;
  }

  @override
  void dispose() {
    _stopLoadingTimer();
    super.dispose();
  }
}
