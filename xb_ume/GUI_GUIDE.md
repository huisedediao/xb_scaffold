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

页面为暗色主题。页头左侧为 Tab，右侧为**全局设备选择器与 VM 会话状态**（不随 Tab 切换，任何页面都能选设备）；右上角圆点为 WebSocket 连接状态（绿色 = 页面与服务端通信正常）：

| 区域 | 模块 | 一句话说明 |
|---|---|---|
| 页头右侧 | 设备选择器 | 下拉框自动发现连接的手机并可选定一台，旁有「刷新」按钮（同时立即扫描设备与刷新会话状态） |
| 页头右侧 | VM 会话选择器 | 下拉列出已接入的调试会话（默认项 `未选择会话（共 N 个）`，选择后才打印对应会话的日志；每个会话**显示应用包名**如 `example · port:56782`，取自 `package:<包名>/main.dart`），选中某个会话后「日志」页的 Flutter 输出只显示该应用，日志行的 tag 列也显示应用包名；守护进程未运行时显示红色 `VM 未连接`；悬停看会话详情 |
| Tab 守护进程 | daemon 管理 | 查看守护进程状态、一键重启、IDE 优先级 |
| Tab 日志 | 日志查看 | 实时展示选中手机的日志 + Flutter 控制台输出 |
| Tab 异常 | 实时异常捕获 | 实时捕获调试会话的框架异常与未捕获异常（App 零接入），栈帧可跳 IDE，新异常右上角红浮层提醒，详见下文「异常」 |
| Tab 应用沙盒 | 沙盒文件浏览 | 浏览/下载/删除选中调试会话（app）沙盒内的目录与文件（删除需确认）；文件可新标签页「查看」（含搜索/过滤）或「监听」（实时 tail），详见下文「应用沙盒」 |
| Tab 路由栈 | 路由栈查看 | 展示选中调试会话 app 的 Navigator 路由栈（栈底 → 栈顶），详见下文「路由栈」 |
| Tab Network | 网络请求查看 | 查看选中会话 app 内 xb_ume Network 模块捕获的请求（与手机端面板同源），支持过滤/详情/复制 cURL/重发/清空，详见下文「Network」 |
| Tab Storage | shared_preferences 读写 | 读写 app 的 shared_preferences 存储文件（Android shared_prefs XML / 鸿蒙 preferences / iOS plist），key/值可编辑、删除、新增，写回手机，详见下文「Storage」 |
| Tab 自动化 | 场景自动化回归 | JSON 场景（tap/input/swipe/断言…）在选中会话上一键重放，逐步报告 + 失败截图；另支持 AI 驱动（自然语言目标→截图→AI 决策→执行循环，详见下文「自动化路径」） |

## 三、功能详细使用说明

### 1. 设备管理（页头右侧，全局）

**功能**：自动发现连接到电脑的手机/模拟器，可选中一台。位于页头右侧，不随 Tab 切换。

**支持的平台与工具依赖**：

| 平台 | 发现方式 | 依赖 |
|---|---|---|
| Android（真机/模拟器） | `adb devices -l` | Android 平台工具（flutter 开发环境一般已具备） |
| 鸿蒙（真机/模拟器） | `hdc list targets` | HarmonyOS SDK 的 hdc 命令 |
| iOS 模拟器（仅 macOS） | `xcrun simctl list devices booted` | Xcode |
| iOS 真机（仅 macOS） | `idevice_id -l` | `brew install libimobiledevice`（未装则不显示） |

**使用步骤**：

1. 手机用数据线连上电脑（模拟器/无线调试同理）；
2. 打开页头右侧的设备下拉框（列表每 3 秒自动刷新，也可点旁边「刷新」立即扫描）；
3. 在下拉框中选中设备——选中后「日志」Tab 的设备日志源即切到该设备；下拉项尾部括号内为设备状态；
4. 状态列含义：`device`（绿色，正常）/ `offline`、`unauthorized`（红色，需在手机上允许 USB 调试或重插）；
5. 设备拔出后日志源自动停止，重新插入自动恢复。

### 2. 守护进程管理（Tab「守护进程」）

**功能**：查看与管理 IDE 跳转功能的常驻守护进程（daemon）。

**状态卡片**展示：

- 运行状态：`运行中`（绿色，含 pid 与已运行时长）/ `未运行`（红色）；
- 已接入的调试会话列表：每条为「来源 → VM service 地址」，即当前连着哪些 `flutter run` 会话；
- IDE 优先级：可拖拽排序的列表（每项前有 ☰ 拖动标识），拖完自动保存到 `~/.xb_ume_ide/config.json` 的 `ideOrder`；未安装的 IDE 灰色标注「未安装」（daemon 唤起时自动跳过）；

**使用步骤**：

- **查看状态**：进入 Tab 自动查询，或点「刷新」；
- **重启守护进程**：点「重启守护进程」→ 确认弹窗 → 自动完成「杀掉所有旧实例 → 启动新实例 → 等待就绪」，成功后显示新状态。适用场景：修改配置后不生效、daemon 行为异常、升级脚本后刷新实例。正在调试的会话断开后会自动重连，无需重启 `flutter run`；
- **修改 IDE 优先级**：拖动条目前面的 ☰ 到目标位置，松手即保存（daemon 每次跳转时重读，立即生效）；每次进入本页会自动扫描本机已安装的 IDE，新装的自动追加到列表末尾并写回配置（已在配置中、后来卸载的仍保留并标注「未安装」）；「恢复默认」一键写回完整默认名单；也可点「打开配置文件」用系统编辑器改。

