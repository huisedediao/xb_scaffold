import 'package:example/choose_page.dart';
import 'package:example/pages/error_test_page.dart';
import 'package:example/xb_test_ume_plugin.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:xb_simple_router/xb_simple_router.dart';
import 'package:xb_ume/xb_ume.dart';

void main() {
  /// 1. 先初始化全局异常处理
  initXBErrorHandler(
    reporter: (error, stackTrace) async {
      final errMsg = '$error\n$stackTrace';
      xbError(errMsg);
    },
    errorWidgetBuilder: (context, details, routeName) {
      final normalizedRouteName =
          routeName?.replaceFirst('/', '') ?? 'UnknownRoute';
      if (normalizedRouteName == 'ErrorTestPage') {
        return XBErrorView(
          error: details.exception,
          stackTrace: details.stack,
          message: 'ErrorTestPage 发生异常',
          retryText: '刷新当前页',
          onRetry: () {
            replace(const ErrorTestPage());
          },
          backText: '返回上一页',
          onBack: () {
            if (Navigator.of(context).canPop()) {
              pop();
            } else {
              popToRoot();
            }
          },
        );
      }

      return XBErrorView(
        error: details.exception,
        stackTrace: details.stack,
        message: '$normalizedRouteName 页面发生异常',
        retryText: '回到首页',
        onRetry: () {
          popToRoot();
        },
        backText: '返回上一页',
        onBack: () {
          if (Navigator.of(context).canPop()) {
            pop();
          } else {
            popToRoot();
          }
        },
      );
    },
    dumpFlutterErrorToConsole: true,
    enableErrorWidget: true,
    enableIsolateError: true,
    appRunner: () async {
      WidgetsFlutterBinding.ensureInitialized();
      XBUmeBinding.ensureInitialized(
        config: const XBUmeConfig(
          enable: kDebugMode,
          enablePerformance: false,
          enableDevice: false,
          enableInspector: false,
          enableRoute: false,
          persistenceEnabled: true,
        ),
        extraPlugins: <XBUmePlugin>[
          XBTestUmePlugin(),
        ],
      );
      XBUme.registerStorageAdapter(
        XBUmeMapStorageAdapter(
          id: 'example_memory_store',
          data: <String, dynamic>{
            'env': 'dev',
            'version': '1.0.0+1',
            'sample_token': 'demo-token',
          },
          allowWrite: true,
        ),
      );
      runApp(const MyApp());
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      navigatorKey: xbSimpleNavigatorKey,
      builder: XBUme.appBuilder(),
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color.fromARGB(255, 76, 27, 162)),
        useMaterial3: true,
      ),
      navigatorObservers: [
        xbSimpleNavigatorObserver,
        xbSimpleRouteObserver,
        xbRouteObserver,
        XBUme.routeObserver,
      ],
      home: XBScaffold(themeConfigs: [
        XBThemeConfig(
          primaryColor: const Color.fromARGB(255, 88, 18, 13),
          imgPrefix: "assets/images",
        ),
        XBThemeConfig(
            primaryColor: const Color.fromARGB(255, 21, 123, 164),
            imgPrefix: "assets/images_dark")
      ], child: const ChoosePage()),
    );
  }
}
