# XBEchoLogger

可复用的远程日志上报组件，从 BCloud 项目中抽取。支持 Flutter / iOS / Android。

## 核心功能

- **队列管理**：内存队列 + 持久化存储，应用被杀后数据不丢失
- **串行消费**：互斥锁保证日志按序发送，不并发
- **延迟启动**：避免与初始化流程争抢资源
- **离线缓存**：断网时日志缓存在本地，恢复后自动发送
- **错误去重**：相同错误在单次会话中只上报一次
- **跨平台**：Dart（Flutter）+ iOS（ObjC）+ Android（Java）三端均可用

## 快速开始

### 1. 复制组件到项目

将整个 `xb_echo_logger` 目录复制到你的 Flutter 项目根目录。

### 2. 添加依赖

在你的 `pubspec.yaml` 中添加：

```yaml
dependencies:
  xb_echo_logger:
    path: xb_echo_logger
```

### 3. 初始化

```dart
import 'package:xb_echo_logger/xb_echo_logger.dart';

void main() {
  // 在应用启动时初始化
  XBEchoLogger.init(
    config: EchoConfig(
      echoHost: 'http://144.168.61.190:3000',  // Echo 服务器地址
      appId: 'com.example.app',                 // 应用标识
      userIdProvider: () => myUser.id,          // 注入 userId
      sidProvider: () => mySession.sid,         // 注入 sid
      isDebugMode: kDebugMode,
      errorReceivers: ['admin@example.com'],    // 错误通知邮箱
    ),
  );
  runApp(MyApp());
}
```

### 4. 使用

```dart
// 普通日志上报（走队列）
XBEchoLogger.instance.echo(content: '用户点击了按钮');
XBEchoLogger.instance.echo(content: '页面加载完成');

// 错误上报（直接发送，带去重）
XBEchoLogger.instance.err(content: '接口返回 500');

// 检查服务器连通性
bool ok = await XBEchoLogger.instance.checkConnectivity();

// 查看队列中待发送数量
print('待发送: ${XBEchoLogger.instance.pendingCount}');
```

## EchoConfig 配置项

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `echoHost` | String | 是 | Echo 服务器地址 |
| `appId` | String | 是 | 应用标识 |
| `userIdProvider` | Function | 否 | 注入 userId |
| `sidProvider` | Function | 否 | 注入 sid |
| `appVersionProvider` | Function | 否 | 注入版本号 |
| `deviceProvider` | Function | 否 | 注入设备型号 |
| `systemVersionProvider` | Function | 否 | 注入系统版本 |
| `udidProvider` | Function | 否 | 注入设备 UDID |
| `environmentProvider` | Function | 否 | 注入环境标识 |
| `pageLogProvider` | Function | 否 | 注入页面导航日志 |
| `isDebugMode` | bool | 否 | 默认 false |
| `queueMaxSize` | int | 否 | 默认 1000 |
| `startDelay` | Duration | 否 | 默认 2 秒 |
| `storage` | EchoStorage | 否 | 持久化存储实现 |
| `customSender` | Function | 否 | 自定义 HTTP 发送器 |
| `errorReceivers` | List\<String\> | 否 | 错误通知邮箱列表 |
| `localLogWriter` | Function | 否 | 本地日志写入回调 |

## 使用 SharedPreferences 持久化

```dart
import 'package:shared_preferences/shared_preferences.dart';

class SPEchoStorage implements EchoStorage {
  final SharedPreferences _prefs;
  SPEchoStorage(this._prefs);

  @override
  Future<String?> getString(String key) async => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }
}

// 使用
final prefs = await SharedPreferences.getInstance();
XBEchoLogger.init(
  config: EchoConfig(
    echoHost: '...',
    appId: '...',
    storage: SPEchoStorage(prefs),
  ),
);
```

## 使用 Dio 替代内置 HTTP 客户端

```dart
import 'package:dio/dio.dart';

final dio = Dio();

XBEchoLogger.init(
  config: EchoConfig(
    echoHost: 'http://144.168.61.190:3000',
    appId: 'com.example.app',
    customSender: (infoMap) async {
      try {
        final resp = await dio.post(
          '${echoHost}/echo',
          data: infoMap,
        );
        return resp.statusCode == 200;
      } catch (_) {
        return false;
      }
    },
  ),
);
```

## iOS 原生端使用

```objc
#import "XBEchoLogger.h"

// 初始化
[XBEchoLogger initWithHost:@"http://144.168.61.190:3000"
                     appId:@"com.example.app"
                  isDebug:NO];

// 上报日志（走队列）
[XBEchoLogger.shared echo:@{
    @"content": @"原生端日志",
    @"userId": @"123",
}];

// 错误上报（直接发送，带去重）
[XBEchoLogger.shared err:@{
    @"content": @"原生端异常",
    @"userId": @"123",
}];
```

## Android 原生端使用

```java
import com.xb.echo.logger.XBEchoLogger;

// 初始化（在 Application.onCreate 中）
XBEchoLogger.init(context, "http://144.168.61.190:3000", "com.example.app", false);

// 上报日志（走队列）
JSONObject info = new JSONObject();
info.put("content", "原生端日志");
info.put("userId", "123");
XBEchoLogger.getInstance().echo(info);

// 错误上报
XBEchoLogger.getInstance().err(info);
```

## 架构

```
echo(content:) / err(content:)
        |
+-------+--------+
|                |
v                v
echo()         err()
(走队列)       (直接发送 + 去重)
|                |
v                v
EchoQueue      HTTP POST (/errCatch)
| (串行消费)
v
EchoHttpClient.post()
|
v
Echo 服务器 (/echo)
```

## 队列机制详解

1. `init()` 从持久化存储恢复未发送的日志
2. 延迟 2 秒后设置 `_canExecute = true`，开始消费
3. 消费是串行的：每次只发一条，等 HTTP 响应（成功或失败）后再发下一条
4. `addTask()` 同时写入内存队列和持久化存储
5. 发送失败不重试，继续处理下一条（避免阻塞队列）
