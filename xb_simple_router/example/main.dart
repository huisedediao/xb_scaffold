import 'package:flutter/material.dart';
import 'package:xb_simple_router/xb_simple_router.dart';

void main() {
  runApp(const RouterExampleApp());
}

class RouterExampleApp extends StatelessWidget {
  const RouterExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: xbSimpleNavigatorKey,
      navigatorObservers: [
        xbSimpleNavigatorObserver,
        xbSimpleRouteObserver,
      ],
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('xb_simple_router example')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => push(const DetailPage()),
          child: const Text('Push detail page'),
        ),
      ),
    );
  }
}

class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detail')),
      body: const Center(
        child: ElevatedButton(
          onPressed: pop,
          child: Text('Pop'),
        ),
      ),
    );
  }
}
