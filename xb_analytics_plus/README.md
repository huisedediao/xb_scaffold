# xb_analytics_plus

`xb_analytics_plus` 是一个面向 `XBScaffold` 生态的跨平台埋点库。  
它提供统一事件模型、异步队列、批量落盘、多 Sink 扇出、导出能力和内置调试页。

## 1. 设计目标

1. 独立包，可单独发布到 `pub.dev`。
2. 不改业务代码结构，快速接入。
3. 写入链路尽量非阻塞，降低对 UI 的影响。
4. 同时支持多输出通道（调试、内存、本地持久化、业务自定义上传）。
5. 内置脱敏与采样能力，降低数据风险与体积。

## 2. 平台支持与持久化策略

1. Android、iOS、Windows、macOS、Linux：使用 `path_provider` + 文件（JSONL）持久化。
2. Web：使用 `localStorage` 持久化（通过条件导入隔离实现）。

说明：`path_provider` 官方不支持 Web，所以 Web 端不会走 `path_provider`。

## 3. 安装

```yaml
dependencies:
  xb_analytics_plus: ^0.1.0
```

如果是当前仓库多包本地联调：

```yaml
dependencies:
  xb_analytics_plus:
    path: ../xb_analytics_plus
```

## 4. 快速开始

```dart
import 'package:xb_analytics_plus/xb_analytics_plus.dart';

Future<void> main() async {
  await initXBTrack(
    XBTrackConfig(
      appVersion: '1.0.0+1',
      enableConsoleSink: true,
      enableMemorySink: true,
      enableLocalStoreSink: true,
      flushBatchSize: 20,
      flushInterval: const Duration(seconds: 1),
      commonParamsProvider: () => {
        'tenantId': '1001',
        'abGroup': 'A',
      },
      onShareRequested: (content) async {
        // 由业务自己接入分享/复制/上传工单能力
      },
    ),
  );

  xbSetTrackUser('user_001');
  xbSetTrackPage('HomePage');

  xbTrack('home_open');
  xbTrack('order_submit_click', params: {'orderId': 'A100'});
}
```

## 5. 核心数据流

`collect -> sanitize -> sample -> queue -> flush(batch) -> sinks`

1. `xbTrack()` 只负责进入内存队列。
2. 达到批次阈值或定时器触发时批量 flush。
3. 同一批事件并行分发到已注册的 sinks。

## 6. 对外接口总览（函数级）

### 6.1 初始化与生命周期

| 接口 | 作用 | 参数 | 返回 |
| --- | --- | --- | --- |
| `initXBTrack(XBTrackConfig config)` | 初始化埋点系统，注册 sinks/store，启动 flush 定时器 | `config` 配置对象 | `Future<void>` |
| `closeXBTrack({bool flushBeforeClose = true})` | 关闭埋点系统，释放资源 | `flushBeforeClose` 关闭前是否先 flush | `Future<void>` |
| `xbFlushTrack()` | 手动立即 flush 队列 | 无 | `Future<void>` |

### 6.2 事件上报

| 接口 | 作用 | 参数 | 返回 |
| --- | --- | --- | --- |
| `xbTrack(String event, {Map<String,dynamic>? params, String? pageName, Map<String,dynamic>? commonParams})` | 上报业务事件主入口 | `event` 事件名，`params` 事件参数，`pageName` 页面名，`commonParams` 本次附加公共参数 | `void` |
| `xbTrackError(Object error, StackTrace? stackTrace, {String event = 'app_error', Map<String,dynamic>? extra})` | 上报异常事件 | `error`、`stackTrace`、`event` 自定义错误事件名、`extra` 附加字段 | `Future<void>` |

### 6.3 上下文控制

