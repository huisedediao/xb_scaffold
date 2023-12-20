import 'package:flutter/material.dart';

mixin XBSysSpaceMixin {
  static double _lastSafeAreaBottom = 0;
  static double _lastStateBarH = 0;

  BuildContext get context;

  get queryData {
    return MediaQuery.of(context);
  }

  get mediaQueryData => queryData;

  /// 屏幕尺寸
  get screenSize => mediaQueryData.size;

  /// 屏幕宽度
  get screenW => screenSize.width;

  /// 屏幕高度
  get screenH => screenSize.height;

  /// 屏幕一个点代表几个像素
  get dpr => mediaQueryData.devicePixelRatio;

  /// 状态栏高度
  get stateBarH {
    //隐藏状态栏的情况会变成0
    if (_lastStateBarH < mediaQueryData.padding.top) {
      _lastStateBarH = mediaQueryData.padding.top;
    }
    return _lastStateBarH;
  }

  /// navigationBar高度
  get naviBarH => kToolbarHeight;

  /// tabbar高度
  get tabbarH => kBottomNavigationBarHeight;

  /// （状态栏 + navigationBar）的高度
  get topBarH => stateBarH + naviBarH;

  /// 除去topBarH后屏幕还剩余的高度
  get screenHWithoutTopBarH => screenH - topBarH;

  /// iOS中底布安全区域的高度
  /// 全面屏手机展开键盘的时候，mediaQueryData.padding.bottom会变成0
  get safeAreaBottom {
    if (_lastSafeAreaBottom < mediaQueryData.padding.bottom) {
      _lastSafeAreaBottom = mediaQueryData.padding.bottom;
    }
    return _lastSafeAreaBottom;
  }

  /// 1个像素的高度
  get onePixel => 1 / dpr;
}
