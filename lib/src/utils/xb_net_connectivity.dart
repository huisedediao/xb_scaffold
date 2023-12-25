import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:xb_scaffold/src/utils/xb_enents.dart';

class XBNetConnectivity {
  late StreamSubscription<ConnectivityResult> _subscription;
  bool _isNetAvailable = false;
  bool _isListening = false;

  /// 私有构造函数
  XBNetConnectivity._privateConstructor() {
    startListen();
  }

  /// 单例实例
  static final XBNetConnectivity _instance =
      XBNetConnectivity._privateConstructor();

  /// 获取单例实例的方法
  static XBNetConnectivity get instance => _instance;

  startListen() {
    if (_isListening) return;
    _isListening = true;
    _subscription = Connectivity()
        .onConnectivityChanged
        .listen((ConnectivityResult result) {
      _handleNewRet(result);
    });
  }

  stopListen() {
    _subscription.cancel();
    _isListening = false;
  }

  /// 网络是否可用
  bool get isNetAvailable => _isNetAvailable;

  /// 从设计上来说，只在启动(后台唤起)app时调用，用于获取初始状态，后续状态更新，会通过监听进行改变
  Future<bool> getNetState() async {
    final result = await (Connectivity().checkConnectivity());
    _handleNewRet(result);
    return _isNetAvailable;
  }

  _handleNewRet(ConnectivityResult result) {
    // Got a new connectivity status!
    bool newState = true;
    // 处理网络状态变化的逻辑
    if (result == ConnectivityResult.none) {
      // 没有网络连接
      newState = false;
    } else if (result == ConnectivityResult.wifi) {
      // 使用WiFi连接
    } else if (result == ConnectivityResult.mobile) {
      // 使用移动数据连接
    }
    if (newState != _isNetAvailable) {
      _isNetAvailable = newState;
      xbEventBus.fire(EventNetStateChanged());
    }
  }
}
