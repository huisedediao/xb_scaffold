import 'package:example/xb_widget_test.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() async {
  XBDioConfig.init(baseUrl: "https://www.baidu.com/");
  runApp(const MyApp());
}

/*
使用ListView 。滚动时 AppBar 改变颜色问题:
MaterialApp(
    theme: ThemeData(
        appBarTheme: AppBarTheme(scrolledUnderElevation: 0.0)
    )
)
AppBar(
    scrolledUnderElevation: 0.0
)
*/
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // appBarTheme: AppBarTheme(scrolledUnderElevation: 0.0),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      navigatorObservers: [xbRouteObserver],
      home: const XBScaffold(
          imgPrefixs: ["assets/images/default/", "assets/images/custom/"],
          child: MyHomePage(title: 'Flutter Demo Home Page')),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  void initState() {
    super.initState();
    xbRouteStackStream.listen((event) {
      print("栈发生改变");
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: const XBWidgetTest(),
    );
  }
}
