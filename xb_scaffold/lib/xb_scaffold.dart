library xb_scaffold;

import 'dart:async';

import 'package:flutter/material.dart';

import 'src/xb_error/xb_error.dart';
import 'src/xb_theme/xb_theme_vm.dart';

export 'xb_scaffold_export.dart';

/// 页面展示隐藏监听
final RouteObserver<ModalRoute<void>> xbRouteObserver =
    RouteObserver<ModalRoute<void>>();

final GlobalKey<NavigatorState> _xbDefaultNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'xb_scaffold_navigator_key');
GlobalKey<NavigatorState>? _xbInjectedNavigatorKey;
NavigatorState? _xbFallbackNavigatorState;

/// XBScaffold 默认使用的 NavigatorKey
GlobalKey<NavigatorState> get xbNavigatorKey =>
    _xbInjectedNavigatorKey ?? _xbDefaultNavigatorKey;

void _bindXBNavigatorKey(GlobalKey<NavigatorState>? key) {
  if (key == null) return;
  _xbInjectedNavigatorKey = key;
}

void _syncXBFallbackNavigatorState(BuildContext context) {
  final navigator = Navigator.maybeOf(context, rootNavigator: true);
  if (navigator != null) {
    _xbFallbackNavigatorState = navigator;
  }
}

NavigatorState? get _aliveFallbackNavigatorState {
  final state = _xbFallbackNavigatorState;
  if (state != null && state.mounted) {
    return state;
  }
  return null;
}

String _buildNavigatorNotReadyMessage(String target) {
  return "XBScaffold $target is not ready.\n"
      "Fix:\n"
      "1) Use XBMaterialApp as your app root, or\n"
      "2) pass navigatorKey: xbNavigatorKey to MaterialApp/GetMaterialApp/CupertinoApp.\n"
      "3) Ensure XBScaffold is mounted before calling global APIs (push/dialog/toast/loading).";
}

NavigatorState? get xbNavigatorStateOrNull =>
    xbNavigatorKey.currentState ?? _aliveFallbackNavigatorState;

BuildContext? get xbNavigatorContextOrNull =>
    xbNavigatorKey.currentContext ?? _aliveFallbackNavigatorState?.context;

OverlayState? get xbOverlayStateOrNull =>
    xbNavigatorKey.currentState?.overlay ??
    _aliveFallbackNavigatorState?.overlay;

/// 全局 NavigatorState（根导航）
NavigatorState get xbNavigatorState {
  final state = xbNavigatorStateOrNull;
  if (state == null) {
    throw StateError(_buildNavigatorNotReadyMessage("navigator state"));
  }
  return state;
}

/// 全局 Navigator Context（用于 showDialog/showModalBottomSheet 等）
BuildContext get xbNavigatorContext {
  final context = xbNavigatorContextOrNull;
  if (context == null) {
    throw StateError(_buildNavigatorNotReadyMessage("navigator context"));
  }
  return context;
}

/// 全局 OverlayState（用于 toast/loading 等 OverlayEntry 场景）
OverlayState get xbOverlayState {
  final overlay = xbOverlayStateOrNull;
  if (overlay == null) {
    throw StateError(_buildNavigatorNotReadyMessage("overlay"));
  }
  return overlay;
}

@Deprecated("Use xbNavigatorContext instead.")
BuildContext get xbGlobalContext {
  return xbNavigatorContext;
}

@Deprecated("No longer required.")
BuildContext? tempContext;

