library xb_scaffold;

import 'dart:async';

import 'package:flutter/material.dart';

import './src/xb_navigator_observer.dart';
import 'src/xb_error/xb_error.dart';
import 'src/xb_theme/xb_theme_vm.dart';

export 'xb_scaffold_export.dart';

/// 页面展示隐藏监听
final RouteObserver<ModalRoute<void>> xbRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// 路由栈监听
final XBNavigatorObserver _xbNavigatorObserver = XBNavigatorObserver();
XBNavigatorObserver get xbNavigatorObserver => _xbNavigatorObserver;

final StreamController<XBStackChangedEvent> _xbRouteStackStreamController =
    StreamController<XBStackChangedEvent>.broadcast();

StreamController<XBStackChangedEvent> get xbStackStreamController =>
    _xbRouteStackStreamController;

Stream<XBStackChangedEvent> get xbRouteStackStream =>
    _xbRouteStackStreamController.stream;

/// 全局 BuildContext
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

/// 用于外部控制 loading 样式
typedef XBLoadingBuilder = Widget Function(BuildContext context, String? msg);

XBLoadingBuilder? _xbLoadingBuilder;
XBLoadingBuilder? get xbLoadingBuilder => _xbLoadingBuilder;

/// toast 背景颜色
Color? _xbToastBackgroundColor;
Color? get xbToastBackgroundColor => _xbToastBackgroundColor;

/// max page log len
int? _maxPageLogLen;
int? get maxPageLogLen => _maxPageLogLen;

/// 对外暴露：初始化全局异常处理
void initXBErrorHandler({
  XBErrorReporter? reporter,
  bool dumpFlutterErrorToConsole = true,
  bool enableErrorWidget = true,
  bool enableIsolateError = false,
}) {
  XBErrorHandler.init(
    reporter: reporter,
    dumpFlutterErrorToConsole: dumpFlutterErrorToConsole,
    enableErrorWidget: enableErrorWidget,
    enableIsolateError: enableIsolateError,
  );
}

class XBScaffold extends StatefulWidget {
  final Widget child;

  /// 图片路径，区分主题
  final List<XBThemeConfig> themeConfigs;

  /// loading 要长什么样
  final XBLoadingBuilder? loadingBuilder;

  /// toast 的背景颜色
  final Color? toastBackgroundColor;

  /// max page log len，默认 30
  final int? maxPageLogLen;

  /// 页面异常时展示的组件
  final Widget? errorWidget;

  const XBScaffold({
    required this.child,
    required this.themeConfigs,
    this.loadingBuilder,
    this.toastBackgroundColor,
    this.maxPageLogLen,
    this.errorWidget,
    super.key,
  });

  @override
  State<XBScaffold> createState() => _XBScaffoldState();
}

class _XBScaffoldState extends State<XBScaffold> {
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

    return _XBSafeContainer(
      errorWidget: widget.errorWidget,
      child: widget.child,
    );
  }
}

class _XBSafeContainer extends StatelessWidget {
  final Widget child;
  final Widget? errorWidget;

  const _XBSafeContainer({
    required this.child,
    this.errorWidget,
  });

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        try {
          return child;
        } catch (e, s) {
          XBErrorHandler.handle(e, s);
          return errorWidget ??
              XBErrorView(
                message: '页面加载失败，请稍后重试',
                onRetry: () {
                  // todo
                },
              );
        }
      },
    );
  }
}

/// 初始化
Future<void> _initXBScaffold({
  required List<XBThemeConfig> configs,
}) async {
  for (int i = 0; i < configs.length; i++) {
    XBThemeVM().setThemeForIndex(
      XBTheme(
        config: XBThemeConfig(
          imgPrefix: configs[i].imgPrefix,
          primaryColor: configs[i].primaryColor,
        ),
      ),
      i,
    );
  }
}
