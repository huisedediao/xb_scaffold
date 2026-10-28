# xb_ume

`xb_ume` 是纯 Flutter 的 in-app 调试工具箱（思路参考 `flutter_ume`），由两部分组成：

- **App 内面板**：悬浮球 + 底部面板，内置 Console / Route / Performance / Network / Inspector / Locator / Device / Storage 八个插件；
- **电脑端 GUI 工具箱**：本机 Web 页面，提供设备与调试会话管理、日志、时间轴、异常、沙盒、数据库、路由栈、Network、Storage、实例、截图、性能、自动化、对比等能力；
- 另含 **IDE 跳转**（App 内点源码行尾 ↗ → 电脑端 IDE）、**命令行场景执行**（CLI / CI）与 **MCP 服务**（Qoder / Cursor / Claude Code 直连调试会话）。

App 内为纯 Dart 实现，不引入原生插件（Network 适配器依赖的 `dio` / `package:http` 已在包内声明）；电脑端脚本零新增依赖、无需编译。

## 目录

- [功能总览](#功能总览)
- [环境与平台支持](#环境与平台支持)
- [安装](#安装)
- [快速使用（App 内面板）](#快速使用app-内面板)
- [App 内模块详解](#app-内模块详解)
- [配置项](#配置项)
- [电脑端 GUI 工具箱](#电脑端-gui-工具箱)
- [IDE 跳转](#ide-跳转)
- [命令行执行场景（CLI / CI）](#命令行执行场景cli--ci)
- [MCP 接入（AI 直接驱动调试会话）](#mcp-接入ai-直接驱动调试会话)
- [常见问题](#常见问题)
- [卸载](#卸载)
- [相关文档](#相关文档)

## 功能总览

| 位置 | 模块 | 一句话说明 |
|---|---|---|
| App 内 | Console | 捕获 `debugPrint` / Flutter 异常 / 平台异常，过滤、搜索、导出 |
| App 内 | Route | 路由事件时间线（push / pop / replace / remove）及触发阶段、调用栈 |
| App 内 | Performance | 逐帧 build / raster / total 耗时、平均 FPS、Jank 统计 |
| App 内 | Network | Dio / package:http / 自定义请求的完整记录与发起位置 |
| App 内 | Inspector | Element 树快照、按类型/Key 搜索、节点详情 |
| App 内 | Locator | 屏幕拾取组件：宽高、间距、组件链、源码位置、点行尾 ↗ 跳 IDE |
| App 内 | Device | OS、屏幕尺寸、DPR、文字缩放、方向等环境信息 |
| App 内 | Storage | 按适配器读写任意 key/value 存储（面板内只写字符串） |
| 电脑端 | GUI 工具箱 | 15 个 Tab，覆盖设备/日志/沙盒/数据库/路由/网络/性能/自动化/调试等 |
| App 内 / 电脑端 | IDE 跳转 | 点源码行尾 ↗ 或 GUI 栈帧「跳转」→ 在 VS Code / Android Studio 等打开对应行列 |
| 命令行 | `xb_ume run` | 同一份场景 JSON 在 CI 中回放并产出 HTML 报告 |
| 电脑端 | MCP 服务 | Qoder / Cursor / Claude Code 直连：按组件 ref 点击、读路由/网络/日志、跑场景、驱动设备 |

## 环境与平台支持

**环境要求**

- Dart `>=3.1.0 <4.0.0`
- Flutter `>=3.12.0`
- 电脑端 GUI 需要本机浏览器；`dart run xb_ume:ide` 需要 `dart:io`（macOS / Windows / Linux）

**平台能力矩阵**（行 = 被调试 app 的平台）

| 平台 | App 内面板 | 电脑端 GUI | IDE 跳转 | 整进程 CPU / 内存 | 依赖 VM evaluate 的 Tab¹ |
|---|---|---|---|---|---|
| Android | ✅ | ✅（adb） | ✅ | ✅ 全核 CPU + PSS | ✅ |
| iOS | ✅ | ✅（仅 macOS 电脑；真机需 libimobiledevice） | ✅ | ✅ 单核 CPU + footprint | ✅ |
| 鸿蒙 OHOS | ✅ | ✅（hdc） | ✅ | ✅ 全核 CPU + PSS² | ❌ |
| macOS | ✅ | ✅ | ✅ | ✅ 单核 CPU + footprint | ✅ |
| Windows | ✅ | ✅ | ✅ | ✅ 全核 CPU + WorkingSet | ✅ |
| Linux | ✅ | ⚠️ 无一键安装：源码目录运行 `dart bin/ide_gui.dart` | ✅（`--daemon`） | ✅ 单核 CPU + PSS（/proc 可读时） | ✅ |
| Web | ✅ | ❌ | ❌ | ❌ | ❌ |

¹ 应用沙盒、数据库、路由栈、Storage、实例、Widget 树、自动化中的 eval 步骤等。
² 鸿蒙 PSS 由 `/proc/self/smaps` 汇总；GL/Graph 显存由系统单独统计，app 内读不到，数值可能比 DevEco 略低。

**运行模式**：电脑端 GUI 的会话相关能力（Flutter 输出、时间轴、异常、截图、自动化等）通过 VM service 工作，**debug** 下最完整；依赖 VM `evaluate` 的能力（应用沙盒、数据库、路由栈、Storage、实例、自动化 eval 步骤，以及 Locator 源码定位）必须 **debug**（profile 为 AOT 编译，通常无法求值表达式）；release 无 VM service。App 内面板在 release 下仍可渲染并采集日志/路由/帧，但调试细节会退化。

电脑端 GUI 的日志、设备管理依赖对应平台工具：`adb` / `hdc` / Xcode `simctl` / `idevice_id`（`brew install libimobiledevice`）。

## 安装

### 1. 添加依赖

来自 pub：

```yaml
dependencies:
  xb_ume: ^0.3.0
```

本地联调（path）：

```yaml
dependencies:
  xb_ume:
    path: ../xb_scaffold/xb_ume
```

然后执行 `flutter pub get`。

### 2. App 内初始化（必做）

只加依赖不会显示悬浮球，也不会采集数据；需要在 `main()` 初始化一次，并把面板宿主与路由观察者挂到 `MaterialApp`：

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xb_ume/xb_ume.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  XBUmeBinding.ensureInitialized(
    config: const XBUmeConfig(
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
      builder: XBUme.appBuilder(),               // 悬浮球 + 面板宿主
      navigatorObservers: [XBUme.routeObserver], // Route 插件的数据源
      home: const Scaffold(body: Center(child: Text('Hello xb_ume'))),
    );
  }
}
```

说明：`XBUmeBinding.ensureInitialized` 必须在 `WidgetsFlutterBinding.ensureInitialized()` 之后调用；若 App 已有 `MaterialApp.builder`（如主题/本地化包装），用 `builder: XBUme.appBuilder(builder: 原有builder)` 串起来，不要直接覆盖。示例中的 `enable: kDebugMode` 表示仅 debug 下显示面板，可按需调整。

使用 `go_router` 时，把观察者挂到 `GoRouter` 上（二选一，不要重复挂）：

```dart
final router = GoRouter(
  observers: [XBUme.routeObserver],
  routes: [...],
);
```

可选：追加自定义插件。

```dart
XBUmeBinding.ensureInitialized(
  config: const XBUmeConfig(enable: kDebugMode),
  extraPlugins: [MyPlugin()],
);
```

完整示例见 [`example/lib/main.dart`](example/lib/main.dart)。

### 3. 电脑端守护与 GUI（每台电脑一次）

在**依赖了 xb_ume 的项目目录**执行：

```bash
flutter pub get

# macOS / Windows：部署守护进程 + GUI，并注册登录自启（macOS 额外崩溃自拉起）
dart run xb_ume:ide --install

# 打开 GUI 工具箱（自动打开浏览器）
dart run xb_ume:ide --gui
```

安装内容与平台差异：

| 项目 | macOS | Windows | Linux |
|---|---|---|---|
| 守护进程自启 | LaunchAgent（登录自启 + 崩溃自拉起） | HKCU Run 键（仅登录自启） | 不支持 `--install`，用 `--daemon` 前台运行 |
| GUI 入口 | 「应用程序」中的 `xb_ume 工具箱` | 桌面快捷方式 | 无一键部署，源码目录运行 `dart bin/ide_gui.dart` |
| 卸载 | `dart run xb_ume:ide --uninstall` | 同左 | 手动结束 `--daemon` |

日常零操作：`flutter run` 或 IDE 运行按钮启动的调试会话会被守护进程自动发现并接入（轮询本机回环端口探测 VM service），支持多设备、多会话，App 重启自动重连。

手动/调试命令：

```bash
dart run xb_ume:ide --uri <ws-uri>     # 手动接单个会话（URI 取自 flutter run 输出）
dart run xb_ume:ide --daemon           # 前台运行守护进程（不注册自启）
dart run xb_ume:ide --configure        # 交互式选择 IDE 优先级
dart run xb_ume:ide --configure --show # 查看当前优先级与可用状态
dart run xb_ume:ide --configure --ide-order "cursor,qodercn,code"
```

GUI 只监听 `127.0.0.1` 并校验 Host / Origin；启动时生成一次性访问令牌，浏览器页面自动通过 Cookie 下发。本地脚本调用时读取 `~/.xb_ume_ide/gui.token`，请求头带 `X-XBUME-Token: <token>`。

### 4. 设备前置

| 目标 | 要求 |
|---|---|
| Android 真机 / 模拟器 | 开启 USB 调试并在手机上授权；`adb devices -l` 能看到设备 |
| 鸿蒙真机 / 模拟器 | `hdc list targets` 能看到设备 |
| iOS 模拟器 | macOS + Xcode（`xcrun simctl`） |
| iOS 真机 | `brew install libimobiledevice`（设备列表与 `idevicesyslog` 日志） |

### 5. 安装验证

1. `flutter run` 启动 App，控制台出现 `A Dart VM Service ... is available at: http://127.0.0.1:<port>/`；
2. 打开 GUI，页头右侧的会话下拉框出现该会话（显示应用包名与端口）；
3. App 内点击悬浮球，底部弹出面板并显示 8 个插件 Tab；
4. 选中设备后，「日志」Tab 能看到 logcat / hilog / log stream 输出。

## 快速使用（App 内面板）

- **打开/关闭**：点击悬浮球切换面板；**拖动**悬浮球可换位置（初始位置 `floatingInitialOffset`，默认 `(16, 180)`）。
- **面板布局**：底部弹出、宽度铺满，高度由 `panelSize.height` 控制（默认 640，最小 280）；点面板外的遮罩或悬浮球关闭。
- **插件 Tab**：按注册顺序排列，默认 `Route → Performance → Network → Console → Inspector → Locator → Device → Storage`；每个 Tab 内容在首次打开时创建并缓存。
- **数据上限**：各模块用环形缓冲限制条数（默认日志 400、路由 300、帧 600、网络 300），超出丢弃最早记录。
- **快照持久化**：`persistenceEnabled: true` 时按 `persistenceDebounce`（默认 1s）防抖写 `Directory.systemTemp/<persistenceFileName>`，重启后恢复；默认关闭。

## App 内模块详解

### Console

**功能**：收集日志与异常，支持过滤、搜索、查看详情、导出。

**采集来源**

- `debugPrint`（`captureDebugPrint`，默认开）——注意 `print` **不会**被自动捕获；
- `FlutterError.onError`（`captureFlutterError`）与 `PlatformDispatcher.instance.onError`（`capturePlatformError`）；
- 主动上报：

```dart
XBUme.log(
  '创建订单失败',
  level: XBUmeLogLevel.error, // debug / info / warn / error / fatal
  tag: 'order',
  stack: stackTrace?.toString(),
);
```

**面板操作**：顶部按级别过滤（ALL / DEBUG / INFO / WARN / ERROR / FATAL）+ 关键字搜索；`Export` 把当前过滤结果以 JSON 复制到剪贴板；`Clear` 清空；点条目查看详情并复制。

**限制**：`maxConsoleRecords` 默认 400；控制台 UI 刷新节流 `consoleUiUpdateInterval`（默认 120ms），高频日志不会逐条重建列表。

### Route

**功能**：记录 Navigator 的路由事件，排查「谁在什么时候改了路由」。

**接入**：`navigatorObservers: [XBUme.routeObserver]`（或 `GoRouter(observers: ...)`）。

**记录内容**：动作（push / pop / replace / remove）、路由名、上一个路由名；事件触发时的 `SchedulerPhase`（idle / build-layout / 动画帧）以及非 idle 时的精简调用堆栈。

**面板操作**：关键字搜索、显示条数、清空；列表按时间展示 `[动作] 路由名` 与 `previous:`。

**限制**：`maxRouteRecords` 默认 300；匿名路由显示框架生成的名称。

### Performance

**功能**：逐帧性能面板，数据来自 `WidgetsBinding.addTimingsCallback`。

**展示**：frames（帧数）、avg fps、avg total、avg build、avg raster、jank 数量，以及逐帧列表（`total / build / raster`）。`total >= 16.7ms` 标记为 Jank frame（红色）。

**面板操作**：`Clear` 清空当前记录。

**限制**：`maxPerformanceRecords` 默认 600，UI 节流 `performanceUiUpdateInterval`（默认 240ms）。这是**帧耗时**面板；电脑端 GUI「性能」Tab 的整进程 CPU / 内存是另一套指标，两者互补。

### Network

**功能**：记录请求方法、URL、查询参数、请求/响应头与 Body、状态码、耗时、错误与发起位置。

**三种接入方式**

Dio：

```dart
dio.interceptors.add(XBUmeDioInterceptor());
```

`package:http`：

```dart
final client = XBUmeHttpClient(http.Client());
```

自定义网络框架：

```dart
final id = XBUmeNetworkReporter.begin(
  method: 'GET',
  url: Uri.parse('https://api.example.com/items'),
  requestHeaders: {'authorization': token},
  requestBody: null,
  sourceStackTrace: StackTrace.current, // 可选：用于解析发起位置
);

try {
  XBUmeNetworkReporter.progress(id, 0.5); // 可选：上传/下载进度
  XBUmeNetworkReporter.complete(
    id,
    statusCode: 200,
    responseHeaders: {'content-type': 'application/json'},
    responseBody: '{"ok":true}',
  );
} catch (e, s) {
  XBUmeNetworkReporter.fail(id, error: e, stackTrace: s);
}
```

**面板操作**：按状态过滤（ALL / PENDING / SUCCESS / FAILURE / CANCELLED）+ 关键字搜索；`Copy JSON` 复制当前列表；`Clear` 清空；详情内展示请求/响应头与 Body，`跳转发起位置` 在 IDE 打开调用点（未安装守护时复制路径）。

**脱敏与上限**：`sensitiveKeys` 命中的头/字段值写成 `***`（默认含 authorization、cookie、token、password、secret、api-key 等）；Body 超过 `networkBodyMaxLength`（默认 64KB）截断；记录上限 `maxNetworkRecords` 默认 300。

**限制**：只有经过上述拦截器/客户端/Reporter 的请求才会被记录；`XBUmeHttpClient` 会把响应流读入内存以便记录，超大文件下载不建议套用。

### Inspector

**功能**：抓取当前 Element 树，按类型或 Key 搜索节点并查看详情。

**使用**：打开 Tab 后点 `Refresh` 抓取快照（`inspectorAutoCaptureOnOpen` 默认 false，不在打开时自动抓）；输入框按 widget 类型/Key 过滤；点节点查看选中卡片或详情弹窗，可复制。

**限制**：依赖已渲染首帧；`maxInspectorNodes` 默认 1500，超出截断；源码位置等调试信息在 debug 构建下最完整。

### Locator

**功能**：在真机/模拟器屏幕上点选组件，显示它的尺寸、间距、组件链与源码位置。

**使用**

1. 面板内点 `Start Pick`（需要 debug + `track-widget-creation`，顶部 chip 为 `ON`）；
2. 直接点击屏幕上任意组件；点悬浮球或 `Stop Pick` 结束拾取；
3. 屏幕上出现高亮框与信息气泡（可拖动），包含 picked / resolved 组件、宽高、源码 file:line:column、父级信息，以及可展开的完整组件链（含每层源码行）；
4. 气泡内展示间距标注：橙色 = 与同级组件的间距，绿色 = 与父组件边缘的间距；
5. **点源码位置行尾的 ↗ 箭头**会在电脑端 IDE 打开对应行列（需已安装守护进程；否则复制 `path:line:column` 到剪贴板）；
6. `Clear Result` 清除结果。

**第三方包源码**：默认优先解析应用自身与本地库的位置；要定位第三方 UI 包内部实现，把包名加入白名单：

```dart
const XBUmeConfig(
  locatorInspectablePackages: <String>{'flutter_quill', 'cached_network_image'},
);
```

**限制**：源码位置依赖 debug 模式的 widget creation tracking；release/profile 下无法得到创建位置。

### Device

**功能**：显示运行环境信息：`kIsWeb`、OS、`defaultTargetPlatform`、物理分辨率、DPR、逻辑尺寸、文字缩放、屏幕方向等。

**使用**：打开 Tab 即展示；点 `Refresh` 重新读取。

### Storage

**功能**：把任意 key/value 存储接入面板，查看与修改（仅可写适配器）。

**接入**

```dart
final session = <String, dynamic>{'token': 'demo', 'count': 1};

XBUme.registerStorageAdapter(
  XBUmeMapStorageAdapter(id: 'session', data: session, allowWrite: true),
);
```

自定义适配器实现 `XBUmeStorageAdapter`：

```dart
class PrefsAdapter implements XBUmeStorageAdapter {
  @override
  String get id => 'prefs';

  @override
  bool get writable => true;

  @override
  Future<Map<String, dynamic>> dump() async => {/* 读取全部键值 */};

  @override
  Future<void> setValue(String key, dynamic value) async {/* 写入 */}

  @override
  Future<void> removeValue(String key) async {/* 删除 */}
}
```

**面板操作**：顶部 ChoiceChip 切换适配器、`Refresh` 重新读取、关键字搜索；可写适配器会显示 `Key` / `Value (string)` / `Set` 输入区（面板只写字符串）。

**注意**：这是 App 内适配器面板，需要 app 主动注册；电脑端 GUI 的「Storage」Tab 是另一条路径，直接读写 shared_preferences 文件，**不需要**注册适配器。

### 自定义插件

实现 `XBUmePlugin` 后注册即可获得独立 Tab：

```dart
class MyPlugin extends XBUmePlugin {
  @override
  String get id => 'my';

  @override
  String get title => 'My';

  @override
  IconData get icon => Icons.extension;

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return const Center(child: Text('Hello'));
  }
}

XBUme.registerPlugin(MyPlugin());
```

也可在初始化时通过 `extraPlugins: [...]` 注册；用 `XBUme.unregisterPlugin('my')` 移除。`disabledPluginIds` / `onlyEnablePluginIds` 可按 id 过滤默认插件。

### 实例注册（配合电脑端「实例」Tab）

App 内注册需要在电脑端查看/修改的运行时对象（Provider 的 notifier、全局单例等）：

```dart
XBUme.registerStore('userNotifier', context.read<UserNotifier>());
```

注册表使用 `WeakReference` 弱持有，不会延长对象生命周期；重复 id 覆盖。电脑端「实例」Tab 可展开字段树、修改基础类型字段并写回（`ChangeNotifier` 自动 `notifyListeners`）。不注册也可以按类名在 GUI 中查找实例（Element 树 + 堆扫描双通道）。

## 配置项

`XBUmeConfig` 常用字段（完整定义见 [`lib/src/config/xb_ume_config.dart`](lib/src/config/xb_ume_config.dart)）：

| 字段 | 默认值 | 说明 |
|---|---|---|
| `enable` | `true` | 总开关；false 时不渲染悬浮球与面板 |
| `enableConsole` / `enableRoute` / `enablePerformance` / `enableNetwork` | `true` | 各插件开关 |
| `enableInspector` / `enableWidgetLocator` / `enableDevice` / `enableStorage` | `true` | 各插件开关 |
| `captureDebugPrint` / `captureFlutterError` / `capturePlatformError` | `true` | 全局日志/异常钩子 |
| `maxConsoleRecords` / `maxRouteRecords` / `maxPerformanceRecords` / `maxNetworkRecords` | `400 / 300 / 600 / 300` | 各模块环形缓冲条数 |
| `networkBodyMaxLength` | `65536` | 请求/响应 Body 最大字符数，超出截断 |
| `maxInspectorNodes` | `1500` | Inspector 单次快照最大节点数 |
| `consoleUiUpdateInterval` / `performanceUiUpdateInterval` | `120ms / 240ms` | 面板 UI 刷新节流 |
| `inspectorAutoCaptureOnOpen` | `false` | 打开 Inspector 时是否自动抓树 |
| `locatorInspectablePackages` | `{}` | Locator 允许定位的第三方包名 |
| `floatingInitialOffset` | `Offset(16, 180)` | 悬浮球初始位置 |
| `panelSize` | `Size(980, 640)` | 面板尺寸（实际宽度铺满屏幕，高度生效） |
| `persistenceEnabled` / `persistenceFileName` / `persistenceDebounce` | `false / xb_ume_snapshot.json / 1s` | 快照持久化 |
| `disabledPluginIds` / `onlyEnablePluginIds` | `{} / null` | 按插件 id 禁用或只启用白名单 |
| `sensitiveKeys` | authorization、cookie、token、password、secret、api-key 等 | Network 脱敏键名（不区分大小写） |

## 电脑端 GUI 工具箱

**安装与启动**：见 [安装 3](#3-电脑端守护与-gui每台电脑一次)；详细说明（启动方式、令牌、每个 Tab 的操作步骤、常见问题）见 [GUI_GUIDE.md](GUI_GUIDE.md)。

**页头（全局）**：设备选择器 + VM 会话选择器。选中设备后「日志」Tab 的设备日志源随之切换；选中会话后各 VM 相关 Tab 才有数据。iOS 真机需 libimobiledevice；鸿蒙设备用 `hdc`。

**Tab 一览**（当前可见 15 个；「状态」「Widget树」两个 Tab 暂时隐藏，代码保留）：

| Tab | 功能 | 前置 / 说明 |
|---|---|---|
| 守护进程 | daemon 状态、已接入会话、一键重启、IDE 优先级拖拽排序 | 需 `--install` 或 `--daemon` |
| 调试 | 起停 `flutter run`（已有会话直接复用）；按 `文件:行` 打断点，支持条件断点与日志断点（命中不暂停、求值写进输出后自动继续），条件 / 日志可就地编辑；命中后浮动条暂停/继续/单步/热重载/热重启；调用栈、变量与求值、运行输出；断点自动记住，重连同一项目自动恢复，也可按「全部项目」总览清空；异常/网络定位行可一键下断点 | 只调 VM service， app 端零改动；外部会话可接入（热重载需本工具拉起的会话） |
| 日志 | 设备日志（logcat / hilog / log stream / idevicesyslog）+ Flutter 输出（未选会话时为全部，选中后只显示该应用） | 设备工具可用；Flutter 输出需 daemon |
| 时间轴 | 路由 / 网络 / 日志 / 异常按时间合并，可过滤、暂停、展开、跳转对应 Tab | 需选中会话 |
| 异常 | 实时捕获框架异常与未捕获异常，栈帧可跳 IDE、可一键下断点，Tab 角标 + 红浮层提醒 | daemon 在跑即可，覆盖全部会话（不要求选中） |
| 应用沙盒 | 浏览 / 下载 / 上传 / 删除 app 文件，文件可「查看」「监听」（tail -f） | VM evaluate；鸿蒙引擎不支持 |
| 数据库 | 打开沙盒内 SQLite：表结构、分页浏览、只读 SQL、导出 CSV | 本机 `sqlite3`；快照只读；库文件 ≤256MB |
| 路由栈 | Navigator 路由栈（栈底→栈顶）：路由名、类型、参数、源码、Widget/State/VM/Notifier | VM evaluate；鸿蒙不支持 |
| Network | 与 App 内 Network 模块同源：过滤、详情、复制 cURL、重发、清空 | App 内需接入拦截器 |
| Storage | 直接读写 app 的 shared_preferences 文件（Android XML / 鸿蒙 preferences / iOS plist） | 依赖 VM evaluate；保存时经 app 内 API 立即生效（部分 key 需重启） |
| 实例 | 注册表 Store、按类名查找实例、字段树展开与写回 | VM evaluate；鸿蒙不支持 |
| 截图 | 实时截图；开启遥控后单击=Tap、拖拽=Swipe、回车=Input；可录制场景 | `_flutter.screenshot` 不可用时自动回退 |
| 性能 | 整进程 CPU、Dart 堆、进程内存（PSS / footprint）与双曲线；可暂停/清空/触发 GC | 整进程指标需 app 内 binding 初始化 |
| 自动化 | JSON 场景回放（tap/input/swipe/断言…）+ AI 驱动循环（自然语言目标→截图→决策→执行） | 需选中会话；鸿蒙不支持 eval 类步骤 |
| 对比 | 同一场景在两个会话上并行执行，逐步骤并排状态/耗时/截图，并对照网络差异 | 需两个会话 |

**性能 Tab 口径**（与官方工具一致）：

- CPU：Android Studio / DevEco 以**全部核心容量**为 100%，Xcode（iOS/macOS）以**单核**为 100%；
- 内存：Android/鸿蒙取 PSS（Android 按 `dumpsys meminfo` 分类，鸿蒙按 DevEco 内存类型），iOS/macOS 取 `phys_footprint`；
- 依赖 app 内 `XBUmeBinding.ensureInitialized` 注册的 `ext.xbume.processStats`（xb_ume ≥ 0.3.0）；未注册时回退为 Dart 主 isolate CPU + VM 进程内存分桶；
- GPU memtrack 显存在 app 内不可读，Android 的 Graphics、鸿蒙的 GL/Graph 可能略低于官方工具。

## IDE 跳转

适用于 Locator 气泡源码行、Network 详情「跳转发起位置」、GUI 异常栈帧等场景：App 内点击源码行尾的 ↗ 箭头 → 通过 VM service 事件发给电脑端守护进程 → 按优先级唤起 IDE 并定位到 `file:line:column`，同时把路径复制到剪贴板兜底。

**安装**（每台电脑一次，在依赖 xb_ume 的项目目录）：

```bash
dart run xb_ume:ide --install
```

**IDE 优先级**：默认 Qoder → Cursor → Trae → Windsurf → VS Code → Android Studio；未安装的自动跳过。可交互修改或直接指定：

```bash
dart run xb_ume:ide --configure
dart run xb_ume:ide --configure --ide-order "cursor,qodercn,code"
dart run xb_ume:ide --configure --show
```

**注意**：Android Studio 在 macOS 走 `idea://` 深链，只能对**已打开项目内**的文件定位行列；其他平台走 `--line/--column`。未安装守护时点击仍可用，但只复制路径到剪贴板。

完整说明见 [IDE_JUMP_GUIDE.md](IDE_JUMP_GUIDE.md)。

## 命令行执行场景（CLI / CI）

GUI「自动化」Tab 保存的场景 JSON 可以不开 GUI、不开浏览器直接执行，产出含截图的 HTML 报告：

```bash
# 场景名（~/.xb_ume_ide/scenarios/<名>.json）或文件路径
dart run xb_ume:run login-remote --uri 65296 --report out/login.html

# 全局安装后可用 `xb_ume run`
dart pub global activate --source path .
xb_ume run login-remote --uri 65296 --continue-on-fail --shot-every-step --report out/login.html
```

常用参数：`--uri`（端口 / host:port / ws 地址，必填）、`--report`、`--continue-on-fail`、`--shot-every-step`、`--wait-after <ms>`、`--shots-dir`、`--json`、`--list`。

退出码：`0` 全过（含 skip）、`1` 有失败、`2` 参数/场景/连接错误。报告为自包含 HTML（截图 base64 内嵌）。步骤语义与 GUI 自动化一致；`assertLog` 在 CLI 下标记 skip。详见 [GUI_GUIDE.md](GUI_GUIDE.md) 第十八章。

## MCP 接入（AI 直接驱动调试会话）

xb_ume 自带 MCP 服务（`bin/mcp.dart`，零新增依赖），把「进程内白盒」能力交给 AI 助手：按 Widget 树找组件（带 `ref` 与源码位置）、注入真实手势、读路由栈/网络/日志、跑场景；需要装包/起停/按键时切到设备后端。

不想读这一节？用「AI 调试」入口，一条命令就把「带 `xbume_eval` 的 MCP + 可直接粘给 AI 的指令」准备好，指令自动进剪贴板（GUI 里是「AI 调试」Tab 的一键开启）：

```bash
dart run xb_ume:ai     # 在 Flutter 项目根目录执行；--print-only 只看不动服务
```

AI 拿到指令会自己 `xbume_app_launch` 拉起 app、定位源码、改代码、热重载、复跑验证；你只需一次性把 MCP 地址填进 AI 客户端。细节见 [MCP_GUIDE.md](MCP_GUIDE.md)。

```bash
# stdio：由 Qoder / Cursor / Claude Code 作为子进程拉起（推荐）
dart run xb_ume:mcp

# Streamable HTTP：仅本机回环 46140，需 token（~/.xb_ume_ide/mcp.token）
dart run xb_ume:mcp --http 46140
```

客户端配置（stdio，粘进客户端的 MCP Servers 配置）：

```json
{
  "mcpServers": {
    "xb_ume": {
      "command": "dart",
      "args": ["run", "xb_ume:mcp"]
    }
  }
}
```

默认暴露 24 个工具（core 18 + diagnose 3 + run-safe 3）：会话发现/选定、截图、找组件、点击/输入/滑动、路由、网络（含请求/响应详情）、日志、结构化异常与时间轴、场景运行与报告、设备发现与启动、向自建 `flutter run` 发热重载/热重启。按键 / 原生点击 / 保持屏幕常亮需 `--tool-groups act`；装包/卸包/停进程（高危，需 `confirm`）需 `--tool-groups act,device-write`；`--device-backend` 选择 adb/hdc/simctl/idevice 或可选的 mobile-mcp（默认不启用）。加 `--allow-eval` 再多出 `xbume_eval`（在 app 进程内求值单行表达式，可读可改运行时状态），默认关。

GUI「守护进程」页的「MCP 服务」卡片可直接启停：点「启动」后台拉起 `~/.xb_ume_ide/mcp.dart --http <46140-46149 首个空闲> --tool-groups all`（日志写 `logs/mcp.log`），点「停止」结束；勾上「随工具箱启动」后每次打开工具箱自动拉起（默认关），勾上「允许 eval」则启动参数额外带 `--allow-eval`（改完重启服务生效）。卡片同时展示运行状态/端口/工具数，并提供「复制 MCP 配置」按当前状态生成可直接粘贴的片段（HTTP 模式自动带 token）。

「AI 调试」Tab 不需要动上面任何一个开关：它按需保证服务带 `xbume_eval` 在跑（已在跑就复用，参数不一致只重启自己 pid 记录的那个），然后把指令写进剪贴板、把 `http://127.0.0.1:<gui 端口>/#ai` 作为固定深链。

工具清单与参数、七个典型 prompt、场景 DSL 全表、设备后端能力矩阵与排障见 [MCP_GUIDE.md](MCP_GUIDE.md)。

## 常见问题

| 现象 | 处理 |
|---|---|
| App 内看不到悬浮球 | 确认 `enable` 为 true（示例的 `enable: kDebugMode` 在 profile/release 下会关闭）、已调用 `XBUmeBinding.ensureInitialized`，且 `MaterialApp.builder` 挂了 `XBUme.appBuilder()` |
| 面板里缺某个 Tab | 检查对应 `enableXxx`，以及 `disabledPluginIds` / `onlyEnablePluginIds` |
| GUI 设备列表为空 | 终端能运行 `adb devices` / `hdc list targets`；iOS 真机装 libimobiledevice；手机开启 USB 调试并授权 |
| GUI 显示「VM 未连接」或会话不出现 | app 需 debug 运行；`--install` / `--daemon` 守护在跑；优先从真实终端或 IDE 启动 `flutter run`（nohup/后台方式可能使 DDS 无响应） |
| 性能页只有「Dart 主 isolate」 | 未走 `XBUmeBinding.ensureInitialized` 或 xb_ume 版本过低；Windows 无整进程采样，回退为 isolate 指标；release 无 VM service |
| Network 没有记录 | 请求未经过 `XBUmeDioInterceptor` / `XBUmeHttpClient` / `XBUmeNetworkReporter` |
| 沙盒/数据库/实例提示表达式求值失败 | 鸿蒙 Flutter 引擎不提供表达式编译服务，换 Android / iOS / macOS 会话；release/AOT 同样不可用 |
| `flutter test` 偶发 `Unable to connect to flutter_tester` | 守护进程轮询本机 VM service 可能干扰测试握手；先 `pgrep -fl ide.dart` 找到精确 PID 后 `kill <pid>`，不要用宽泛 `pkill` |
| MCP 连不上 / 工具报「未选择会话」 | 先调 `xbume_sessions`；HTTP 模式需带 `X-XBUME-Token`（见 [MCP_GUIDE.md](MCP_GUIDE.md) 排障章） |
| GUI 被 `kill -9` 后某个会话对 DevTools 也无响应 | 流订阅被硬切断触发 DDS 死锁，重启该 `flutter run` 会话即可；正常退出 GUI 已主动关连接规避 |

更多问题见 [GUI_GUIDE.md](GUI_GUIDE.md) 第十七章。

## 卸载

```bash
# 停止守护进程并删除 ~/.xb_ume_ide（含 GUI 脚本、启动器、配置、场景与缓存）
dart run xb_ume:ide --uninstall
```

然后从 `pubspec.yaml` 移除依赖，并删除 `main()` 中的初始化与 `MaterialApp` 上的 `builder` / `navigatorObservers`。

## 相关文档

- GUI 工具箱完整指南（14 个 Tab 的操作、令牌、CLI、FAQ）：[GUI_GUIDE.md](GUI_GUIDE.md)
- MCP 接入（工具清单、客户端配置、场景 DSL、后端矩阵）：[MCP_GUIDE.md](MCP_GUIDE.md)
- IDE 跳转与守护进程安装：[IDE_JUMP_GUIDE.md](IDE_JUMP_GUIDE.md)
- 版本变更：[CHANGELOG.md](CHANGELOG.md)
- 完整示例：[`example/lib/main.dart`](example/lib/main.dart)

当前版本：`0.4.0`。