### 3. 日志查看（Tab「日志」）

**功能**：实时展示「VM 会话 + 设备」组合日志，双数据源合并。

**过滤规则**（由页头右侧的两个下拉框决定）：

| 选择状态 | 展示内容 |
|---|---|
| VM、设备都未选 | **不打印**（提示先在页头右侧选择） |
| 只选 VM | 仅该会话的 Flutter 输出 |
| 只选设备 | 该设备的设备日志 + **属于该设备**的 VM 输出（一台设备可同时跑多个 app，即多个 VM） |
| 同时选 VM + 设备 | 两个源**都打印**（并集）：选中的 VM 输出 + 选中设备的日志，互不约束 |

VM→设备的归属判定（仅「只选设备」时用于筛选 VM 输出）：会话来源带设备号时（如 `adb:SERIAL#port:x`）**精确匹配**；否则按平台推断（getVM 的 operatingSystem 与设备平台比对，如 mac 上的 VM 永远不会归属到手机）。同平台多台设备同时在线时，无设备号的会话无法区分属于哪台（已知局限）。切换选择只改变显示，**不清屏、不中断采集**。

**两个数据源**（可分别开关）：

| 来源 | 内容 | 对应场景 |
|---|---|---|
| 设备日志（logcat / hilog / iOS log） | 各设备的**全量**系统日志：Flutter 输出、native 层、系统组件、三方 SDK——**包含 flutter run 控制台不打印的内容** | 排查 native 崩溃、看被控制台过滤掉的日志 |
| Flutter 输出（stdout/stderr） | 全部调试会话中 app 进程的标准输出/错误流，与 `flutter run` 控制台中 app 输出的部分一致 | 专注看 Flutter 层 `print`/`debugPrint`/异常输出 |

**使用步骤**：

1. 在页头右侧按需选择设备/VM 会话（默认全部）；
2. 电脑上正常 `flutter run` 启动调试，日志开始实时滚动；
3. 用工具栏过滤（按作用对象分成两个组框，作用范围从布局即可看出）：
   - **「设备日志」组**：勾选启用后，组内的级别筛选（V·详细 / D·调试 / I·信息 / W·警告 / E·错误）生效；取消启用时整组置灰不可点；未选设备时组内无日志（设备在页头右侧选择）；
   - **「Flutter 输出」组**：只控制 Flutter 输出的显隐，**不受级别筛选影响**（stderr 错误通道输出标为 E·错误着色）；来源由页头右侧的会话下拉框选择（默认「未选择会话」，未选会话且未选设备时不打印）；悬停组框可看说明；
   - **关键字**：空格分隔多个关键字，日志包含**任一**关键字即显示（对消息和 tag 不区分大小写）；输入防抖 200ms；实时生效——新日志到达时只增量追加命中行，无命中时 DOM 完全不动，**选中文字/复制不会被刷新打断**；新行只在底部追加，往上翻阅时不会被强制拉底，滚回底部后恢复跟随
4. 「到顶」「到底」一键滚动到最早/最新日志（到底后恢复自动跟随新日志；到顶后新日志不会拉走视图）；「复制」把框中当前显示（含过滤）的全部日志逐行复制到剪贴板（直接读渲染行，所见即所得）；「暂停」停止页面滚动（服务端仍在收集，取消暂停后继续渲染新日志）；「清屏」清 空当前显示；「导出」下载当前缓冲的全部日志为 txt（导出与复制的区别：导出走服务端 5000 条环形缓冲含未显示来源，复制只取框中当前显示的行）；
5. 每行格式：`时间 [来源] TAG 消息`，级别着色（E 红 / W 黄 / D 蓝 / I 白 / V 灰）；
6. 服务端保留最近 5000 行（环形缓冲），更早的自动丢弃以防内存膨胀。

**注意**：

- 「Flutter 输出」源覆盖**所有**调试会话：多个 Flutter 应用同时接入（无论多台手机还是同一台手机装多个 app）时，每行 tag 列显示会话来源（如 `adb:设备号#port:本机端口`），可用关键字过滤区分不同应用的输出；IDE 跳转各会话独立处理，互不影响；
- 设备日志流在设备断开时自动重连；对应命令行工具（adb/hdc 等）未安装时会提示一次，不会刷屏。

## 四、应用沙盒（Tab「应用沙盒」）

**前提**：在页头右侧选中某个 VM 会话后，本 Tab 才展示内容；未选择时显示「请先选择 VM」。

**原理**：通过 VM service 的 evaluate 在 **app 进程内**执行 dart:io 代码读写文件系统，零 app 端改动，适用于任何 debug 模式的 Flutter 应用（release 无 VM service，不可用）。

**使用**：

