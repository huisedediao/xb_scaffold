# xb_ume GUI 工具箱使用指南

> 电脑端调试助手：设备管理、守护进程管理、手机日志实时查看。
> 零新增依赖、无需编译，随 `dart run xb_ume:ide --install` 一并安装。

## 一、启动方式（三选一）

### 方式 1：命令启动（推荐）

```bash
# 在依赖 xb_ume 的项目目录中
dart run xb_ume:ide --gui
```

### 方式 2：双击桌面入口（安装时自动创建）

`--install` 会在系统常用位置创建 GUI 桌面入口：

| 平台 | 入口位置 | 打开方式 |
|---|---|---|
| macOS | `/Applications/xb_ume 工具箱.app`（若无写权限则装到 `~/Applications`） | 在「应用程序」文件夹双击，或 Launchpad / Spotlight 搜索「xb_ume」；卸载时一并删除 |
| Windows | 桌面快捷方式「xb_ume 工具箱.lnk」 | 双击后 GUI 以最小化窗口运行在任务栏（图标为 dart 图标），页面自动弹出；卸载时一并删除 |

保留的备用启动器（隐藏目录 `~/.xb_ume_ide/` 内）：macOS `xb_ume_gui.command`（Finder 按 `Cmd+Shift+G` 输入 `~/.xb_ume_ide` 直达，首次被 Gatekeeper 拦截时右键 → 打开）；Windows `XBumeGui.bat`。

### 方式 3：直接运行部署副本

```bash
dart ~/.xb_ume_ide/ide_gui.dart    # macOS
dart %USERPROFILE%\.xb_ume_ide\ide_gui.dart   # Windows
```

### 启动行为

- 启动后自动打开浏览器访问 `http://127.0.0.1:46129`（端口被占用时自动顺延）；
- **单实例**：已有 GUI 在跑时，再次启动只会新开一个浏览器页面，不会出现多个实例；
- 服务进程窗口保持开启即页面可用，关闭窗口（或 Ctrl-C）即退出 GUI。

## 二、界面总览

页面为暗色主题，顶部三个 Tab 切换模块，右上角圆点为 WebSocket 连接状态（绿色 = 页面与服务端通信正常）：

| Tab | 模块 | 一句话说明 |
|---|---|---|
| 设备 | 设备管理 | 识别电脑上连接的手机，选择一台作为日志来源 |
| 守护进程 | daemon 管理 | 查看 IDE 跳转守护进程状态、一键重启、IDE 优先级 |
| 日志 | 日志查看 | 实时展示选中手机的日志 + Flutter 控制台输出 |

## 三、功能详细使用说明

### 1. 设备管理（Tab「设备」）

**功能**：自动发现连接到电脑的手机/模拟器，可选中一台。

**支持的平台与工具依赖**：

| 平台 | 发现方式 | 依赖 |
|---|---|---|
| Android（真机/模拟器） | `adb devices -l` | Android 平台工具（flutter 开发环境一般已具备） |
| 鸿蒙（真机/模拟器） | `hdc list targets` | HarmonyOS SDK 的 hdc 命令 |
| iOS 模拟器（仅 macOS） | `xcrun simctl list devices booted` | Xcode |
| iOS 真机（仅 macOS） | `idevice_id -l` | `brew install libimobiledevice`（未装则不显示） |

**使用步骤**：

1. 手机用数据线连上电脑（模拟器/无线调试同理）；
2. 进入「设备」Tab，列表每 3 秒自动刷新，也可点「刷新设备」立即扫描；
3. 点击设备行首的单选框选中该设备——选中状态会同步到「日志」Tab 的设备下拉框；
4. 状态列含义：`device`（绿色，正常）/ `offline`、`unauthorized`（红色，需在手机上允许 USB 调试或重插）；
5. 设备拔出后日志源自动停止，重新插入自动恢复。

### 2. 守护进程管理（Tab「守护进程」）

**功能**：查看与管理 IDE 跳转功能的常驻守护进程（daemon）。

**状态卡片**展示：

- 运行状态：`运行中`（绿色，含 pid 与已运行时长）/ `未运行`（红色）；
- 已接入的调试会话列表：每条为「来源 → VM service 地址」，即当前连着哪些 `flutter run` 会话；
- IDE 优先级：当前生效的 IDE 唤起顺序（读取 `~/.xb_ume_ide/config.json`）。

**使用步骤**：

