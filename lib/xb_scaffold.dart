library xb_scaffold;

import 'dart:async';

import 'package:flutter/material.dart';
import './src/xb_navigator_observer.dart';
import 'src/xb_theme/xb_theme_vm.dart';

export 'xb_scaffold_export.dart';

/// 页面展示隐藏监听
final RouteObserver<ModalRoute<void>> xbRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// 路由栈监听
XBNavigatorObserver _xbNavigatorObserver = XBNavigatorObserver();
XBNavigatorObserver get xbNavigatorObserver => _xbNavigatorObserver;
final StreamController<XBStackChangedEvent> _xbRouteStackStreamController =
    StreamController<XBStackChangedEvent>.broadcast();
StreamController<XBStackChangedEvent> get xbStackStreamController =>
    _xbRouteStackStreamController;
Stream<XBStackChangedEvent> get xbRouteStackStream =>
    _xbRouteStackStreamController.stream;

/// 全局BuildContext
late BuildContext _xbGlobalContext;
bool _isInitXBScaffold = false;
BuildContext get xbGlobalContext {
  if (_isInitXBScaffold) {
    return _xbGlobalContext;
  }
  assert(tempContext != null, "请初始化XBScaffold或者设置tempContext");
  return tempContext!;
}

BuildContext? tempContext;

/// 结束输入框编辑
void endEditing({BuildContext? context}) =>
    FocusScope.of(context ?? xbGlobalContext).requestFocus(FocusNode());

/// 用于外部控制loading要长什么样
typedef XBLoadingBuilder = Widget Function(BuildContext context, String? msg);
XBLoadingBuilder? _xbLoadingBuilder;
XBLoadingBuilder? get xbLoadingBuilder => _xbLoadingBuilder;

/// toast的背景颜色
Color? _xbToastBackgroundColor;
Color? get xbToastBackgroundColor => _xbToastBackgroundColor;

/// max page log len
int? _maxPageLogLen;
int? get maxPageLogLen => _maxPageLogLen;

class XBScaffold extends StatefulWidget {
  final Widget child;

  /// 图片路径，区分主题
  final List<XBThemeConfig> themeConfigs;

  /// loading要长什么样
  final XBLoadingBuilder? loadingBuilder;

  /// toast的背景颜色
  final Color? toastBackgroundColor;

  /// max page log len, 默认30
  final int? maxPageLogLen;

  const XBScaffold(
      {required this.child,
      required this.themeConfigs,
      this.loadingBuilder,
      this.toastBackgroundColor,
      this.maxPageLogLen,
      super.key});

  @override
  State<XBScaffold> createState() => _MyWidgetState();
}

class _MyWidgetState extends State<XBScaffold> {
  @override
  void initState() {
    super.initState();
    _xbLoadingBuilder = widget.loadingBuilder;
    _xbToastBackgroundColor = widget.toastBackgroundColor;
    _maxPageLogLen = widget.maxPageLogLen;
    _initXBScaffold(configs: widget.themeConfigs);
  }

  @override
  Widget build(BuildContext context) {
    _xbGlobalContext = context;
    _isInitXBScaffold = true;
    return widget.child;
  }
}

/// 初始化
/// imgPrefixs图片的前缀，每个主题使用的图片不同，如果没有设置，则使用"assets/images/default/"
_initXBScaffold({required List<XBThemeConfig> configs}) async {
  for (int i = 0; i < configs.length; i++) {
    XBThemeVM().setThemeForIndex(
        XBTheme(
            config: XBThemeConfig(
                imgPrefix: configs[i].imgPrefix,
                primaryColor: configs[i].primaryColor)),
        i);
  }
  return Future.value(1);
}
