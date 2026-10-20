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

- 调试会话来源标签增强：自动发现时经 `adb forward --list` / `hdc fport ls` 把本机转发端口映射到设备号，会话标签由 `port:端口` 升级为 `adb:设备号#port:端口`（无转发表时保持 `port:端口`），多台手机 / 同一手机多个 app 同时调试时可读可区分。
- 新增电脑端 GUI 工具箱（`bin/ide_gui.dart`，本机 Web GUI、零新增依赖）：`--install` 时随守护脚本一并部署，并在系统常用位置创建桌面入口（macOS 应用程序文件夹 `xb_ume 工具箱.app` 可从 Launchpad/Spotlight 启动，无写权限时装到 `~/Applications`；Windows 桌面快捷方式），另有启动器与 `dart run xb_ume:ide --gui` 命令入口；三个 Tab——设备管理（adb/hdc/Xcode 模拟器/idevice_id 发现与选择）、守护进程（状态查询经互斥端口 status 协议、一键重启、IDE 优先级展示）、日志（选中设备的全量设备日志 + 全部调试会话 stdout/stderr 实时展示，支持来源/级别/关键字过滤、暂停、清屏、导出）；`--uninstall` 一并移除桌面入口。
- 守护进程增加单实例接管锁：新实例启动时自动停止旧实例（命令行匹配 + 回环端口互斥双保险），只保留最新实例，避免多实例重复消费事件导致一次点击唤起多个 IDE；`--uninstall` 现在会停止所有 daemon 实例后再清理文件。
- 修复 Windows 下 Android Studio 已安装但检测不到的问题：`_hasAndroidStudio` 原先仅对 macOS 检查二进制路径，现按平台路径（含 `%LOCALAPPDATA%\Programs\Android Studio`）与命令名统一检测；同时修复文档示例中不存在的 `XBUme.app` API，新增 IDE 跳转使用指南 `IDE_JUMP_GUIDE.md`。

## 0.1.6

- 修复 GUI 临时连接泄漏：`/api/sandbox/read`（监听页 50ms~2s 轮询）、`/api/screenshot`（自动刷新）、`/api/wtree`、`/api/wtree/pick`、`/api/sandbox/delete`、`/api/sandbox/upload`、`/api/runtime/op` 七处未关闭 `_SandboxRpc`，长时间使用会累积 WebSocket 与文件描述符（对端 app 进程内同样被占用）；关闭流程统一加超时，避免握手挂住阻塞 HTTP 响应。
- 修复 GUI 轮询重入：设备轮询加互斥，设备日志进程启动期间占位去重，避免慢设备下重复启动 logcat/hilog 并遗留孤儿进程。
- 修复 VM 会话失效不恢复：建连失败或连接断开后按轮询周期自动重建（原实现会永久失效到 GUI 重启），握手增加 5s 超时。
- 修复实例字段写回字符串转义：值中的 `$`、换行、制表符改用 `_escEvalString`，并校验字段名，避免写回失败或写错值。
- 路由操作新增 `_debugLocked` 保护：App 正在转场时返回 `BUSY`，避免与自身导航竞争触发 Navigator 断言。
- GUI 退出新增 SIGHUP 处理（关闭终端窗口也会先断开 VM 会话，降低 DDS 死锁风险）。
- 守护进程：修复实例指纹去重集合从未写入导致跨轮去重失效；`--uri` 模式断线后自动重连（原实现永久挂起）；事件年龄过滤兼容手机与本机时钟偏差；停止旧实例时优先用状态 pid 精确停止，并以 `ps` 严格校验命令行，避免误伤其他调试进程。
- 修复 Widget 树输出缺段时的 `RangeError`。

## 0.1.8

