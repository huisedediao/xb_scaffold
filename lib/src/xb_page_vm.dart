// ignore_for_file: empty_catches

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBPageVM<T> extends XBVM<T> {
  XBPageVM({required super.context}) {
    if ((widget as XBPage).needInitLoading()) {
      _isLoading = true;
    }
  }

  bool _isLoading = false;

  bool get isLoading => _isLoading;

  GlobalKey<XBFadeWidgetState>? _fadeKey;

  GlobalKey<XBFadeWidgetState> get fadeKey {
    _fadeKey ??= GlobalKey();
    return _fadeKey!;
  }

  Widget? back<O extends Object?>([O? result]) {
    return pop(result);
  }

  bool get needLoading => (widget as XBPage).needLoading();

  showLoading() {
    try {
      _showLoading();
    } catch (e) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showLoading();
      });
    }
  }

  _showLoading() {
    if (needLoading) {
      _isLoading = true;
      notify();

      fadeKey.currentState?.show();
    }
  }

  hideLoading() {
    try {
      if (needLoading) {
        fadeKey.currentState?.hide(() {
          try {
            _isLoading = false;
            notify();
          } catch (e) {}
        });
      }
    } catch (e) {}
  }

  /// -------------------- function --------------------
  /// 即将pop
  onWillPop() {
    if (Platform.isAndroid) {
      return _androidOnWillPop;
    } else {
      if ((widget as XBPage).needIosGestureBack() && _canLoadingPop()) {
        return null;
      } else {
        return _iosOnWillPop;
      }
    }
  }

  /// ios如果用WillPopScope的onWillPop不为null，则返回手势失效，可以用这个控制iOS是否能够返回
  /// 返回结果无影响，因为只要设置了就不能滑动返回
  Future<bool> _iosOnWillPop() async {
    return false;
  }

  /*
   * 只有 安卓 的 手势返回 操作，这个方法才生效
   * 如果需要控制iOS的滑动返回，在NeedIosGestureUtil中配置
   * */
  Future<bool> _androidOnWillPop() async {
    return !isShowGoabolLoading &&
        (widget as XBPage).onAndroidPhysicalBack(this) &&
        _canLoadingPop();
  }

  /// loading是否允许返回
  bool _canLoadingPop() =>
      isLoading == false ||
      (widget as XBPage).needResponseNavigationBarLeftWhileLoading();
}