/// 结束输入框编辑
void endEditing({BuildContext? context}) {
  if (context != null) {
    FocusScope.of(context).requestFocus(FocusNode());
    return;
  }
  final navigatorContext = xbNavigatorContextOrNull;
  if (navigatorContext != null) {
    FocusScope.of(navigatorContext).requestFocus(FocusNode());
    return;
  }
  FocusManager.instance.primaryFocus?.unfocus();
}

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
  XBErrorWidgetBuilder? errorWidgetBuilder,
  bool dumpFlutterErrorToConsole = true,
  bool enableErrorWidget = true,
  bool enablePlatformDispatcherError = true,
  bool enableIsolateError = false,
}) {
  XBErrorHandler.init(
    reporter: reporter,
    errorWidgetBuilder: errorWidgetBuilder,
    dumpFlutterErrorToConsole: dumpFlutterErrorToConsole,
    enableErrorWidget: enableErrorWidget,
    enablePlatformDispatcherError: enablePlatformDispatcherError,
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

  const XBScaffold({
    required this.child,
    required this.themeConfigs,
    this.loadingBuilder,
    this.toastBackgroundColor,
    this.maxPageLogLen,
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
    _syncXBFallbackNavigatorState(context);
    return widget.child;
  }
}

/// 初始化
Future<void> _initXBScaffold({
  required List<XBThemeConfig> configs,
}) async {
  for (int i = 0; i < configs.length; i++) {
    String imgPrefix = configs[i].imgPrefix;
    if (!imgPrefix.endsWith("/")) {
      imgPrefix = "$imgPrefix/";
    }
    XBThemeVM().setThemeForIndex(
      XBTheme(
        config: XBThemeConfig(
          imgPrefix: imgPrefix,
          primaryColor: configs[i].primaryColor,
        ),
      ),
      i,
    );
  }
}

class XBMaterialApp extends StatelessWidget {
  final GlobalKey<NavigatorState>? navigatorKey;
  final Widget? home;
  final Map<String, WidgetBuilder> routes;
  final String? initialRoute;
  final RouteFactory? onGenerateRoute;
  final InitialRouteListFactory? onGenerateInitialRoutes;
  final RouteFactory? onUnknownRoute;
  final TransitionBuilder? builder;
  final String title;
  final GenerateAppTitle? onGenerateTitle;
  final Color? color;
  final ThemeData? theme;
  final ThemeData? darkTheme;
  final ThemeMode themeMode;
  final Locale? locale;
  final Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates;
  final LocaleListResolutionCallback? localeListResolutionCallback;
  final LocaleResolutionCallback? localeResolutionCallback;
  final Iterable<Locale> supportedLocales;
  final bool debugShowCheckedModeBanner;
  final List<NavigatorObserver> navigatorObservers;
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;
  final ScrollBehavior? scrollBehavior;

  const XBMaterialApp({
    super.key,
    this.navigatorKey,
    this.home,
    this.routes = const <String, WidgetBuilder>{},
    this.initialRoute,
    this.onGenerateRoute,
    this.onGenerateInitialRoutes,
    this.onUnknownRoute,
    this.builder,
    this.title = '',
    this.onGenerateTitle,
    this.color,
    this.theme,
    this.darkTheme,
    this.themeMode = ThemeMode.system,
    this.locale,
    this.localizationsDelegates,
    this.localeListResolutionCallback,
    this.localeResolutionCallback,
    this.supportedLocales = const <Locale>[Locale('en', 'US')],
    this.debugShowCheckedModeBanner = true,
    this.navigatorObservers = const <NavigatorObserver>[],
    this.scaffoldMessengerKey,
    this.scrollBehavior,
  });

  List<NavigatorObserver> _buildObservers() {
    final observers = <NavigatorObserver>[...navigatorObservers];
    if (!observers.contains(xbRouteObserver)) {
      observers.add(xbRouteObserver);
    }
    return observers;
  }

  @override
  Widget build(BuildContext context) {
    final key = navigatorKey ?? _xbDefaultNavigatorKey;
    _bindXBNavigatorKey(key);
    return MaterialApp(
      navigatorKey: key,
      home: home,
      routes: routes,
      initialRoute: initialRoute,
      onGenerateRoute: onGenerateRoute,
      onGenerateInitialRoutes: onGenerateInitialRoutes,
      onUnknownRoute: onUnknownRoute,
      builder: builder,
      title: title,
      onGenerateTitle: onGenerateTitle,
      color: color,
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: localizationsDelegates,
      localeListResolutionCallback: localeListResolutionCallback,
      localeResolutionCallback: localeResolutionCallback,
      supportedLocales: supportedLocales,
      debugShowCheckedModeBanner: debugShowCheckedModeBanner,
      navigatorObservers: _buildObservers(),
      scaffoldMessengerKey: scaffoldMessengerKey,
      scrollBehavior: scrollBehavior,
    );
  }
}
