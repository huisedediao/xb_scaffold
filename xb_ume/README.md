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

## Widget locator

The locator prefers source locations from the application by default. To
inspect the implementation of selected third-party UI packages, add their
pubspec package names to `locatorInspectablePackages`:

```dart
const XBUmeConfig(
  locatorInspectablePackages: <String>{
    'flutter_quill',
    'cached_network_image',
  },
);
```

When a tapped widget was created by a configured package, the locator shows
the nearest source location in that package and its nearest located ancestor
from the same package. If there is no same-package ancestor, it falls back to
the normal application-first parent resolution.

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

## IDE 跳转（点击行尾箭头定位源码）

Locator 选中组件后，展开气泡中的链条行 / picked / parent 行**行尾有一个箭头按钮，点击即可**在本机 IDE 打开对应源码行列，并自动复制 `path:line:column` 到剪贴板（兑底）。需要一次性安装本机守护脚本：

```bash
cd /path/to/your/app   # 依赖 xb_ume 的项目目录
flutter pub get
dart run xb_ume:ide --install          # macOS：注册 LaunchAgent（登录自启 + 崩溃自拉起）
dart run xb_ume:ide --uninstall        # 卸载
```

安装后日常零操作：

- `flutter run` 或 IDE 运行按钮启动的调试会话会被自动发现并接入：daemon 轮询扫描本机回环监听端口，探测 `GET /getVM` 返回 `type=VM` 的 VM service（覆盖 flutter 工具代理、adb forward / hdc fport、桌面直连等各种暴露方式，无需依赖设备日志或 mDNS）；
- 同一台电脑多台设备同时调试均支持；App 重启自动重连，会话断开自动清理；
- IDE 自动检测顺序（VS Code 系 fork，均支持 `-g file:line:col`）：Qoder（`qodercn`）→ Cursor（`cursor`）→ Trae（`trae`）→ Windsurf（`windsurf`）→ VS Code（`code`）→ Android Studio（`jetbrains://` 深链 / 可执行文件）；未安装 shell 命令时 macOS 下自动回退到 /Applications 内 app 内置 CLI；可用 `--ide qodercn|cursor|trae|windsurf|code|androidStudio` 显式指定；
- 不安装脚本时点击箭头仍可用（仅复制路径到剪贴板）；release 模式无 VM service，事件发送会静默降级。

手动模式（自动发现不可用时的兑底）：

```bash
dart run xb_ume:ide --uri <vm-service-ws-uri>   # URI 取自 flutter run 控制台输出
dart run xb_ume:ide --daemon                    # 前台运行守护进程（不注册自启）
```
