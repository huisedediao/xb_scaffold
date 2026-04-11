import 'dart:async';

import 'package:example/choose_page.dart';
import 'package:example/pages/error_test_page.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  /// 1. 先初始化全局异常处理
  initXBErrorHandler(
    reporter: (error, stackTrace) async {
      final errMsg = '$error\n$stackTrace';
      debugPrint(errMsg);
      XBLogsUtil.writeText(errMsg
          .replaceAll('\n', '<br>')
          .replaceAll('<asynchronous suspension>', ''));
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
  );

  /// 2. Zone 兜底
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const MyApp());
  }, (error, stackTrace) async {
    await XBErrorHandler.handle(error, stackTrace);
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color.fromARGB(255, 76, 27, 162)),
        useMaterial3: true,
      ),
      navigatorObservers: [xbNavigatorObserver, xbRouteObserver],
      home: XBScaffold(themeConfigs: [
        XBThemeConfig(
          primaryColor: Color.fromARGB(255, 88, 18, 13),
          imgPrefix: "assets/images",
        ),
        XBThemeConfig(
            primaryColor: Color.fromARGB(255, 21, 123, 164),
            imgPrefix: "assets/images")
      ], child: const ChoosePage()),
    );
  }
}
