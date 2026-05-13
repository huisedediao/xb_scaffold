# xb_ume

`xb_ume` is a pure Flutter in-app debug toolkit inspired by `flutter_ume`.

It ships with:

- Floating debug entry and plugin panel host
- Console logs and error capture
- Route timeline via navigator observer
- Frame timing and jank metrics
- Network timeline with multi-framework adapters
- Widget tree inspector
- Widget locator (pick on screen and show file/line/column)
- Device/environment info panel
- Storage inspector with pluggable adapters
- Snapshot persistence

## Install

```yaml
dependencies:
  xb_ume: ^0.1.0
```

## Quick Start

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xb_ume/xb_ume.dart';

void main() {
  XBUmeBinding.ensureInitialized(
    config: XBUmeConfig(
      enable: kDebugMode,
      persistenceEnabled: true,
    ),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      builder: XBUme.appBuilder(),
      navigatorObservers: [XBUme.routeObserver],
      home: const Scaffold(body: Center(child: Text('Hello xb_ume'))),
    );
  }
}
```

## Network adapters

### Dio

```dart
dio.interceptors.add(XBUmeDioInterceptor());
```

### package:http

```dart
final client = XBUmeHttpClient(http.Client());
```

### Custom framework

```dart
final requestId = XBUmeNetworkReporter.begin(
  method: 'GET',
  url: Uri.parse('https://api.example.com/items'),
);

try {
  // execute request...
  XBUmeNetworkReporter.complete(
    requestId,
    statusCode: 200,
    responseBody: '{"ok":true}',
  );
} catch (e, s) {
  XBUmeNetworkReporter.fail(requestId, error: e, stackTrace: s);
}
```

## Storage adapters

Register any key/value source:

```dart
XBUme.registerStorageAdapter(
  XBUmeMapStorageAdapter(id: 'session', data: sessionMap),
);
```

## Example

See [`example/lib/main.dart`](example/lib/main.dart).