- 路由栈名称列新增 XBVM：`/api/routeinfo` 除了 State / ChangeNotifier，还会静态解析页面的 XBVM 子类（`extends XBPage<HomeVM>` 泛型实参、`generateVM` 返回类型或构造调用、State 字段、`vmOf/vmWatch/Provider.of/Consumer` 等泛型实参，沿 extends 链验证 XBVM / XBPageVM 体系）；表格列改为「Widget / State / VM / Notifier」，VM 名可点击跳到「实例」Tab 扫描堆上实例。
- 隐藏「状态」Tab（ChangeNotifier 聚合面板），代码保留，恢复时去掉页头 tab 的 `display:none` 即可。

## 0.1.7

- 修复路由栈 Tab 可能诱发的 App 端 framework 断言（`InheritedElement.notifyClients` 的 `check that it really is our descendant`，多发生在 `UnmanagedRestorationScope` 重建时）：`/api/routelocate` 原先用 `ModalRoute.of(e)` 遍历整棵 Element 树来收集目标路由的候选 Widget，而 `ModalRoute.of` 会给每个 Element 注册 `_ModalScopeStatus` 依赖——相当于让全树的 `didChangeDependencies` 在每次路由状态变化（isCurrent/canPop）时都被触发，可能诱导业务代码在构建/转场期间执行导航或重建，进而触发 framework 断言。现改为只从目标路由自己的 `ModalRoute.subtreeContext` 向下遍历页面子树，不再注册任何 InheritedWidget 依赖，同时避免 250 候选上限把深页面的用户 Widget 截掉。
- 新增路由调试日志 `~/.xb_ume_ide/logs/route_debug.log`（超 2MB 轮转）：记录路由栈读取、路由定位、路由操作的端口/耗时/结果；当 App 端框架异常或未捕获异常到达时，自动追加最近 25 条路由操作快照，便于复现「切到路由栈 Tab 后操作手机出现异常」时直接对齐电脑端操作与手机端异常的时间线。
- 上述 `check that it really is our descendant` 断言到达后，额外在 App 内只读跑一次依赖一致性探针，把「仍登记在 InheritedElement._dependents 里、但祖先链已回不到该 InheritedElement」的元素以 `[deps]` 写入 `route_debug.log`（继承点/失效 dependent/生命周期/祖先链，最多 8 对），用于确认断言是哪一对依赖失效导致。

## 0.2.0

- GUI 新增「时间轴」Tab：把路由、网络、日志、异常四类调试事件按时间合并为一条流，用来对齐「一次操作前后 app 内先后发生了什么」。
  - 数据来源：路由 / 网络仅在时间轴 Tab 激活时由服务端每 1.5s 经 VM service eval 增量拉取（`XBUme.controller.routes` / `XBUme.controller.network`），经 WebSocket 只推送新增或状态变化的条目；日志 / 异常复用页面已实时接收的数据在前端本地合并，不重复传输。
  - 过滤与操作：时间范围（1/5/30 分钟/全部，默认 5 分钟）、事件类型（路由/网络/日志/异常分别开关）、日志级别（Flutter I / W·E / D·V）、空格分隔多关键字、暂停/恢复、一键回到最新、清空、复制当前视图。
  - 展示：按时间升序合并（同一毫秒权重 异常 > 网络 > 路由 > 日志），行内为时间、类型徽标、摘要与状态；点击行展开详情——路由含前后路由与 phase，网络含方法/URL/状态码/耗时与错误，异常含摘要/相关 Widget/栈帧，日志含来源/tag/完整消息，详情内可跳转到对应 Tab 查看完整内容。
  - 暂停时底部浮条提示有新事件，点击恢复并跳到底部；清空只清 GUI 视图里的路由/网络副本（不动 app 内记录），并以时间下限阻止旧记录回填；同一会话切走再切回保留已合并的历史。
  - 详情内的跳转链接会定位到目标 Tab 的具体位置：滚动到对应行/卡片并闪烁高亮；Network 自动展开该条请求，日志定位时自动放开挡住目标行的过滤；路由事件定位到当前栈中同名路由（已 pop 时给出提示）。
  - 修复时间轴实时刷新时点击偶发无效（需点两次才跳转）：按住鼠标期间推迟合帧重渲染，避免 mousedown 与 mouseup 之间的行被替换导致 click 丢失。
  - 日志与异常使用本机接收/捕获时间，路由与网络使用 app 端事件时间；手机与本机时钟偏差大时跨源排序可能有偏差（页面说明文案已注明）。

