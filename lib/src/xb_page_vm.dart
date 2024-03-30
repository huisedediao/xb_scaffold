// ignore_for_file: empty_catches

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBPageVM<T> extends XBVM<T> with XBLifeCycleMixin {
  XBPageVM({required super.context}) {
    if ((widget as XBPage).needInitLoading()) {
      _isShowLoadingWidget = true;
    }
    _addStackListen();
  }

  _addStackListen() {
    _stackSubscription = xbRouteStackStream.listen((event) {
      handleStackChanged(event: event, widget: widget as Widget);
    });
  }

  late StreamSubscription _stackSubscription;

  bool _isShowLoadingWidget = false;

  bool get isShowLoadingWidget => _isShowLoadingWidget;

  GlobalKey<XBFadeWidgetState>? _loadingWidgetFadeKey;

  GlobalKey<XBFadeWidgetState> get loadingWidgetFadeKey {
    _loadingWidgetFadeKey ??= GlobalKey();
    return _loadingWidgetFadeKey!;
  }

  void back<O extends Object?>([O? result]) {
    pop(result);
  }

  bool get needShowLoadingWidget => (widget as XBPage).needLoading();

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
    if (needShowLoadingWidget) {
      if (loadingWidgetFadeKey.currentState == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showLoading();
        });
        return;
      }
      _isShowLoadingWidget = true;
      notify();

      loadingWidgetFadeKey.currentState?.show();
    }
  }

  hideLoading() {
    try {
      if (needShowLoadingWidget) {
        loadingWidgetFadeKey.currentState?.hide(() {
          try {
            _isShowLoadingWidget = false;
            notify();
          } catch (e) {}
        });
      }
    } catch (e) {}
  }

  @override
  void dispose() {
    _stackSubscription.cancel();
    super.dispose();
  }

  /// -------------------- function --------------------
  /// 即将pop
  onWillPop() {
    if (Platform.isAndroid) {
      return _androidOnWillPop;
    } else {
      if ((widget as XBPage).needIosGestureBack(this) && _canLoadingPop()) {
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
      isShowLoadingWidget == false ||
      (widget as XBPage).needResponseNavigationBarLeftWhileLoading();
}
