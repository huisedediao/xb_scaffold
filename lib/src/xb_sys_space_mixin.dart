import 'package:flutter/material.dart';

mixin XBSysSpaceMixin {
  static double _lastSafeAreaBottom = 0;
  static double _lastStateBarH = 0;

  BuildContext get context;

  get queryData {
    return MediaQuery.of(context);
  }

  get mediaQueryData => queryData;

  static getMediaQueryData(BuildContext context) => MediaQuery.of(context);

  /// 屏幕尺寸
  get screenSize => mediaQueryData.size;

  static getScreenSize(BuildContext context) => getMediaQueryData(context).size;

  /// 屏幕宽度
  get screenW => screenSize.width;

  static getScreenW(BuildContext context) => getScreenSize(context).width;

  /// 屏幕高度
  get screenH => screenSize.height;

  static getScreenH(BuildContext context) => getScreenSize(context).height;

  /// 屏幕一个点代表几个像素
  get dpr => mediaQueryData.devicePixelRatio;

  static getDpr(BuildContext context) =>
      getMediaQueryData(context).devicePixelRatio;

  /// 状态栏高度
  get stateBarH {
    //隐藏状态栏的情况会变成0
    if (_lastStateBarH < mediaQueryData.padding.top) {
      _lastStateBarH = mediaQueryData.padding.top;
    }
    return _lastStateBarH;
  }

  static getStateBarH(BuildContext context) {
    //隐藏状态栏的情况会变成0
    if (_lastStateBarH < getMediaQueryData(context).padding.top) {
      _lastStateBarH = getMediaQueryData(context).padding.top;
    }
    return _lastStateBarH;
  }

  /// navigationBar高度
  get naviBarH => kToolbarHeight;

  static getNaviBarH() => kToolbarHeight;

  /// tabbar高度
  get tabbarH => kBottomNavigationBarHeight;

  static getTabbarH() => kBottomNavigationBarHeight;

  /// （状态栏 + navigationBar）的高度
  get topBarH => stateBarH + naviBarH;

  static getTopBarH(BuildContext context) =>
      getStateBarH(context) + getNaviBarH();

  /// 除去topBarH后屏幕还剩余的高度
  get screenHWithoutTopBarH => screenH - topBarH;

  static getScreenHWithoutTopBarH(BuildContext context) =>
      getScreenH(context) - getTopBarH(context);

  /// iOS中底布安全区域的高度
  /// 全面屏手机展开键盘的时候，mediaQueryData.padding.bottom会变成0
  get safeAreaBottom {
    if (_lastSafeAreaBottom < mediaQueryData.padding.bottom) {
      _lastSafeAreaBottom = mediaQueryData.padding.bottom;
    }
    return _lastSafeAreaBottom;
  }

  static getSafeAreaBottom(BuildContext context) {
    if (_lastSafeAreaBottom < getMediaQueryData(context).padding.bottom) {
      _lastSafeAreaBottom = getMediaQueryData(context).padding.bottom;
    }
    return _lastSafeAreaBottom;
  }

  /// 1个像素的高度
  get onePixel => 1 / dpr;

  static getOnePixel(BuildContext context) => 1 / getDpr(context);
}
