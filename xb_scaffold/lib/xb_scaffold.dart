library xb_scaffold;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/configs/xb_dialog_style.dart';
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

/// 用于外部控制 dialog 样式（结构不变，仅替换各部分样式/内容）
XBDialogStyle? _xbDialogStyle;
XBDialogStyle? get xbDialogStyle => _xbDialogStyle;

/// 运行中动态设置 dialog 全局样式（如跟随深色模式），传 null 恢复框架默认
void xbSetDialogStyle(XBDialogStyle? style) {
  _xbDialogStyle = style;
}

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
  FutureOr<void> Function()? appRunner,
}) {
  XBErrorHandler.init(
    reporter: reporter,
    errorWidgetBuilder: errorWidgetBuilder,
    dumpFlutterErrorToConsole: dumpFlutterErrorToConsole,
    enableErrorWidget: enableErrorWidget,
    enablePlatformDispatcherError: enablePlatformDispatcherError,
    enableIsolateError: enableIsolateError,
  );

  if (appRunner != null) {
    runZonedGuarded(() async {
      await appRunner();
    }, (error, stackTrace) async {
      await XBErrorHandler.handle(error, stackTrace);
    });
  }
}

class XBScaffold extends StatefulWidget {
  final Widget child;

  /// 图片路径，区分主题
  final List<XBThemeConfig> themeConfigs;

  /// loading 要长什么样
  final XBLoadingBuilder? loadingBuilder;

  /// dialog 要长什么样（结构不变，仅替换各部分样式/内容）
  final XBDialogStyle? dialogStyle;

  /// toast 的背景颜色
  final Color? toastBackgroundColor;

  /// max page log len，默认 30
  final int? maxPageLogLen;

  /// 主题索引持久化读取器（可选）：返回上次保存的主题 index，未存储过返回 null。
  /// 初始化完成、主题注册后自动回灌生效。
  /// ```dart
  /// themeIndexReader: () async => prefs.getInt('theme_index'),
  /// ```
  final XBThemeIndexReader? themeIndexReader;

  /// 主题索引持久化写入器（可选）：changeTheme 时自动调用。
  /// ```dart
  /// themeIndexWriter: (index) => prefs.setInt('theme_index', index),
  /// ```
  final XBThemeIndexWriter? themeIndexWriter;

  const XBScaffold({
    required this.child,
    required this.themeConfigs,
    this.loadingBuilder,
    this.dialogStyle,
    this.toastBackgroundColor,
    this.maxPageLogLen,
    this.themeIndexReader,
    this.themeIndexWriter,
    super.key,
  });

  @override
  State<XBScaffold> createState() => _XBScaffoldState();
}

class _XBScaffoldState extends State<XBScaffold> {
  /// 初始化令牌：新一轮初始化开始后，旧一轮异步结果作废，防止旧配置覆盖新配置
  int _initToken = 0;

  @override
  void initState() {
    super.initState();
    _syncGlobalConfigs();
    _initThemes(++_initToken);
  }

  @override
  void didUpdateWidget(covariant XBScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncGlobalConfigs();
    if (!_themeConfigsEqual(widget.themeConfigs, oldWidget.themeConfigs)) {
      _initThemes(++_initToken);
    }
  }

  /// 同步全局配置（loadingBuilder / dialogStyle / toastBackgroundColor / maxPageLogLen / 主题持久化钩子）
  void _syncGlobalConfigs() {
    _xbLoadingBuilder = widget.loadingBuilder;
    _xbDialogStyle = widget.dialogStyle;
    _xbToastBackgroundColor = widget.toastBackgroundColor;
    _maxPageLogLen = widget.maxPageLogLen;
    XBThemeVM().bindIndexWriter(widget.themeIndexWriter);
  }

  /// XBThemeConfig 未重写 ==，手动按内容比较，避免父组件重建时误触发重新初始化
  bool _themeConfigsEqual(List<XBThemeConfig> a, List<XBThemeConfig> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].imgPrefix != b[i].imgPrefix ||
          a[i].primaryColor != b[i].primaryColor) {
        return false;
      }
    }
    return true;
  }

  /// 初始化各主题并注册到 XBThemeVM
  ///
  /// 异步加载 AssetManifest 期间可能又有新一轮初始化（如 themeConfigs 变更），
  /// 通过 token 判断：旧任务完成后若 token 已过期则丢弃结果。
  /// 完成时 setThemeForIndex 会触发 notifyListeners，
  /// 依赖主题的页面（needRebuildWhileAppThemeChanged）会自动重建。
  Future<void> _initThemes(int token) async {
    final configs = widget.themeConfigs;

    // 加载 AssetManifest，获取所有已声明的 asset 资源
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    if (token != _initToken) return;
    final allAssets = manifest.listAssets();

    // 为每个主题构建 XBThemeImage 并扫描可用资源
    final List<XBThemeImage> themeImages = [];
    for (int i = 0; i < configs.length; i++) {
      String imgPrefix = configs[i].imgPrefix;
      if (!imgPrefix.endsWith("/")) {
        imgPrefix = "$imgPrefix/";
      }
      final themeImage = XBThemeImage(prefix: imgPrefix);

      // 扫描该主题前缀下的所有 asset，提取相对文件名
      final Set<String> availableAssets = {};
      for (final key in allAssets) {
        if (key.startsWith(imgPrefix)) {
          availableAssets.add(key.substring(imgPrefix.length));
        }
      }
      themeImage.setAvailableAssets(availableAssets);
      themeImages.add(themeImage);
    }

    if (token != _initToken) return;

    // 非默认主题设置 fallback 为默认主题（index 0）的 imgPrefix
    if (themeImages.length > 1) {
      final defaultImgPrefix = themeImages[0].prefix;
      for (int i = 1; i < themeImages.length; i++) {
        themeImages[i].setFallbackPrefix(defaultImgPrefix);
      }
    }

    for (int i = 0; i < configs.length; i++) {
      XBThemeVM().setThemeForIndex(
        XBTheme(
          config: XBThemeConfig(
            imgPrefix: configs[i].imgPrefix,
            primaryColor: configs[i].primaryColor,
          ),
          images: themeImages[i],
        ),
        i,
      );
    }

    // 回灌持久化的主题 index（须在主题注册完成之后，避免命中越界校验）
    // 脏数据（越界/负数）静默忽略，避免历史遗留脏数据在启动时崩溃
    final reader = widget.themeIndexReader;
    if (reader != null) {
      final savedIndex = await reader();
      if (token == _initToken &&
          savedIndex != null &&
          savedIndex >= 0 &&
          savedIndex < configs.length &&
          savedIndex != XBThemeVM().themeIndex) {
        XBThemeVM().changeTheme(savedIndex);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncXBFallbackNavigatorState(context);
    return widget.child;
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
