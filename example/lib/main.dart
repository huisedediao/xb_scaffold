import 'package:example/choose_page.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  runApp(const MyApp());
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
      navigatorObservers: [xbNavigatorObserver, xbRrouteObserver],
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