1. 页头右侧选中调试会话后，Tab 内自动定位 app 的可访问根目录（多入口自动探测：HOME、系统临时目录、平台约定沙盒路径——鸿蒙为 `/data/storage/el2/base`、`/data/storage/el1/base`，Android 会在 app 内读 `/proc/self/cmdline` 取包名并优先探测 `/data/data/<包名>`、`/data/user/0/<包名>`、`/storage/emulated/0/Android/data/<包名>/files` 等本应用沙盒，取可成功列目录的作为入口）；HOME 不可访问时（如鸿蒙真机）自动回退到沙盒映射路径，多个入口时顶部显示「入口」快捷链接；
2. 点目录名逐层进入，点面包屑逐级返回；列表显示名称/大小/修改时间，`[链接]` 标记的是符号链接（不可进入，下载时按文件尝试）；访问受限的目录会提示「无权限访问」并列出可尝试的其他入口；
3. 文件点「下载」保存原文件；目录点「下载 .tar」递归打包（USTAR 无压缩）下载；
4. **上传**：每行都有「上传」链接——目录行把本地文件写入该目录，文件行写入其所在目录。选择本地文件后经 base64 编码上传、app 内 eval 分块写入（同名覆盖、深层目录自动创建，单个文件上限 12MB），完成后自动刷新列表；文件名禁止含路径分隔符或 `..`（防目录穿越）；
5. 点行尾「删除」移除文件或文件夹（**文件夹递归删除全部内容**）。删除是敏感操作：点击后弹出确认框（显示类型、名称与完整路径），确认后才执行，且**不可恢复**；删除成功后自动刷新当前目录。后端会拒绝删除文件系统根等不合法路径；
6. 文件行点「查看」「监听」会在浏览器**新标签页**打开独立页面（不影响主页面浏览），两页均支持搜索与过滤（可同时使用，先过滤再在筛出的行内高亮搜索，**过滤命中的关键字同样会高亮**）：
   - **查看**：分块流式读取并展示文件当前全部内容（静态快照，**不限文件大小**，读取中显示进度）；搜索高亮全部匹配处并显示匹配总数，过滤只保留匹配行；
   - **监听**：GUI 版 `tail -f`——从文件末尾开始，每 2 秒轮询增量并追加显示（文件轮转/重建会提示，可点「重新开始」；支持「暂停/继续」）；搜索高亮新增内容，过滤只保留匹配行；**内存保护：最多保留最近 5 万行**，超限丢弃最早行并在状态栏提示累计丢弃量（完整内容用「查看」页或「下载」本地看）；
   - 分段读取已按 UTF-8 边界切割，多字节字符（中文等）不会被切断出现乱码。

**说明**：文件/文件夹下载**无大小限制**——分段流式传输（每次 1MB + gzip 压缩经 VM service 中转），app 与本机内存占用恒定；大文件下载耗时随体积线性增长（实测约 2MB/s，30MB 文件约 15 秒）；tar 不保留空目录。

**注意**：可浏览范围是 app 进程可见的全部路径，请勿在不可信环境开启本功能。

## 五、路由栈（Tab「路由栈」）

**前提**：在页头右侧选中某个 VM 会话后，本 Tab 才展示内容；未选择时显示「请先选择 VM」。

**展示内容**：app 内所有 Navigator 的路由栈，按栈底 → 栈顶排列；每条显示：

