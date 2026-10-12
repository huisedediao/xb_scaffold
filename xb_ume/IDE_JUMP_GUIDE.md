# xb_ume IDE 跳转使用指南

> 手机上点击组件，电脑上 IDE 自动打开对应源码行列。

## 一、功能简介

在 xb_ume Locator（组件拾取）模式中选中任意组件后，气泡中展示的组件链条行 / picked / parent 行行尾有一个箭头按钮（↗）。点击后：

1. 本机 IDE（VS Code 系编辑器 / Android Studio）自动打开对应文件并定位到行列；
2. 同时复制 `path:line:column` 到剪贴板作为兜底。

**工作原理**：App 端点击后通过 `developer.postEvent` 经 VM service Extension 流发出事件；电脑上的常驻守护进程（daemon）监听事件并唤起 IDE。App 跑在手机、IDE 在电脑，两者物理分离，因此必须在本机部署一次 daemon 作为接收器——这与 DevTools 的 "Open in IDE" 依赖 IDE 内置 Dart Tooling Daemon 是同一思路，xb_ume 用独立轻量脚本实现了等效能力。

## 二、前置条件

| 条件 | 说明 |
|---|---|
| App 为 **debug 模式** | release 无 VM service 与源码位置信息，事件静默降级为仅复制剪贴板 |
| App 已接入 xb_ume | 见下文「App 侧接入」 |
| 电脑已安装目标 IDE | VS Code 系（Qoder/Cursor/Trae/Windsurf/VS Code）或 Android Studio |

### App 侧接入（如已接入可跳过）

在 `main()` 中初始化（完整示例见 `example/lib/main.dart`）：

```dart
import 'package:flutter/foundation.dart';
import 'package:xb_ume/xb_ume.dart';

void main() {
  XBUmeBinding.ensureInitialized(
    config: const XBUmeConfig(
      enable: kDebugMode,
      // 可选：指定允许拾取的包，默认业务代码均可
      // locatorInspectablePackages: <String>{'my_package'},
    ),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      builder: XBUme.appBuilder(),          // 挂载悬浮按钮与面板
      navigatorObservers: [XBUme.routeObserver],
      // ...其余配置
    );
  }
}
```

## 三、电脑侧安装守护脚本（一次性）

在依赖 xb_ume 的项目目录中执行：

```bash
# macOS / Windows / Linux 命令一致
cd /path/to/your/app
flutter pub get
dart run xb_ume:ide --install
```

安装内容：

| 平台 | 自启方式 | 特性 |
|---|---|---|
| macOS | LaunchAgent（`~/Library/LaunchAgents/com.xbume.ide.plist`） | 登录自启 + 崩溃自拉起 |
| Windows | HKCU 注册表 Run 键（`XBumeIde`） | 仅登录自启，崩溃不自动拉起 |
| Linux | 无自启 | 需手动前台运行 `--daemon` |

安装过程中若在终端运行，会列出本机检测到的 IDE 并让你按优先级选择（如输入 `2 1 3`，直接回车使用默认顺序），结果写入 `~/.xb_ume_ide/config.json`。

安装后日常**零操作**：正常 `flutter run` 或 IDE 运行按钮启动调试即可，daemon 会自动发现会话。

守护进程**单实例运行**：`--install` / `--daemon` 启动的新实例会自动接管（停止旧实例，只保留最新实例）；重复安装/启动不会出现多个实例重复响应点击的问题。

## 四、日常使用

1. 电脑上启动 debug 会话（`flutter run` 或 IDE 运行按钮）；
2. 手机上点悬浮 UME 按钮，进入 **Locator** 模式；
3. 点击目标组件，气泡展示组件链条；
4. **点击行尾箭头按钮（↗）**，电脑 IDE 自动打开对应源码行列，同时路径已复制到剪贴板。

支持多台设备同时调试；App 重启自动重连，会话断开自动清理。

## 五、配置 IDE 优先级

daemon 每次唤起 IDE 时重新读取配置，**修改立即生效，无需重启**。

### 方式一：交互式选择

```bash
dart run xb_ume:ide --configure
```

### 方式二：非交互直接设置

```bash
dart run xb_ume:ide --configure --ide-order "cursor,qodercn,code"
```

### 方式三：直接编辑配置文件

| 平台 | 路径 |
|---|---|
| macOS / Linux | `~/.xb_ume_ide/config.json` |
| Windows | `%USERPROFILE%\.xb_ume_ide\config.json`（即 `C:\Users\<用户名>\.xb_ume_ide\config.json`） |

```json
{ "ideOrder": ["cursor", "qodercn", "code", "androidStudio"] }
```

### 其他命令

```bash
dart run xb_ume:ide --configure --show   # 查看当前顺序及各 IDE 可用状态
dart run xb_ume:ide --ide qodercn        # 单次显式指定 IDE（优先级最高）
```

### 规则

- 默认优先级：**Qoder（`qodercn`）→ Cursor（`cursor`）→ Trae（`trae`）→ Windsurf（`windsurf`）→ VS Code（`code`）→ Android Studio（`androidStudio`）**；
- 顺序中未安装的 IDE 自动跳过；
- 配置缺失/损坏时回退默认顺序；
- 优先级：`--ide` 显式参数 > `config.json` > 内置默认。

## 六、平台差异说明

| 环节 | macOS | Windows | Linux |
|---|---|---|---|
| 会话发现 | `lsof` 扫描回环端口 | 自带 `netstat -ano`，能力一致 | `lsof` |
| VS Code 系唤起 | PATH 优先 + /Applications 内置 CLI 回退 | `%LOCALAPPDATA%\Programs\<App>\...\bin\*.cmd` 等常见路径回退 | PATH |
| Android Studio | `idea://` 深链（行列定位） | 命令行 `--line/--column`（未实测） | 命令行（未实测） |
| 自启 | LaunchAgent，崩溃自拉起 | 注册表 Run 键，不自拉起 | 无 |

**Android Studio 限制**：JetBrains 仅能对**已在 AS 中打开的项目内文件**精确定位行列。跳转 pub-cache 三方包源码时需先在 AS 中 File → Open 打开该包目录；VS Code 系编辑器无此限制。

## 七、故障排查

| 现象 | 排查步骤 |
|---|---|
| 点一次箭头唤起了多个 IDE | 旧版本存在多实例重复消费事件的问题，已加入单实例接管锁：更新脚本后重新 `--install`（新实例自动停止旧实例）即可 |
| 点箭头只提示「路径已复制到剪贴板」 | daemon 未运行：`--configure --show` 查看状态；或前台运行 `dart run xb_ume:ide --daemon` 看日志 |
| IDE 打开了文件但没定位到行列 | Android Studio 平台限制，见第六节；或旧版命令行工具不支持 `--column` |
| 自动发现不到调试会话 | 手动兜底：`dart run xb_ume:ide --uri <ws-uri>`，URI 取自 `flutter run` 控制台输出 |
| Windows 登录后 daemon 没起来 | 注册表自启依赖 `dart` 在 PATH 中，确认终端能直接运行 `dart --version` |
| Web 平台 | 不支持（无 dart:io） |

## 八、卸载

```bash
dart run xb_ume:ide --uninstall
```

会停止所有守护进程实例，并清理守护脚本、配置文件与自启项（macOS LaunchAgent / Windows 注册表键）。不卸载脚本时点箭头仍可用（仅复制路径到剪贴板）。