## 0.3.0

- Network 详情新增「发起位置」：app 端在请求开始时捕获调用栈，过滤 `dart:` / Flutter / Dio / http / xb_ume / xb_network 等基础设施帧后保留最多 24 个用户代码帧，首帧即发起位置；GUI 展示首帧与「跳转」（复用异常栈帧的 IDE 打开链路），完整调用栈默认折叠；「复制全部」包含发起位置。
- `XBUmeNetworkItem` 新增 `initiator` / `initiatorStack` 字段（`toJson` / `fromJson` / `copyWith` 兼容）；GUI 以 dynamic + try/catch 读取，app 端未升级（< 0.3.0）时降级为「未记录」，不影响其余字段。
- 手机端 ume 面板 Network 详情同步新增「发起位置」（完整过滤后调用栈，可选中复制）与「跳转发起位置」按钮，复用 `xb_ume:openSource` 事件通道打开电脑 IDE；若该请求来自旧版本（无发起位置字段）则显示「未记录」。
- 守护脚本新增 `package:` 源引用解析：跳转请求中的 `package:pkg/path.dart` 由 daemon 借会话自身的 VM service（`getIsolate` 的 `file:///` 库反推项目根，再读该项目 `package_config.json`）映射为本机文件路径。升级到 0.3.0 后需重新执行 `dart run xb_ume:ide --install` 更新守护脚本，否则手机端 Network 跳转只能复制 `package:` 原文到剪贴板。
- 异常 Tab 新增「AI 分析」（`POST /api/exc/analyze`）：把异常摘要/描述、相关 Widget、最多 12 帧调用栈、最多 5 个用户代码文件的源码片段、异常时路由栈与页面文本、前 30 秒网络请求、同一会话前后 15 秒 E/W 日志发给 OpenAI 兼容接口，输出「结论 / 定位 / 修复建议 / 需要补充」四段式归因；卡片内展示分析文本、依据统计与「复制分析」，结果在当前页面内存缓存（切 Tab / 新异常重渲染不丢）；AI 未配置、接口失败、异常记录不存在时在卡片内显示错误。异常记录新增 `wsUri`，分析时优先回连异常来源会话取上下文（异常来自非当前选中会话也有效）。
- 修复手机端 ume 面板 Console / Network / Inspector 详情弹窗在桌面端偶发 `The Scrollbar's ScrollController has no ScrollPosition attached` 断言：三个面板统一改用 `XBUmeDetailScrollContent`，Scrollbar 与 SingleChildScrollView 共用同一个 controller，并补充 macOS 回归测试。
- 截图 Tab 新增遥控与场景录制：工具栏勾选「遥控」（开始录制时自动勾选）后，单击截图=Tap、按住拖拽=Swipe、输入框回车=Input；坐标按截图物理像素映射，操作串行注入并自动刷新截图（失败保留上一帧）。每次成功操作自动追加场景步骤（`phys:true`），两次操作停顿超过 0.9s 自动插入最长 4s 的 wait；步骤可逐条删除/撤销/清空，可保存到 `~/.xb_ume_ide/scenarios`、载入继续编辑，并用「▶ 回放当前步骤」复用 `/api/auto/run` 逐步回放（失败即停、失败截图、状态与耗时），结束后可跳「自动化」Tab 看完整报告。新增 `POST /api/remote/op` 单步执行端点，只放行 tap/swipe/input（输入上限 5000 字），不占用场景执行状态；截图响应补 `Cache-Control: no-store`。
- example 新增「Login Demo」验收页（账号/密码/登录结果），用于录制并回放「不碰手机完成一次登录」。