- **栈序**（含「栈底」「栈顶」标注）；
- **路由名**（`settings.name`；匿名 push 的页面显示 `<unnamed>`）；
- **类型**（MaterialPageRoute / DialogRoute / BottomSheet 等，弹窗也是路由栈的一层）；
- **参数**（`settings.arguments` 的摘要，悬停看完整内容；复杂对象只显示 toString/类型）；
- **文件**（该页面对应的源码文件名：类声明行，如 `device_advanced_config_page.dart:15`，悬停看完整路径与类名；无法解析时显示 `—`）；
- **Widget / State / Notifier**（页面 Widget 类名 / 其 State 类名 / ChangeNotifier 类名，无则显示 `\`；**State 有多个 CN 字段时全部列出，页面用 Provider `Consumer2/3/4<...>` 监听的多个 CN 也会被识别**——泛型参数逐个验证是否 CN 子类）；**点击名称会跳到「实例」Tab 并自动查找该类的实例**（复用实例 Tab 的 Element 树 + 堆扫描双通道查找）；
- **定位**（行尾「跳转」链接，见下文）；
- **操作**（行尾「pop」/「remove」链接，见下文「路由操作」）；
- 栈顶当前路由带 **● 当前** 高亮标记。

嵌套 Navigator（如底部导航每个 Tab 内的 Navigator）分组展示为 Navigator #1、#2… 。

**跳转到源码**：点击行尾「跳转」会用配置的 IDE 打开「文件」列对应的源码文件（定位到页面 Widget 类声明行，不到具体行列）。实现原理：收集该路由子树内的 widget（浅→深）→ 逐个查其类的定义库 → 跳过 Flutter 框架内置类，取第一个能解析到本机源文件的用户类 → 按 `ideOrder` 优先级唤起 IDE（与守护进程的 IDE 跳转同一份 `~/.xb_ume_ide/config.json` 配置）。项目根从调试会话的库路径自动推导，包依赖经项目的 `.dart_tool/package_config.json` 解析；依赖包源码不在本机或整条路由都是框架组件时会提示失败原因。IDE 一个都没找到时会把路径复制到剪贴板兑底。

**刷新方式**：切换到本 Tab 自动拉取一次；也可点「刷新」手动拉取（导航、开关弹窗后点刷新即可看到最新栈）。

**Widget / State / Notifier 列原理**：纯静态解析、零 VM 调用——复用「跳转」已定位 到的用户 widget 类源文件：State 名取 `createState()` 的返回类型；ChangeNotifier 名 取 State 字段里沿 `extends` 链能到 ChangeNotifier 的类型，加上同文件内 `ConsumerN<...>` 泛型参数（均仅搜本机项目 `lib/`，框架类型与外部包类型自然跳过）。解析在浏览器加载后自动进行，无需点击。

**原理**：通过 VM service 在 app 进程内（`navigator.dart` 库上下文）读取 NavigatorState 的路由历史，零 app 端改动；仅 debug 模式可用。

### 路由操作（pop / remove / pushNamed）

每个 Navigator 分组头部有 **pushNamed 输入框**：输入路由名回车或点按钮，会在 app 内经 `Navigator.pushNamed` 压入该名字的路由。实现上先经 `_routeNamed` 校验：名字解析不出立即报 `UNKNOWN`（名字未注册或该 Navigator 未配置 routes/onGenerateRoute）；部分路由框架（如 Get）对未知名字是抛错而非返回 null，此时提示 `app 内执行报错（FlutterError）`。

行尾「操作」列：

- **pop**：仅栈顶且非唯一路由时可用，走转场动画（与用户手势返回一致）；
- **remove**：任意非唯一路由可用，无转场直接出栈（`Navigator.removeRoute`），适合清理中间残留路由（如反复 push 后忘记退出的测试页）。

操作成功后表格自动刷新（双次延迟，避免拉到出栈前的旧栈）；失败时链接变 ✗，悬停看原因（如「仅栈顶路由可 pop」「栈里只剩一条路由，不能移除」——唯一路由受保护，避免整窗白屏）。

**macOS 桌面会话注意**：app 窗口切到后台（最小化/被遮挡到 hidden）后 Flutter 会暂停帧调度，未完成的转场会冻结在过渡态，此时 pop/remove 虽返回成功但出栈要等窗口回前台、转场完成后才真正生效，路由栈也会显示卡在过渡态的路由。把 app 窗口带回前台即可恢复；真机/模拟器会话无此问题。

### 泄漏检测

工具栏的**「泄漏检测」按钮**：对本会话浏览过的页面 State 类（Widget/State 列解析成功过的类会自动累积，路由栈刷新时已退出的页面类也会记入；另可在输入框手动补类名，逗号分隔）做一次**GC 后堆扫描**：先经 VM service 触发 `_collectAllGarbage`，再对每个类分别统计「树上实例数」（Element 树遍历）与「堆上实例数」（getClassList + getInstances），结果分四类：

- ✓ **栈中存活**：GUI 记录的当前栈里有该类（正常）；
- ✓ **树上存活**：树上有实例（同名类被其它活跃页面使用时不误报）；
- ⚠ **疑似泄漏**（红色）：页面已退出路由栈、GC 后堆上仍有实例 —— 通常是静态变量 / 监听器 / 动画 / 全局 key 等持有，可配合「实例」Tab 展开字段树定位引用链；
- ✓ **已释放**：堆上已无实例。

判定要点：页面被上层不透明页面覆盖时其元素会从树上临时卸载（State 仍由 Route 正常持有），此时树上计 0 属正常，不会误报；类名来自静态解析，带泛型的 State（如 `_FooState<T>`）会自动剥掉泛型再去堆里匹配。记录仅存于浏览器内存（刷新页面重置），多扫几轮路由栈可让候选类更全。仅 debug 模式可用。

## 六、Network（Tab「Network」）

**编辑重放与响应 diff**：每条请求详情头部除「复制 cURL」「重发」外，还有「**编辑重放**」——展开编辑表单（URL / 请求头每行 `k: v` / 请求体，均预填原值），改完点「执行重放」由**电脑直接发起**（不经 app，method 固定为原请求方法），响应展示在「重发响应」卡内，并自动与原响应做**逐字段 diff**：JSON 递归对比（对象按字段、数组按下标），●改 / +增 / −删 三种标注 + 差异计数，完全一致时显示绿色「✓ 与原响应完全一致」；原/新响应任一非 JSON 时降级为提示（人工比对两段响应体）。重放后编辑内容保留在表单中，可连续微调多次重放对比。典型用途：改请求参数验证服务端行为、对比接口版本差异、复现边界参数。


展示**选中调试会话 app 内 xb_ume Network 模块捕获的请求**（与手机端 ume 面板同源数据，不是 GUI 自己抓包），需 app 接入 xb_ume 并配置了网络拦截（`XBUmeHttpClient` / `XBUmeDioInterceptor`）。

**使用**：
1. 页头右侧选中调试会话后切到本 Tab 自动拉取；也可点「刷新」重新拉取；
2. 顶部输入框实时过滤（匹配 URL/方法/状态码/错误信息）；
3. **点击行展开/收起详情**（可同时展开多条，互不影响；展开的行高亮）：Query、请求头（app 端已对敏感头脱敏，如 `Authorization: ***`）、请求体、响应头、响应体（JSON 自动格式化）、失败时附错误堆栈；
4. 行尾或详情顶部可操作：
   - **复制全部**：把该请求展开详情的全部内容复制为纯文本（概要行含时间/状态码/耗时，加 Query、请求头、请求体、响应头、响应体、错误堆栈，以及重发响应（如有）；空节省略）；
   - **cURL**：把该请求复制为 curl 命令（含方法/URL/请求头/请求体）到剪贴板；
   - **重发**：在**电脑上**按原方法/URL/请求头/请求体直接发起 HTTP 请求（不经手机），结果附在该条详情下方（状态码/响应头/响应体）；适合排查「换环境/换参数是否还报错」；
   - **清空**：清空 app 内 ume 的 Network 记录（与手机端面板的清空等效）；

**原理**：通过 VM service 在 `package:xb_ume` core 库上下文读 `XBUme.controller.network`（同步 getter，零 app 端改动）；仅 debug 模式可用，app 未接入 xb_ume 时会提示错误。

## 七、Storage（Tab「Storage」）

读写 app 的 **shared_preferences 数据**——Android 为 `/data/data/<包名>/shared_prefs/*.xml`（`<map>` 格式）；鸿蒙为 app 沙盒 preferences 目录（`/data/storage/el2/base/preferences/`，如 `FlutterSharedPreferences`，无扩展名，`<preferences>` 格式）；iOS 为沙盒 `Library/Preferences/<bundleId>.plist`（binary plist，GUI 端经 plutil 转换读写）：列出全部 prefs 文件，展示每个 key 的类型与值，可直接编辑。

**使用**：
1. 顶部下拉选择 prefs 文件，点「刷新」重新读取；
2. 表格中可编辑：值（boolean 用下拉；set 用逗号分隔成员）；已有条目的 **key 与类型不可修改**（key 改名易导致 app 端读写错位，类型由文件解析决定避免类型与值不匹配），仅「新增」行可填写 key 名与选择类型；点行尾「删除」移除该项；点「新增」添加空行；
3. 点「**保存写入（写回手机）**」把整份 XML 写回手机；按钮短暂变为「✓ 已写入」；
4. 关键字过滤实时匹配 key/value，命中片段**绿色高亮**（过滤生效时 key/值以高亮文本展示，清空过滤后值恢复输入框编辑，key 始终为只读文本）；

**生效时机（重要）**：修改写入的是手机上的存储文件，但 shared_preferences 插件在 app 内有**内存缓存**——已加载过的值不会立刻变化，**重启 app 后生效**。

**原理**：通过 VM service 在 app 进程内读 `/proc/self/cmdline` 取包名（Android）、探测平台对应存储路径并直读/覆写存储文件（零 app 端改动）；Android / 鸿蒙 / iOS debug 会话可用。保存时按平台格式重建整个文件（Android `<map>` / 鸿蒙 `<preferences>` / iOS plist 经 plutil 转 binary 写回）。iOS 的 plist 复杂类型（dict/date/data）不支持编辑但保存时原样保留。

## 八、实例（Tab「实例」）

**在 GUI 上直接查看与修改 app 运行时内存里的对象**——比如某个 State 里的 `int age`、Provider 的 ChangeNotifier 里的字段。仅 debug 会话可用。

**定位实例的三条途径**：
1. **注册表 Store**：app 端调 `XBUme.registerStore(id, obj)` 注册的对象（如 Provider 的 notifier、全局单例），点「注册表 Store」直接列出；需 app 端 xb_ume 支持该 API（旧版本会提示更新依赖并重启 app）；
2. **Element 树查找**：输入类名点「查找实例」，遍历当前 Widget 树找存活的 State 实例（来源标记「Element 树」）；
3. **堆扫描**：同时用 `getClassList + getInstances` 捞出堆上该类的全部实例（来源标记「堆扫描」），覆盖不在树上的纯逻辑对象；结果去重合并展示。

**字段树**：点行内「查看字段」展开实例字段树——字符串/数字/bool 直接显示值；List/Map 显示条目（上限 100）；嵌套对象递归展开（默认 2 层）；引用可点「展开」继续下 钻；循环引用/已回收实例有明确标注。标题栏有**「仅用户字段」勾选框（默认勾选）**：勾选时隐藏 Flutter/dart SDK 类声明的字段（如 ChangeNotifier 内部的 `_count`/`_listeners`），只看业务字段；取消勾选恢复全部。

**刷新对比**：点字段树标题栏「刷新」重新拉取，**值有变化的字段整行高亮（● + 橙底）并附删除线旧值**（如 `● _count int 42 旧: 1`）；基础值变化、null↔对象、List/Map 长度变化都会标注；点「展开」下钻的深层字段也纳入对比基线；「编辑」保存后的自动刷新会直接显示本次写回的新旧对比。首次打开或切换实例时重新建立基线、不标注。

**编辑写回**：基础类型字段（int/double/bool/String）行尾有「编辑」，输入新值保存即通过 VM service 写回 app 内存（private 字段也可写）；ChangeNotifier 类型的实例写回后会自动 `notifyListeners`（状态栏提示），界面立即刷新。final 字段/不存在字段会返回明确错误。

**原理**：注册表经 VM service 在 `xb_ume_store_registry.dart` 库上下文 eval 读注册 Map；查找走 Element 树遍历 + 堆扫描双通道；字段树用 `getObject` 递归展开；写回是在实例上下文 eval 字段赋值表达式（eval 作用域为实例所属库，私有可见）。

## 九、状态面板（Tab「状态」）

**ChangeNotifier 状态聚合视图**——一屏看清 app 内活跃的 ChangeNotifier（控制器/状态对象）：实例数、监听者数、字段摘要。仅 debug 会话可用。

**使用**：切到「状态」Tab 自动扫描，或在输入框手动补充类名（逗号分隔）后回车。表格列：

| 列 | 含义 |
|---|---|
| CN 类 | 类名，点击跳「实例」Tab 自动查找该类实例 |
| 来源 | 树上（自动发现）/ 手动（输入框补充） |
| 实例数 | GC 后堆扫描的该类全部实例数（getInstances totalCount） |
| 监听者 | 该类首个实例的 ChangeNotifier 监听者数（读 `_listeners` 非 Null 槽计数，老版 SDK 读 `_count` 字段）；无实例或读不到显示 ? |
| 字段摘要 | 首个实例的字段预览（已过滤 `_listeners`/`_count`/`_notificationCallStackDepth` 等 CN 内部机制字段） |

**候选类自动发现**（无需手动输入）：
1. Element 树上 State 本身是 ChangeNotifier 的（如框架内控制器）；
2. Element 树上 runtimeType 带泛型实参的 State（如 `XBWidgetState<ChoosePageVM>`）——提取泛型实参类名，再沿 super 链校验（getObject 逐级查 super，上限 12 跳）确认其确实继承 ChangeNotifier 才入候选（GetX 的 `GetBuilderState<GetMaterialController>` 之类非 CN 实参会被拦掉）。

**注意**：监听者数/字段摘要取该类**首个实例**（同类多实例状态可能不同，全量与实时查看点类名跳「实例」Tab）；聚合是快照不是订阅，需手动重扫刷新。

## 十、Widget 树浏览（Tab「Widget树」）

**前提**：页头选中 VM 会话；仅 debug 模式可用。

**布局**：左树右图——左侧 Element 树，右侧 app 实时截图叠加高亮框。

**使用**：

1. 点「刷新树 + 截图」：一次 eval 拉全 Element 树（含每个节点的屏幕 bounds）并抓取当前截图；树默认展开到第 6 层，更深层级点 ▸ 展开；
2. 点击树节点：右侧截图上红框高亮该节点的屏幕位置，工具栏信息条显示深度/类型/key/bounds；选中被折叠的节点会自动展开其祖先链并滚动定位；
3. 点击截图任意位置：选中该位置上的**业务组件**（locator 同款判定——沿命中链向上找 `creationLocation` 非 Flutter SDK 的最近组件，优先非 pub-cache），信息条显示组件类型、宽高、源文件：行：列，以及四向间距（`↑10.0(XBCell某组件)` / `↓12.0(parent)`，与手机端 locator 同算法，截图上叠加黄色参照框与距离标注）；树同步滚动定位。若命中链上全是 SDK 组件则提示无业务组件；
4. 过滤输入框按类型/key 即时筛选，显示匹配节点及其祖先链（根到匹配节点的完整路径）；「展开全部/收起全部」一键操作。

**说明**：bounds 由 app 内 `localToGlobal(paintBounds)` 实时计算（逻辑像素），按 devicePixelRatio 对齐截图物理像素；每个 Element 都输出其 renderObject 子树的 bounds（组件节点高亮=其实际渲染范围）。超过 24 层的深层节点不真实缩进（避免行宽过 大导致内容横向滚出视口），行首以灰色「祖先/父级/」前缀标识层级位置。SDK/系统包装类节点在树中以淡化样式展示（仅视觉，不影响点选），方便快速找到业务组件。刷新树与截图是两次独立抓取，app 界面若在两次抓取间变化，高亮位置可能轻微偏移，再点一次刷新即可。

## 十一、自动化路径（Tab「自动化」）

**前提**：页头选中 VM 会话；仅 debug 模式可用。场景存电脑端 `~/.xb_ume_ide/scenarios/*.json`（与 app 零侵入，全部通过 VM service eval 驱动）。

**用途**：把「点这里→输入这个→断言那个」的回归验证步骤存成 JSON 场景一键重放，逐步给 status/耗时/期望 vs 实际/失败截图。

**步骤类型**（JSON 数组，每步一个对象）：

| type | 参数 | 说明 |
|---|---|---|
| tap | x, y, phys? | 注入 PointerDown/Up；`phys:true` 为截图物理像素坐标，否则逻辑像素 |
| input | text | 向当前焦点输入框注入文本（需先 tap 输入框建立 TextInputConnection，否则报「无焦点输入框」） |
| swipe | x1,y1,x2,y2, ms?, phys? | 8 段插值 move 模拟拖动/滚动（move 事件带递增 timeStamp 与显式 delta，真实触摸语义，慢拖/fling 均可触发滚动） |
| wait | ms | 等待 |
| back | — | pop 栈顶路由（已是最后一个路由则报错） |
| navigate | name | pushNamed（app 未配命名路由表会报 NO_ROUTE_TABLE/UNKNOWN） |
| assertVisible | widget | 树中存在该类型（支持泛型前缀）且 RenderBox 有尺寸 |
| assertRoute | name | 栈顶路由名包含 name |
| assertInstance | class | 堆/树上存在该类实例（GC 后计数） |
| assertText | contains 或 notContains | 全树页面文本（Text/输入框内容，跳过 Offstage）包含/不包含指定文本 |
| assertRequest | urlContains, method?, not?, withinLastMs? | 最近网络请求中有/无匹配记录（时间窗默认 AI 运行起点，回放场景近 5 分钟） |
| assertLog | contains 或 notContains, level?, source?, withinLastMs? | 最近日志（flutter + 设备 logcat/hilog）中存在/不存在匹配行 |
| eval | expr, expect? | 任意 eval 表达式（binding.dart 上下文），结果含 expect 则过 |

**使用**：

1. 场景下拉选已有场景（或直接在 textarea 写步骤 JSON）→ 填「场景名」→「保存」；「格式化」美化 JSON，「删除」删场景；
2. 「▶ 运行」在选中会话上串行执行；默认失败即停（失败步骤截图落盘），勾「失败继续」跑完所有步骤；执行中「■ 停止」在当前步骤结束后跳过余下；
3. 报告表实时刷新：步骤号/类型/状态（绿 pass / 红 fail / 灰 skip）/耗时/期望/实际/失败截图链接；

**说明**：所有注入都走 `GestureBinding.handlePointerEvent` / `TextInput._instance` eval（零 app 侵入）；macOS 桌面 app 长时间后台后帧调度会冻结（push 动画不完成、新页面元素不上树），跑场景前把 app 置前台；步间默认等 700ms（步骤可加 `waitAfter` 覆盖）让 UI 渲染稳定。

### AI 驱动（自动化页底部区块）

**用途**：不想手写 JSON 时，直接用一句自然语言描述目标（如「打开 XBDialogInputDemo 页面再返回首页」），GUI 自动循环：截图 → 把截图 + 目标 + 历史发给 AI → AI 返回操作指令 → 执行 → 再截图看结果 → 直到 AI 判定完成。适合让 AI 探路；跑通后可一键存为场景 JSON，之后不依赖 AI 直接回放。

**配置（「AI 设置」）**：任意 OpenAI 兼容接口（`/chat/completions`，需支持图片输入）——接口地址（填到 `/v1`，如 `https://api.openai.com/v1`）、密钥、支持视觉的模型名（如 `gpt-4o`、`qwen-vl-max`）。配置存 `~/.xb_ume_ide/ai_config.json`，密钥界面打码显示、保存时不覆盖未修改的打码值。

**使用**：页头选中会话 → 输入目标 →「▶ AI 执行」。每轮显示卡片：轮前截图缩略图（点击看大图）/ AI 分析文本 / 步骤执行表（同场景回放样式）。AI 坐标按截图像素自动换算；某步失败时失败截图会反馈给 AI 下一轮修正；执行中「■ 停止」在当前步骤结束后生效；每轮最多 5 步，轮数无上限（AI 判定完成或手动停止结束），跑之前留意 token 消耗。结束后「存为场景」把本次实际执行的步骤拍平保存，可回上方场景回放。

**测试报告**：运行结束（完成/异常终止/手动停止）后自动生成一份自包含 HTML 测试报告（截图 base64 内嵌，单文件可直接转发），落盘在 `~/.xb_ume_ide/scenarios/reports/ai-<runId>.html`；点结束后出现的「⬇ 导出报告」按钮即可下载（GUI 重启后仍可下载当前运行的那份）。报告含：结论（✅ 目标完成 / ❌ 异常终止 + 原因 / ⚠️ 手动停止）、遇到的问题清单（步骤级失败含期望 vs 实际与失败截图、AI 调用重试轮、轮级错误）、总耗时与步数统计（pass/fail）、逐轮执行明细（AI 思考文本 + 步骤表 + 截图内嵌）。

**结构化上下文**：除了截图，GUI 每轮还会自动采集四项数据层证据一并发给 AI——当前路由栈 / 页面文本（全树 Text 与输入框内容，去重，跳过 Offstage 保活页面）/ 最近网络请求（本次运行以来，需 app 接入 network 模块）/ 增量日志（上一轮以来的 E/W 级与含 error/exception/fail/crash 关键字的日志，含 flutter 输出与设备 logcat/hilog）。「AI 设置」里可逐项开关（默认全开；关闭后 AI 消息不含该项、对应断言步骤被忽略）。

**说明**：AI 只能返回白名单内的步骤类型（tap/swipe/input/wait/back/assertVisible/assertInstance/assertText/assertRequest/assertLog/eval，eval 提示慎用）；接口请求失败/超时/回复无法解析为 JSON/未给出有效步骤时自动重试（每轮最多重试 3 次，退避 2s/4s/6s，轮卡片显示重试次数），重试期间仍可手动停止；重试耗尽才终止任务并显示原因；AI 接口的可达性取决于你本机网络（内网 网关或公网 API 均可）。

## 十二、异常（Tab「异常」）

**实时捕获调试会话的异常，App 零接入**：debug 模式下 Flutter 框架自动把异常经 VM service Extension 流上报（`Flutter.Error` 结构化事件，无需 app 做任何事）；GUI 同时解析会话输出流中的未捕获异常块（引擎 `Unhandled Exception:` 与 xb_scaffold `XBErrorHandler catch error:` 两种格式）。10 秒窗口内连续相同的异常自动合并计数（×N）。

**使用**：

1. 切到本 Tab 自动拉取历史异常，之后新异常实时推送（无需手动刷新）；
2. 每条异常卡片展示：时间 / 通道标签（红「框架」/ 橙「未捕获」）/ 来源会话与应用包名 / 合并计数（×N）/ 摘要 / 描述 / 相关 Widget / 栈帧列表；卡片头部行尾「复制」可一键复制本条异常全部内容（头部/摘要/描述/Widget 含文件:行/栈帔逐行，缺省字段自动跳过）；
3. **跳转 IDE**：栈帧中用户代码帧（`package:` 的非 Flutter/dart 帧）行尾有「跳转」，点击按 IDE 优先级（与守护进程同一份 `ideOrder` 配置）打开对应源码行；相关 Widget 的源码位置同样可跳；Flutter/dart 框架帧与无位置帧（如 eval 生成代码）不可跳；
4. 顶部工具栏：「刷新」重拉全部、「清空」清空列表、「关键字过滤」对摘要/描述/Widget/栈帧/来源实时过滤；
5. **红浮层**：新异常到达时页面右上角弹出红色浮层（含摘要与计数），点击跳到本 Tab，停留 12 秒自动消失；「异常」Tab 标题上的红色徽标显示当前异常总数（进入本 Tab 自动隐藏）。

**原理**：GUI 经 daemon 发现各调试会话后，对每个会话同时订阅 Stdout/Stderr/Extension 三条流——Extension 流的 `Flutter.Error` 事件解析出摘要/描述/Widget 位置/栈帧（完整渲染文本也一并保留）；输出流按行喂给状态机，识别异常头行与栈帧行（最多 120 帧，800ms 无新行结算）。栈帧的 `package:` uri 经项目 `.dart_tool/package_config.json` 解析为本机文件路径。仅 debug 模式可用；多会话异常混排但各自标注来源。

**注意（DDS 死锁防护）**：GUI 退出时会主动关闭各会话的流订阅连接（SIGTERM/Ctrl-C 均已处理）——持有流订阅的连接被硬切断（如 `kill -9`、进程崩溃）会让该会话的 DDS 死锁，此后对所有工具（包括 DevTools）无响应，只能重启 `flutter run` 会话。

## 十三、常见问题

| 现象 | 处理 |
|---|---|
| 浏览器没有自动打开 | 手动访问启动日志中打印的地址（如 `http://127.0.0.1:46129`）；`dart run xb_ume:ide --gui` 是 detached 启动，终端无输出属正常 |
| 双击 `.command` 提示无法打开 | macOS 隐藏目录用 `Cmd+Shift+G` 直达；被拦截时右键 → 打开 |
| 设备列表为空 | 确认对应工具可用：终端能运行 `adb devices` / `hdc list targets`；iOS 真机需 `brew install libimobiledevice`；手机需开启 USB 调试并授权 |
| 守护进程显示未运行 | 执行 `dart run xb_ume:ide --install` 安装并启动（详见 `IDE_JUMP_GUIDE.md`） |
| 日志页没有「设备日志」 | 未选中设备，或选中设备的平台工具不可用；「Flutter 输出」源不依赖设备选择，但需要 daemon 正在运行且有调试会话接入 |
| 跑 `flutter test` 时报 `Unable to connect to flutter_tester process` | daemon 会轮询本机 VM service，可能干扰测试进程握手；跑全量测试前先停 daemon（`pgrep -fl ide.dart` 找到 pid 后 kill） |
| Windows 下启动器窗口一闪而过 | 先用命令 `dart %USERPROFILE%\.xb_ume_ide\ide_gui.dart` 前台启动看报错（常见原因：dart 不在 PATH） |
| 页头选中的 VM 会话过一会儿变回「未选择会话」 | 会话 ws 瞬断（热重载/重连）时页面会保持你的选择，连续约 15s 仍缺失才回退；重连后端口变化时按实例指纹自动找回同一会话。若仍频繁掉选，说明该会话连接本身不稳定 |
| Network/Storage/路由栈等 Tab 一直转圈或提示「VM service 响应超时」 | 会话已断开（app 退出或 `flutter run` 停止）；重新选择页头右侧的有效会话即可。另外：用 nohup/后台脚本方式启动 `flutter run` 可能使本机 DDS 无响应（stdin EOF），从真实终端或 IDE 启动调试即可恢复 |
| 重启/被杀 GUI 后某个 `flutter run` 会话对所有客户端无响应（DevTools 也连不上） | GUI 非优雅退出（`kill -9` 或崩溃）时持有流订阅的连接被硬切断，可能触发 DDS 死锁；重启该 `flutter run` 会话即可恢复。新版 GUI 退出时已主动关闭连接规避（`kill -9` 仍无法避免） |

## 十四、卸载

```bash
dart run xb_ume:ide --uninstall
```

会停止守护进程、删除整个 `~/.xb_ume_ide/` 目录（含 GUI 脚本、启动器与配置）。

## 十五、相关文档

- IDE 跳转功能与守护进程安装：[IDE_JUMP_GUIDE.md](IDE_JUMP_GUIDE.md)
- 包总体说明：[README.md](README.md)
