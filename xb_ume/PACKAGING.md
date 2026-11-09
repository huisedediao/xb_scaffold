# XbUme 桌面客户端打包与分发

两种安装方式，**功能完全一致**，只有「怎么装到电脑上」不同：

| 方式 | 适合谁 | 命令 |
| --- | --- | --- |
| 源码部署 | 开发同学（本机有 Flutter/Dart） | `dart run xb_ume:ide --install` |
| 独立安装包 | 测试 / 产品（不想碰命令行） | 双击 `.dmg`（macOS）或 `-setup.exe`（Windows） |

两条路径共用同一份 `bin/` 代码，差别只在运行形态：

- 源码部署：`~/.xb_ume_ide/` 下放 `.dart` 脚本，用 `dart` 跑；
- 安装包：脚本被 `dart compile exe` 编成 4 个原生可执行文件，
  目标机不需要 Dart / Flutter / Android SDK / DevEco。

## 运行期怎么区分两种形态

不看环境变量（Finder 双击拿不到启动器设的 env），而是看**同目录有没有兄弟
可执行文件**：

```dart
bool isBundledBuild() => bundledExe(kBundledGuiExe) != null; // 见 bin/src/control/svc_control.dart
```

`~/.xb_ume_ide/` 里没有 `xbume-gui`，源码部署自然落回原分支。这个判定
统一驱动：守护进程/GUI 拉起方式、MCP 与池 worker 拉起、全局快捷键监听器、
`resources/bin` 工具优先查找、版本号来源、`--install` 拒绝部署等。

## macOS

```bash
cd xb_ume
./tool/package/macos/build.sh                 # ad-hoc 签名
./tool/package/macos/build.sh --sign "Developer ID Application: xxx (TEAMID)"
```

产物：

- `build/package/macos/XbUme.app`（可双击）
- `dist/XbUme-<version>.dmg`（分发；内含「首次打开.command」去隔离）

目录结构：

```
XbUme.app/Contents/
  MacOS/xbume-ide          双击入口：起守护进程 + 拉 GUI + 开浏览器
  MacOS/xbume-gui          HTTP + 页面服务（默认 127.0.0.1:46129）
  MacOS/xbume-mcp          MCP 服务 / 池 worker
  MacOS/xbume-hotkey       全局快捷键监听器（Carbon 事件循环）
  Resources/version.txt    版本号（放 MacOS 会让 codesign 报 In subcomponent）
  Resources/icon.icns
  Resources/bin/adb|hdc|iproxy|idevice_id (+ *.dylib)
  Resources/使用说明.txt
  Info.plist
```

打包要点（踩过的坑都写在 `build.sh` 注释里）：

1. 内嵌的 hdc / iproxy / idevice_id 依赖第三方 dylib，`relocate_deps` 递归拷
   进来并改写为 `@executable_path/<base>`；
2. `install_name_tool` 会作废原签名，**arm64 上签名无效会被内核直接 kill**
   （现象：运行即退出、无任何输出）。签名顺序必须是「先 dylib → 再
   Resources/bin 其余二进制 → 再三个主 exe → 最后 bundle」；
3. `Contents/MacOS` 下不能放非 Mach-O 文件，版本号只能放 `Resources`；
4. 没有 Developer ID 时只能 ad-hoc，首次打开需右键「打开」或先跑 dmg 里的
   「首次打开.command」（`xattr -dr com.apple.quarantine`）。

## Windows

```powershell
powershell -ExecutionPolicy Bypass -File xb_ume\tool\package\windows\build.ps1
```

前置：`dart` 在 PATH；要出安装包需装 [Inno Setup 6](https://jrsoftware.org/isdl.php)。
没有 Inno Setup 时脚本只产出免安装目录 `build\package\windows\app\`，
打成 zip 发给测试人员同样可用（双击 `xbume-ide.exe`）。

产物：

- `build/package/windows/app/`（免安装目录）
- `dist/XbUme-<version>-setup.exe`（Inno Setup，装到当前用户目录，无需管理员）

目录结构（安装后）：

```
<安装目录>/
  xbume-ide.exe / xbume-gui.exe / xbume-mcp.exe / xbume-hotkey.exe
  tools/adb.exe|hdc.exe|idevice_id.exe|iproxy.exe (+ dll)
  version.txt / 使用说明.txt
```

`bundledBinDir()` 在 Windows 上找 `<exeDir>\tools`，排在 PATH 之前。

Windows 连 iPhone 需要机器上装了 iTunes / Apple 设备支持（提供 usbmuxd
驱动），否则 `iproxy` 建不了端口转发。

## 功能覆盖

安装包与源码部署是同一份代码，**不裁剪任何功能**：

- 会话发现（VM 通道 + `XBUME_AGENT=1` 直连通道）、日志 / 网络 / 异常 /
  时间轴 / 截图 / 点按 / 数据 / 性能；
- 断点、单步、热重载 / 热重启、表达式求值、路由栈（仅 debug 包的 VM 会话）；
- 全局快捷键（独立 `xbume-hotkey` 进程，AOT 版同样跑在 Carbon / user32 上）；
- MCP 单实例 + 池入口（`--pool-entry`，worker 由 `router._spawn` 用
  `xbume-mcp` 拉起）；
- 页内自检 `/api/version`（分发版返回 `bundled: true` 与 `version`）；
- AI 页、场景自动化、运行配置等，全部走同一个数据目录。

依赖 Flutter 调试通道的能力在直连（非 VM）会话上仍按原逻辑置灰。

## 数据目录

两种形态共用 `~/.xb_ume_ide`（macOS / Linux）或 `%USERPROFILE%\.xb_ume_ide`
（Windows）：token、config.json、日志、MCP 实例登记、AI 配置都在这里。
`XB_UME_HOME` 可覆盖（多实例 / 隔离调试），GUI 与 MCP 读同一份环境变量，
否则两边 token 不一致会握手失败。

## 升级与卸载

- macOS：把新的 `XbUme.app` 拖进「应用程序」覆盖；卸载直接拖到废纸篓。
- Windows：直接跑新版 `-setup.exe` 覆盖安装；卸载在「设置 → 应用」里，
  卸载会按可执行文件名收掉 `xbume-*` 进程。
- 数据目录不会被卸载删除（日志、配置可留档）。

## 校验

```bash
dart analyze bin
dart test            # 单测
```

打包后建议至少手工验三件事：`/api/version` 返回 `bundled: true`、
`POST /api/mcp/start` 后 `tools/list` 能列出工具、`Resources/bin/adb`（或
`tools\adb.exe`）能打印版本。
