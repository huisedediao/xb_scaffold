import 'package:flutter/material.dart';

mixin XBSysSpaceMixin {
  static double _lastSafeAreaBottom = 0;
  static double _lastStateBarH = 0;

  BuildContext get context;

  get queryData {
    return MediaQuery.of(context);
  }

  get mediaQueryData => queryData;

  get screenSize => mediaQueryData.size;

  get screenW => screenSize.width;

  get screenH => screenSize.height;

  get dpr => mediaQueryData.devicePixelRatio;

  get stateBarH {
    //隐藏状态栏的情况会变成0
    if (_lastStateBarH < mediaQueryData.padding.top) {
      _lastStateBarH = mediaQueryData.padding.top;
    }
    return _lastStateBarH;
  }

  get naviBarH => kToolbarHeight;

  get tabbarH => kBottomNavigationBarHeight;

  get topBarH => stateBarH + naviBarH;

  get screenHWithoutTopBarH => screenH - topBarH;

  //全面屏手机展开键盘的时候，mediaQueryData.padding.bottom会变成0
  get safeAreaBottom {
    if (_lastSafeAreaBottom < mediaQueryData.padding.bottom) {
      _lastSafeAreaBottom = mediaQueryData.padding.bottom;
    }
    return _lastSafeAreaBottom;
  }

  get onePixel => 1 / dpr;
}