- **查看状态**：进入 Tab 自动查询，或点「刷新」；
- **重启守护进程**：点「重启守护进程」→ 确认弹窗 → 自动完成「杀掉所有旧实例 → 启动新实例 → 等待就绪」，成功后显示新状态。适用场景：修改配置后不生效、daemon 行为异常、升级脚本后刷新实例。正在调试的会话断开后会自动重连，无需重启 `flutter run`；
- **修改 IDE 优先级**：点「打开配置文件」用系统编辑器打开 `config.json`，改完保存立即生效（daemon 每次跳转时重读）。

### 3. 日志查看（Tab「日志」）

**功能**：实时展示选中设备的日志，双数据源合并。

**两个数据源**（可分别开关）：

| 来源 | 内容 | 对应场景 |
|---|---|---|
| 设备日志（logcat / hilog / iOS log） | 选中手机的**全量**系统日志：Flutter 输出、native 层、系统组件、三方 SDK——**包含 flutter run 控制台不打印的内容** | 排查 native 崩溃、看被控制台过滤掉的日志 |
| Flutter 输出（stdout/stderr） | 全部调试会话中 app 进程的标准输出/错误流，与 `flutter run` 控制台中 app 输出的部分一致 | 专注看 Flutter 层 `print`/`debugPrint`/异常输出 |

**使用步骤**：

1. 先在「设备」Tab（或本 Tab 左上角下拉框）选中设备——未选设备时只有「Flutter 输出」源工作；
2. 电脑上正常 `flutter run` 启动调试，日志开始实时滚动；
3. 用工具栏过滤：
   - **来源勾选**：只看设备日志或只看 Flutter 输出；
   - **级别勾选**：V / D / I / W / E，如排查崩溃时只留 W+E；
   - **关键字**：对消息和 tag 做不区分大小写的包含匹配；
4. 「暂停」停止页面滚动（服务端仍在收集，取消暂停后继续渲染新日志）；「清屏」清空当前显示；「导出」下载当前缓冲的全部日志为 txt；
5. 每行格式：`时间 [来源] TAG 消息`，级别着色（E 红 / W 黄 / D 蓝 / I 白 / V 灰）；
6. 服务端保留最近 5000 行（环形缓冲），更早的自动丢弃以防内存膨胀。

**注意**：

- 「Flutter 输出」源覆盖**所有**调试会话（多设备同时调试时不区分设备），可用关键字过滤；
- 设备日志流在设备断开时自动重连；对应命令行工具（adb/hdc 等）未安装时会提示一次，不会刷屏。

## 四、常见问题

| 现象 | 处理 |
|---|---|
| 浏览器没有自动打开 | 手动访问启动日志中打印的地址（如 `http://127.0.0.1:46129`）；`dart run xb_ume:ide --gui` 是 detached 启动，终端无输出属正常 |
| 双击 `.command` 提示无法打开 | macOS 隐藏目录用 `Cmd+Shift+G` 直达；被拦截时右键 → 打开 |
| 设备列表为空 | 确认对应工具可用：终端能运行 `adb devices` / `hdc list targets`；iOS 真机需 `brew install libimobiledevice`；手机需开启 USB 调试并授权 |
| 守护进程显示未运行 | 执行 `dart run xb_ume:ide --install` 安装并启动（详见 `IDE_JUMP_GUIDE.md`） |
| 日志页没有「设备日志」 | 未选中设备，或选中设备的平台工具不可用；「Flutter 输出」源不依赖设备选择，但需要 daemon 正在运行且有调试会话接入 |
| 跑 `flutter test` 时报 `Unable to connect to flutter_tester process` | daemon 会轮询本机 VM service，可能干扰测试进程握手；跑全量测试前先停 daemon（`pgrep -fl ide.dart` 找到 pid 后 kill） |
| Windows 下启动器窗口一闪而过 | 先用命令 `dart %USERPROFILE%\.xb_ume_ide\ide_gui.dart` 前台启动看报错（常见原因：dart 不在 PATH） |

## 五、卸载

```bash
dart run xb_ume:ide --uninstall
```

会停止守护进程、删除整个 `~/.xb_ume_ide/` 目录（含 GUI 脚本、启动器与配置）。

## 六、相关文档

- IDE 跳转功能与守护进程安装：[IDE_JUMP_GUIDE.md](IDE_JUMP_GUIDE.md)
- 包总体说明：[README.md](README.md)