| 接口 | 作用 | 参数 | 返回 |
| --- | --- | --- | --- |
| `xbSetTrackUser(String userId)` | 设置当前用户 ID（后续事件自动带上） | `userId` | `void` |
| `xbClearTrackUser()` | 清空当前用户 ID | 无 | `void` |
| `xbSetTrackPage(String? pageName)` | 设置当前页面上下文 | `pageName` | `void` |
| `xbSetTrackCommonParamsProvider(XBTrackCommonParamsProvider? provider)` | 设置动态公共参数 provider | `provider` 回调，可返回租户、门店、AB 等上下文 | `void` |

### 6.4 本地读取与导出

| 接口 | 作用 | 参数 | 返回 |
| --- | --- | --- | --- |
| `xbReadTrackLocalLatest({int limit = 100, int offset = 0})` | 分页读取本地最新事件 | `limit` 每页条数，`offset` 偏移量 | `Future<List<XBTrackEvent>>` |
| `xbExportTrackAsJson({int? limit})` | 导出 JSON（可限制最近 N 条） | `limit` 可空 | `Future<String>` |
| `xbExportTrackAsText({int? limit})` | 导出逐行文本（JSONL 风格） | `limit` 可空 | `Future<String>` |
| `xbShareTrackExport({int? limit})` | 触发分享回调（由 `onShareRequested` 执行） | `limit` 可空 | `Future<void>` |
| `xbClearTrackLocal()` | 清空本地缓存（内存 + store） | 无 | `Future<void>` |

### 6.5 自动事件 Helper（供框架接线）

| 接口 | 作用 | 事件名 |
| --- | --- | --- |
| `xbTrackPageView(String pageName, {Map<String,dynamic>? params})` | 页面曝光 | `page_view` |
| `xbTrackPageHide(String pageName, {Map<String,dynamic>? params})` | 页面被覆盖/隐藏 | `page_hide` |
| `xbTrackPageLeave(String pageName, {required int durationMs, Map<String,dynamic>? params})` | 页面离开（含时长） | `page_leave` |
| `xbTrackAppForeground({Map<String,dynamic>? params})` | 进入前台 | `app_foreground` |
| `xbTrackAppBackground({Map<String,dynamic>? params})` | 进入后台 | `app_background` |
| `xbTrackTap(String trackId, {Map<String,dynamic>? params})` | 通用点击事件 | `tap` |

## 7. 核心类型与接口（类级）

### 7.1 `XBTrackEvent`

统一事件对象，关键字段：

1. `eventId`：事件唯一 ID。
2. `event`：事件名。
3. `eventTimeMs`：毫秒时间戳。
4. `sessionId`：会话 ID。
5. `userId`：用户 ID（可空）。
6. `pageName`：页面名（可空）。
7. `appVersion`：应用版本（可空）。
8. `platform`：平台标识。
9. `schemaVersion`：埋点协议版本。
10. `params`：业务参数。
11. `commonParams`：公共参数。

### 7.2 `XBTrackSink`

自定义输出通道接口：

```dart
abstract class XBTrackSink {
  Future<void> onEvent(XBTrackEvent event);
  Future<void> onEvents(List<XBTrackEvent> events);
  Future<void> close();
}
```

适用场景：

1. 自定义 HTTP 上报。
2. 写数据库。
3. 转发到日志系统。

### 7.3 `XBTrackStore`

本地持久化接口：

```dart
abstract class XBTrackStore {
  Future<void> appendMany(List<XBTrackEvent> events);
  Future<List<XBTrackEvent>> readLatest({int limit = 100, int offset = 0});
  Future<List<XBTrackEvent>> readAll();
  Future<int> count();
  Future<int> approximateBytes();
  Future<void> clear();
  Future<void> close();
}
```

### 7.4 `XBTrackExporter`

导出接口：

```dart
abstract class XBTrackExporter {
  Future<String> exportAsJson({int? limit});
  Future<String> exportAsText({int? limit});
}
```

