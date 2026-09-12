import 'package:flutter/services.dart';

/// Web 平台无法直接退出进程，通知浏览器退出当前页面
void exitApp() => SystemNavigator.pop();
