## 0.1.0

- Initial release.
- Pure Flutter UME-like debugging toolkit.
- Includes core panel host and plugins:
  - Console
  - Route timeline
  - Performance timeline
  - Network (generic + Dio + http)
  - Inspector
  - Device info
  - Storage inspector
- Includes persistence support and a runnable example.

## 0.1.1

- optimized.

## 0.1.2

-  优化 locator 定位精度

## 0.1.3

-  优化 locator 层级展示

## 0.1.4

- locator 选中组件新增宽高标注：气泡内新增 size 行展示组件真实宽高（逻辑像素），高亮框边缘新增 W/H 青色标签，组件超出屏幕时仍显示真实值；不影响现有边框、间距标注与拖拽功能。

## 0.1.5

- 新增电脑端 GUI 工具箱（`bin/ide_gui.dart`，本机 Web GUI、零新增依赖）：`--install` 时随守护脚本一并部署，并在系统常用位置创建桌面入口（macOS 应用程序文件夹 `xb_ume 工具箱.app` 可从 Launchpad/Spotlight 启动，无写权限时装到 `~/Applications`；Windows 桌面快捷方式），另有启动器与 `dart run xb_ume:ide --gui` 命令入口；三个 Tab——设备管理（adb/hdc/Xcode 模拟器/idevice_id 发现与选择）、守护进程（状态查询经互斥端口 status 协议、一键重启、IDE 优先级展示）、日志（选中设备的全量设备日志 + 全部调试会话 stdout/stderr 实时展示，支持来源/级别/关键字过滤、暂停、清屏、导出）；`--uninstall` 一并移除桌面入口。
- 守护进程增加单实例接管锁：新实例启动时自动停止旧实例（命令行匹配 + 回环端口互斥双保险），只保留最新实例，避免多实例重复消费事件导致一次点击唤起多个 IDE；`--uninstall` 现在会停止所有 daemon 实例后再清理文件。
- 修复 Windows 下 Android Studio 已安装但检测不到的问题：`_hasAndroidStudio` 原先仅对 macOS 检查二进制路径，现按平台路径（含 `%LOCALAPPDATA%\Programs\Android Studio`）与命令名统一检测；同时修复文档示例中不存在的 `XBUme.app` API，新增 IDE 跳转使用指南 `IDE_JUMP_GUIDE.md`。