## 8. `XBTrackConfig` 配置项详解

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关，`false` 时不采集 |
| `flushBatchSize` | `20` | 队列满多少条触发一次 flush |
| `flushInterval` | `1s` | 定时 flush 间隔 |
| `maxPendingQueueSize` | `5000` | 内存队列最大长度 |
| `maxEventBytes` | `8KB` | 单条事件最大字节，超限丢弃 |
| `sampleRate` | `1.0` | 采样率，范围 `(0,1]` |
| `memoryMaxEvents` | `1000` | 内存 sink 最大缓存条数 |
| `ioMaxBytes` | `20MB` | 非 Web 本地存储上限 |
| `webMaxBytes` | `3MB` | Web 本地存储上限 |
| `schemaVersion` | `'1.0.0'` | 埋点协议版本号 |
| `appVersion` | `null` | 应用版本，写入事件 |
| `platform` | `null` | 平台名，空时自动识别 |
| `enableConsoleSink` | `false` | 是否启用控制台 sink |
| `enableMemorySink` | `true` | 是否启用内存 sink |
| `enableLocalStoreSink` | `true` | 是否启用本地 store sink |
| `commonParamsProvider` | `null` | 全局公共参数回调 |
| `sanitizer` | `null` | 自定义值清洗器 |
| `onShareRequested` | `null` | 分享请求回调 |
| `sinks` | `[]` | 业务附加 sinks |
| `store` | `null` | 自定义 store 实现 |
| `sensitiveKeys` | 内置敏感词集合 | 命中后自动掩码 |
| `sensitiveValueMask` | `'***'` | 脱敏替换值 |
| `dropEventsWhenQueueFull` | `true` | 队列满时丢弃新事件 |
| `debugPrintDropReason` | `false` | 调试输出丢弃原因 |
| `storeNamespace` | `'xb_track'` | 本地存储命名空间 |

## 9. 内置组件

### 9.1 `XBTrackDebugPage`

作用：可视化查看本地埋点数据，支持搜索、分页、复制 JSON、触发分享、清空缓存。

用法：

```dart
Navigator.of(context).push(
  MaterialPageRoute(builder: (_) => const XBTrackDebugPage()),
);
```

### 9.2 内置 sinks

1. `XBConsoleSink`：输出到控制台。
2. `XBMemorySink`：内存环形缓存。
3. `XBLocalStoreSink`：写入本地 `XBTrackStore`。

## 10. 高级扩展示例

### 10.1 自定义 Sink（例如上传到你自己的服务）

```dart
class MyUploadSink extends XBTrackSink {
  @override
  Future<void> onEvents(List<XBTrackEvent> events) async {
    final payload = events.map((e) => e.toJson()).toList();
    // TODO: 调用你自己的网络层上传 payload
  }
}
```

```dart
await initXBTrack(
  XBTrackConfig(
    sinks: <XBTrackSink>[MyUploadSink()],
  ),
);
```

### 10.2 自定义脱敏规则

```dart
await initXBTrack(
  XBTrackConfig(
    sanitizer: ({required key, required value}) {
      if (key == 'email' && value is String) {
        return value.replaceAll(RegExp(r'(?<=.).(?=.*@)'), '*');
      }
      return value;
    },
  ),
);
```

## 11. 接入建议（与 XBScaffold 配合）

1. 在应用启动时调用 `initXBTrack`。
2. 登录后调用 `xbSetTrackUser`，退出登录时调用 `xbClearTrackUser`。
3. 页面生命周期中接入 `xbTrackPageView/pageHide/pageLeave`。
4. App 生命周期中接入 `xbTrackAppForeground/background`。
5. 关键交互使用 `xbTrack` 或 `xbTrackTap`。
6. 线上环境建议开启本地持久化并配置导出回调，便于问题排查。

## 12. 发布说明

`xb_analytics_plus` 是独立包，可单独发布。  
发布前建议执行：

```bash
flutter pub get
flutter analyze
flutter test
flutter pub publish --dry-run
```
