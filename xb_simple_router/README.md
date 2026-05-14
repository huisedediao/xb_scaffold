# xb_simple_router

`xb_simple_router` provides a lightweight, injectable routing abstraction for Flutter.

- Navigator mode with global helper methods (`push`, `pop`, `replace`, `popToRoot`)
- Route stack observer (`xbSimpleNavigatorObserver`, `xbSimpleRouteStackStream`)
- Driver injection (`configureXBRouteDriver`) for custom routing engines
- Optional go_router adapter (`configureXBGoRouter`)

## Install

```yaml
dependencies:
  xb_simple_router: ^0.1.0
```

## Quick Start (Navigator)

```dart
import 'package:flutter/material.dart';
import 'package:xb_simple_router/xb_simple_router.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => push(const DetailPage()),
          child: const Text('Go Detail'),
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
      body: Center(
        child: ElevatedButton(
          onPressed: pop,
          child: const Text('Back'),
        ),
      ),
    );
  }
}
```

## Example

See [`example/main.dart`](example/main.dart) for a runnable demo.
