## 0.4.0

- 异常新增「出错 widget → 业务源码定位」：`XBUmeExceptionItem` 补 `widget` / `widgetFile` / `widgetLine` / `widgetColumn` 四个字段（`copyWith` / `toJson` / `fromJson` 同步），`XBUmeBinding` 在 `FlutterError.onError` 里从 `informationCollector` 的「The relevant error-causing widget was」段落取位置，新增 `lib/src/core/xb_ume_error_source.dart` 纯字符串解析器（兼容 `Row` 与 `Row:file:///...:21:20` 两行格式、优先取 hint 之后的帧而不误抓 framework 的 `flex.dart`、`%20` 还原、CRLF）；`xbume_exceptions` 返回补 `widget` 与 `source{file,line,column,snippet}`，snippet 由 daemon 读源码 ±2 行（超过 512KB 的文件跳过，真机调试源码不在本机时只给路径）；VM 表达式从 9 段扩到 13 段且改用 `e.toJson()` 取值避免旧 app 的 `NoSuchMethod`，旧 app 只回 9 段时 MCP 自动降级为不含位置。新增 `test/xb_ume_error_source_test.dart`（8 项）与 `test/xb_ume_exceptions_test.dart` 两项（钩子抓位置、同签名合并不丢位置）、`test/mcp_diagnose_tools_test.dart` 六条断言；macOS example 实测真实 `RenderFlex overflowed by 400 pixels` 返回 `Row @ .../lib/xxx.dart:21:20` 与 `flutter run` 日志一致；`flutter test` 266 → 276 项全过。
- Windows 支持补齐（macOS 行为不变）：`flutter run` / `npx` 等 `.bat` / `.cmd` 一律 `runInShell`（CreateProcess 不能直接执行批处理）；停止自建的 `flutter run` 时用 `tasklist` 判断存活、用 PowerShell 求整棵子进程树（cmd → dart → app）一并结束（原来 Windows 分支直接返回空表，app 会留在后台）；「AI 调试」页的设备下拉补 Windows 桌面项并在指令里按宿主系统推荐 `macos` / `windows`；性能页补 Windows 整进程统计（`GetProcessTimes` 的 kernel+user、`GetProcessMemoryInfo` 的 WorkingSetSize，任务管理器口径）；会话扫描补 Windows 通配绑定（`0.0.0.0` / `[::]`）的端口解析；设备类工具描述、`xbume_ai` 帮助与 `sqlite3` 缺失提示不再写死 macOS；README 平台矩阵同步。Windows 上仍存在的降级项（防顶掉体检、无崩溃自拉起）记在 MCP_GUIDE「已知缺口」。
- 新增「AI 调试模式」（零学习入口，一条命令 / 一个 Tab）：`dart run xb_ume:ai`（pubspec 新增 `executables: xb_ume_ai: ai`，支持 `--dir` / `--device` / `--print-only` / `--json`）与 GUI 新增「AI 调试」Tab（`#ai` 深链直达），一个动作把三件事做完——确保带 `--allow-eval` 的 MCP 在跑（已在跑就复用；在跑但没 eval 且 pid 是自己记录的那个就重启，外部服务不碰）、按项目目录 + 设备生成一段可直接粘给 AI 的指令（含 `xbume_app_launch` 的 `cwd`，让 AI 自己拉起 app，热重载才有 stdin 句柄）、把指令写进剪贴板；命令侧新增 `bin/src/mcp/host.dart`（`McpHost`：端口 46140-46149 探测握手 / 拉起 / 按 pid 停）、GUI 与命令共用 `bin/src/ai/prompt.dart`（项目目录校验、设备推荐：唯一手机 > macOS > 首个可用、指令与客户端配置文本）。GUI 侧 `startMcp({forceEval})` 复用已验证的启停链路，不改 `mcpAllowEval` 配置。
- 防「AI 二次拉起顶掉 IDE 会话」：`xbume_app_launch(via: "flutter-run")` 启动前扫本机 `flutter run`（`ps` + `lsof -d cwd`），**同设备 + 同目录**已有时默认拒绝并报出那个 pid 与两条出路（复用现有会话但无热重载 / `force: true` 重起）；路径按符号链接归一（`/tmp` → `/private/tmp`）；AI 指令第一步改为「先 `xbume_sessions`，有会话先问我」，不再写「先别管，用新起的」。新增 `test/flutter_run_guard_test.dart`（4 项：`-d` / `--device-id` 解析、无显式设备返回 null、符号链接与尾斜杠归一、不存在路径回落不抛异常）。
- AI 调试页的项目目录支持直接浏览本机目录：新增「选择…」按钮与目录选择器（`GET /api/fs/dirs` 由后台列子目录；浏览器自己的 `<input type=file webkitdirectory>` 只给相对名，拿不到能当 `cwd` 的绝对路径）。列表里 Flutter 项目（含 `pubspec.yaml`）排前并带标记、隐藏目录（`.git` / `.dart_tool` 等）跳过、符号链接归一（`/tmp` → `/private/tmp`）、单层最多 500 项；顶部路径框可直接粘绝对路径回车跳转，「上级 / 主目录」一键定位、根目录时「上级」自动禁用；底部提示当前目录是不是项目根，允许先进父目录再「选定此目录」；候选区把「会话反推的项目根 + 最近用过的目录」做成快捷按钮，Esc / 点遮罩关闭。
- AI 调试页的项目目录与设备改为「选」而不是「填」：「项目目录」变成带候选的下拉输入框（候选 = 当前已连接调试会话按 app 库路径反推的项目根 + `aiRecentDirs` 最近 8 个，仍可直接粘路径）；「设备」变成 `<select>`（自动 / 具体手机 / macOS 桌面，默认跟随右上角设备选择器）。`/api/ai/config` 同时返回 `sessionDirs` / `recentDirs` / `devices` / `selectedDevice`，`_VmSession` 解析 `getIsolate` 时顺手保存 `projectRoot` 供反推。
- AI 调试 Tab 的工具栏按「一键开启 → 状态（N 个工具 / eval 已开 / 指令已复制）→ 复制 AI 指令 / 复制 MCP 配置」排列：项目目录输入框自适应剩余宽度（长路径不再被截成两段），指令预览区高度随窗口（`calc(100vh - 400px)`，内部滚动）；剪贴板被浏览器策略拦下时给出「点『复制 AI 指令』手动全选」而不是静默失败。
- GUI 页签切换重构为 `showTab(tab)` 并支持 `#<tab>` 深链（文档、脚本、截图共用一个入口）：`http://127.0.0.1:<gui 端口>/#ai` 直接落在 AI 调试 Tab，行为与手动点击一致（各 Tab 的进入钩子照旧执行）。
- 新增 `test/ai_prompt_test.dart`（6 项：项目目录校验与报错文案、指令包含项目/设备/`cwd`/三阶段工具与热重载、`hasEval` 决定是否出现 `xbume_eval`、客户端配置含 `type: http` + token、GUI 结构守卫：`data-tab="ai"` / `page-ai` / `/api/ai/setup` / `/api/ai/config` / `startMcp(forceEval: true)` / `--allow-eval` 拼接 / 拒绝停外部服务）；`flutter test` 252 → 258 项全过。
- 新增两个 MCP 工具，把「改代码 → 重载 → 复跑」也交给 AI：`xbume_hot_reload`（向本服务用 `xbume_app_launch(via: "flutter-run")` 拉起的进程写 `r` / `R`，热重载或热重启，识别 flutter 的完成行后返回耗时与最近输出；热重启后自动清 isolate 缓存；会话不在自己手里时明确拒绝，不按名字杀进程）与 `xbume_eval`（新增 `--allow-eval` 开关，默认关；在 app 进程内求值单条表达式，`lib` 支持完整 uri 或子串匹配且业务库优先，返回 `值` + 库 + 类型，编译错误与运行时异常分开报，4000 字符上限 + `maxChars` 截断）。默认工具 23 → 24（core 17 → 18），`--tool-groups all` 28 → 29；GUI「MCP 服务」卡片新增「允许 eval」勾选（`config.json` 的 `mcpAllowEval` + `/api/mcp/eval`，只影响下次启动，重启后生效）。
- 修复热重载等待完成的正则漏配：`flutter run` 无改动时只打印「Reloaded 0 libraries in 83ms」（没有 `of N`），原正则按「Reloaded X of Y libraries」匹配会白等到超时；现在 `of N` 可选，实测空改动 146ms、改一个文件 229ms 即命中。
- 新增 MCP 服务 `dart run xb_ume:mcp`（`bin/mcp.dart` + `bin/src/mcp/*`，零新增依赖）：JSON-RPC 2.0 手写协议层，stdio（换行分隔，客户端拉起）与 Streamable HTTP（仅绑 127.0.0.1，默认 46140，token 校验 + Host 校验）双传输；默认 23 个工具（core 17 + diagnose 3 + run-safe 3），`act` / `device-write` 等有副作用的组必须显式 `--tool-groups` 开启；`--uri` 可手工指定会话，省略时自动扫描本机 VM service。
- MCP 核心工具：会话发现/选定、截图（image content）、按类型/Key/文本/Semantics 找组件（回 `ref` + 逻辑像素 bounds + 源码位置）、点击（ref / by+value / 坐标三选一）、焦点输入框写文本、滑动、路由 push/pop 与路由栈、网络记录、app 日志、场景运行/查询/停止/报告；场景运行异步返回 runId，同一时间只允许一个实例。
- 新增设备类 MCP 工具与可插拔后端（`bin/src/device/*`）：adb / hdc / simctl / idevice 自研实现 + `mobile-mcp` 可选适配器（需 Node/npx，**不**进入 auto，必须显式 `--device-backend` 才启用，首次调用可能 `npx -y @mobilenext/mobile-mcp@latest` 拉包）；能力显式声明（install/uninstall/launch/terminate/pressKey/tapNative/crashList/crashGet），后端不支持时返回 `unsupported: true` 与原因而不是假装成功；`xbume_app_launch(via: flutter-run)` 直接跑 `flutter run` 并把新会话设为当前（macOS 桌面无 adb 时走该分支）。
- 新增场景 DSL 复合与设备步骤（`bin/src/scenario/steps.dart`，part 方式共用 runner 的注入守卫）：`waitFor` / `retry` / `if` / `observe` / `scrollUntil`，以及 `install` / `uninstall` / `launchApp` / `pressKey` / `nativeTap` / `assertNoCrash`；条件统一支持 `visible` / `text` / `route` / `request` / `expr`，省略 `kind` 时按字段自动推断；`record` 与 `assertLog` 不做假实现，分别显式报错与标 skip。
- AI 驱动循环新增「元素候选」上下文：单次 eval 采集当前屏可点/有文字元素（ref、类型、文本、逻辑像素 bounds、业务源码 `文件:行`），剔除 Material Icons 等私有区字形、按文本优先去重、上限 50 条；新增 `tapRef` 步骤按 `ref` 反查 bounds 中心注入点击，并用 `expectType` 校验界面是否已变化（不匹配时提示改用坐标或重新决策）。
- 修复 `tapRef` 步骤被丢弃的问题：步骤 JSON 里候选类型与步骤类型同名 `type` 会互相覆盖（jsonDecode 后者胜），入参改名为 `expectType` 并在提示词中明确禁止重写 `type`。
- GUI「守护进程」Tab 新增「MCP 服务」卡片：只读探测本机 MCP（HTTP 模式扫 46140-46149 并握手 `initialize` + `tools/list` 拿工具数；stdio 模式按进程命令行识别），展示运行状态/端口/工具数/协议版本，并提供「复制 MCP 配置」按当前状态生成可直接粘贴的片段（HTTP 自动带 `X-XBUME-TOKEN`，凭据只在点复制时经 `/api/mcp?token=1` 下发）。
- 会话发现逻辑抽到 `bin/src/session/discovery.dart`，daemon 与 MCP 服务共用一份实现（含增强 PATH 与 adb/hdc 转发来源映射）。
- GUI「MCP 服务」卡片支持一键启停：点「启动」后台拉起部署副本（`~/.xb_ume_ide/mcp.dart --http <46140-46149 首个空闲端口> --tool-groups all --log-file logs/mcp.log`，detached，pid 记 `~/.xb_ume_ide/mcp.pid`，拉起前预生成 token 免首次握手 401，10 秒内握手成功才回「已启动」），点「停止」按记录 pid 发 SIGTERM 并轮询等端口释放；重复启动幂等、不是工具箱拉起的服务拒绝停；新增「随工具箱启动」勾选（`config.json` 的 `mcpAutoStart`，默认关；勾上时若服务未运行立即拉起，GUI 启动时也自动拉起）；新增 `/api/mcp/start|stop|auto` 三个端点，`/api/mcp` 回包补 `autoStart` / `launchable` / `managedPid`，前端状态行与按钮随 5 秒轮询刷新而「复制 MCP 配置」生成的文本不被覆盖。
- 修复 `--install` 部署副本跑不起来 MCP：部署改为递归复制整棵 `bin/src` + `bin/mcp.dart` + 写 `version.txt`，删掉容易漏的 `_kIdeRuntimeDeps` 单文件清单；`mcp.dart` 新增 `--log-file <path>`（stderr 照旧，同时按 ISO 时间戳追加到文件），`_readVersion` 在拿不到 `../pubspec.yaml` 时回退同目录 `version.txt`（部署副本 `--version` 报 0.4.0 而非 0.0.0）；`test/ide_deploy_deps_test.dart` 改为锁「`bin/` 下无 `package:` 依赖 + 部署函数递归复制 `src` 并带上 `mcp.dart`」。
- 修复 `--install` 部署不完整导致 daemon 起不来：`ide.dart` 改为依赖 `src/session/discovery.dart` 后，部署副本仍只复制单文件，dart 从部署目录解析不到 import 直接编译失败，GUI 只提示「重启后未检测到 daemon」；现在安装时按 `_kIdeRuntimeDeps` 清单连同依赖一起复制（保持相对路径），GUI 重启前先检查部署副本的相对依赖并点名缺失项，提示重新安装；新增 `test/ide_deploy_deps_test.dart` 锁住「相对 import ⇄ 清单」一致性。
- 修复时间轴「清空」看起来没生效：时间轴是路由/网络/监听/日志/异常五类事件的聚合视图，原实现只清路由/网络/监听，日志与异常仍原样留在页面上；现在点清空直接清掉视图内全部事件、不再弹二次确认（日志/异常只是被视图下限隐藏，各 Tab 原始数据不删），并处理三个边界：服务端清空失败或订阅重放时旧事件不再 merge 回来、会话掉线（uri 变空）不解除下限、只在两个非空会话之间切换时才让新会话历史正常显示；顺带修掉掉线时统计文字仍写「请先选择 VM」而行区有内容的不一致；新增 `test/gui_timeline_clear_test.dart` 锁住「不弹框 + 五类事件都受下限约束」。
- 新增 app 侧结构化异常缓冲：`XBUmeExceptionItem`（kind / type / message / signature / stack / library / context / count）+ `XBUme.controller.exceptions` + `addException` / `clearExceptions`，容量由 `XBUmeConfig.maxExceptionRecords` 控制（默认 200）；`XBUmeBinding` 在 `FlutterError.onError` 与 `PlatformDispatcher.onError` 里除原有日志外再存一份结构化记录（日志通道行为不变），10 秒内同签名（类型|摘要|首帧）原地累加 `count`，不再刷屏；`lib/xb_ume.dart` 导出模型。
- 新增三个诊断类 MCP 工具（均归 `core`，默认即可用）：`xbume_network_detail` 按 `id` 或 `urlContains`（可加 `method`）取完整请求头 / 响应头 / body 与发起位置、发起栈，`maxChars` 截断、`limit` 多条，凭据头沿用录制期脱敏（`Authorization: ***`）；`xbume_exceptions` 读 app 内异常缓冲，支持 `kind`（flutter / platform / app / all）、`typeContains`、`keyword`、`sinceMs`、`limit` 过滤，返回类型 / 库 / 上下文 / 栈 / 重复次数；`xbume_timeline` 把路由 + 网络 + 日志 + 异常按时间合并成一条流（`kinds` 过滤、每段取末尾 `limit` 条），异常段对旧版本 app 包 try/catch 兜底。默认工具 20 → 23（core 14 → 17），`--tool-groups all` 25 → 28；旧 app 调用 `xbume_exceptions` 时给升级提示，不把 VM 报错直接抛给模型。
- 新增 [MCP_GUIDE.md](MCP_GUIDE.md)：工具清单与参数、Qoder/Cursor/Claude Code 配置、七个典型 prompt、场景 DSL 全表、后端能力矩阵、安全模型、排障与已知缺口；README 新增「MCP 接入」章节与总览行，GUI_GUIDE 补守护进程页的 MCP 卡片说明。
- CHANGELOG 改为降序（最新在最上），与仓库其他包一致。
- 新增 `test/mcp_protocol_test.dart`、`test/device_parse_test.dart`、`test/scenario_steps_test.dart`、`test/mobile_mcp_test.dart`、`test/ide_deploy_deps_test.dart`、`test/gui_timeline_clear_test.dart`、`test/gui_mcp_control_test.dart`、`test/xb_ume_exceptions_test.dart`（7 项：入库字段、10 秒同签名合并、不同异常分列、容量淘汰、清空、JSON 往返、`FlutterError.onError` 钩子）、`test/mcp_diagnose_tools_test.dart`（8 项：注册与分组、schema 参数、三个表达式过滤 / 兜底 / 单行断言、旧版本提示、eval 源码守卫与选库、热重载只接受自建进程）；`flutter test` 258 项全过（含上面的 `ai_prompt_test.dart` 6 项）。

## 0.3.0

- Network 详情新增「发起位置」：app 端在请求开始时捕获调用栈，过滤 `dart:` / Flutter / Dio / http / xb_ume / xb_network 等基础设施帧后保留最多 24 个用户代码帧，首帧即发起位置；GUI 展示首帧与「跳转」（复用异常栈帧的 IDE 打开链路），完整调用栈默认折叠；「复制全部」包含发起位置。
- `XBUmeNetworkItem` 新增 `initiator` / `initiatorStack` 字段（`toJson` / `fromJson` / `copyWith` 兼容）；GUI 以 dynamic + try/catch 读取，app 端未升级（< 0.3.0）时降级为「未记录」，不影响其余字段。
- 手机端 ume 面板 Network 详情同步新增「发起位置」（完整过滤后调用栈，可选中复制）与「跳转发起位置」按钮，复用 `xb_ume:openSource` 事件通道打开电脑 IDE；若该请求来自旧版本（无发起位置字段）则显示「未记录」。
- 守护脚本新增 `package:` 源引用解析：跳转请求中的 `package:pkg/path.dart` 由 daemon 借会话自身的 VM service（`getIsolate` 的 `file:///` 库反推项目根，再读该项目 `package_config.json`）映射为本机文件路径。升级到 0.3.0 后需重新执行 `dart run xb_ume:ide --install` 更新守护脚本，否则手机端 Network 跳转只能复制 `package:` 原文到剪贴板。
- 异常 Tab 新增「AI 分析」（`POST /api/exc/analyze`）：把异常摘要/描述、相关 Widget、最多 12 帧调用栈、最多 5 个用户代码文件的源码片段、异常时路由栈与页面文本、前 30 秒网络请求、同一会话前后 15 秒 E/W 日志发给 OpenAI 兼容接口，输出「结论 / 定位 / 修复建议 / 需要补充」四段式归因；卡片内展示分析文本、依据统计与「复制分析」，结果在当前页面内存缓存（切 Tab / 新异常重渲染不丢）；AI 未配置、接口失败、异常记录不存在时在卡片内显示错误。异常记录新增 `wsUri`，分析时优先回连异常来源会话取上下文（异常来自非当前选中会话也有效）。
- 修复手机端 ume 面板 Console / Network / Inspector 详情弹窗在桌面端偶发 `The Scrollbar's ScrollController has no ScrollPosition attached` 断言：三个面板统一改用 `XBUmeDetailScrollContent`，Scrollbar 与 SingleChildScrollView 共用同一个 controller，并补充 macOS 回归测试。
- 截图 Tab 新增遥控与场景录制：工具栏勾选「遥控」（开始录制时自动勾选）后，单击截图=Tap、按住拖拽=Swipe、输入框回车=Input；坐标按截图物理像素映射，操作串行注入并自动刷新截图（失败保留上一帧）。每次成功操作自动追加场景步骤（`phys:true`），两次操作停顿超过 0.9s 自动插入最长 4s 的 wait；步骤可逐条删除/撤销/清空，可保存到 `~/.xb_ume_ide/scenarios`、载入继续编辑，并用「▶ 回放当前步骤」复用 `/api/auto/run` 逐步回放（失败即停、失败截图、状态与耗时），结束后可跳「自动化」Tab 看完整报告。新增 `POST /api/remote/op` 单步执行端点，只放行 tap/swipe/input（输入上限 5000 字），不占用场景执行状态；截图响应补 `Cache-Control: no-store`。
- example 新增「Login Demo」验收页（账号/密码/登录结果），用于录制并回放「不碰手机完成一次登录」。
- 实例 Tab 新增「Watch 监听」：字段树 value/ref 行可一键监听，或输入 eval 表达式设置监听，按 200ms~10s 间隔经 VM service 轮询取值，值变化写入时间轴（类型「监听」，可单独开关过滤）；支持条件表达式（与监听同上下文求值，需返回 bool）在 true 的上升沿自动截图，PNG 落盘 `~/.xb_ume_ide/scenarios/artifacts/watch-<时间戳>-<序号>.png` 并在时间轴详情直接打开；监听列表实时显示当前值、累计变化/截图次数与最近错误，可暂停/恢复/删除，连续失败 30 次自动暂停；同一目标去重，服务端常驻轮询（切 Tab 不中断）。时间轴监听事件详情支持「在实例 Tab 中定位该监听」。新增 `GET /api/watch/list|events` 与 `POST /api/watch/add|remove|pause|clear`。
- example 新增「Watch Demo」验收页（200ms 自增计数 + 阶段切换，经 `XBUme.registerStore('watch-demo', vm)` 暴露给实例 Tab）。
- 修复 VM service 错误只显示笼统 `Expression compilation error` 的问题：临时连接现在一并透传 JSON-RPC `error.data.details`，并对鸿蒙 Flutter 引擎（无 expression compilation service）给出「该调试会话不支持表达式求值（VM 未提供编译服务，常见于鸿蒙 Flutter 引擎）……路由栈/实例字段/Watch/沙盒等依赖 eval 的功能不可用」的明确提示，避免误判为表达式写错。
- 新增「数据库」Tab（SQLite 浏览器）：应用沙盒中对 `.db` / `.sqlite` / `.sqlite3` / `.db3` 文件新增「查询」入口，打开时经 VM service 分块（1MB + gzip）拉取到本机缓存 `~/.xb_ume_ide/db/<8位哈希>.db`（缓存键 = 会话 uri + 路径 + 大小 + 修改时间，命中复用），再用本机 `sqlite3 -readonly` 只读执行：表/视图列表、列结构与建表 SQL、`LIMIT 100` 分页浏览、任意单条只读 SQL（超 20000 字符或多语句拒绝）、CSV 导出（UTF-8 BOM + RFC 4180 转义，按原库名命名）。写操作全部被拒绝，库文件上限 256MB，单次查询 20s 超时/16MB 输出截断；新增 `POST /api/db/open|query|close` 与 `GET /api/db/schema|csv`，app 端零改动（macOS 自带 sqlite3，Windows/Linux 需安装并加入 PATH）。
- 新增「对比」Tab（多设备并排对比）：同一场景 JSON 在两个调试会话（如 macOS + iOS 模拟器）上并行执行，逐步并排展示两侧状态/期望 vs 实际/耗时/截图，行尾标注差异类型（状态 / 实际值 / 错误 / 耗时差值 ≥ 200ms），支持「只看差异」过滤；页面底部按「方法 + URL」聚合两侧运行窗口内的网络请求并标「仅 A 有 / 仅 B 有 / 一致」。同一会话会被拒绝，同一时间只允许一个场景或对比任务（409）；截图落 `~/.xb_ume_ide/scenarios/artifacts/cmp-<时间戳>-{a,b}-step<N>.png`；iOS 无 `_flutter.screenshot` 时自动退回 `ext.flutter.inspector.screenshot`（根渲染对象 toImage，原分辨率）；新增 `POST /api/compare/run|stop` 与 `GET /api/compare/status`，app 端零改动。
- 页头 Tab 栏改为横向滚动（`.tabs` 容器 + Tab 不换行），修复 Tab 增多后被 flex 压窄导致中文竖排换行的问题。
- Network 页工具栏（关键字过滤/刷新/清空/说明）与「共 N 条」统计行、表头改为吸顶（`position:sticky`），滚动长列表时不再跟页面滚走；吸顶偏移按工具栏实际高度在每次渲染后同步实测写入（不用 rAF，重建 DOM 到下一帧之间也不会失去偏移），过滤/展开详情重渲染后仍保持吸顶。三者的自然位置与吸附位置对齐（原 `.page` 顶部内边距、`#nw-body` 上边距、表格上边距改为自身 padding），从 scrollTop=0 起就固定，不会再先移动一小段再吸附。
- 新增场景命令行执行器 `xb_ume run`（`dart run xb_ume:run`，全局 activate 后为 `xb_ume run`）：`xb_ume run <场景文件|场景名> --uri <ws地址|端口>` 无需 GUI/浏览器，直连 VM service 顺序执行场景，支持 `--continue-on-fail` / `--shot-every-step` / `--wait-after` / `--shots-dir` / `--json` / `--list`；默认失败即停（剩余步骤标 skip）、失败步骤自动截图；步骤语义与 GUI 自动化一致（tap/swipe/input/wait/back/navigate/assertVisible/assertRoute/assertInstance/eval/assertText/assertRequest），`assertLog` 因依赖 GUI 日志订阅上下文在 CLI 下标 skip；`--report` 输出自包含 HTML 报告（结论徽章、场景/会话/起止时间/命令、逐步状态/耗时/实际与错误、截图 base64 内嵌），未指定时落到 `~/.xb_ume_ide/scenarios/reports/run-<场景>-<时间>.html`；退出码 0 全过 / 1 有失败 / 2 参数或场景加载错误；截图优先 `_flutter.screenshot`，iOS 退回 `ext.flutter.inspector.screenshot`；数据目录可用 `XB_UME_HOME` 覆盖；pubspec 新增 `executables: xb_ume: run`。
- 修复日志页两个问题：① 点击「设备日志」启用勾选框后工具栏按钮/输入框错位、右侧按钮被挤出可视区——关键字输入框改为宽度自适应（180px 起、最多 380px），「复制/到顶/到底/暂停/清屏/导出」包成整体按钮组 `flex:0 0 auto`，窄窗口时整组一起换行，不会再出现输入框变宽把按钮挤走；② 取消设备日志后即使勾选「Flutter 输出」也没有日志——全局 5000 条日志缓冲原按 FIFO 淘汰，单个高频会话（实测 f_jlink 调试会话）或设备日志洪流会把其他会话的 Flutter 输出整片挤出（修复前实测 5000 条里其他会话 0 条）。现改为按来源（source + tag + device）各保留最近 1000 条，总量超限时优先淘汰最旧的非 Flutter 行，服务端缓冲与页面缓冲同策略；修复后实测高频会话被限制在 1000 条，其他会话（20 条）与设备日志（hilog/ios 各近 3000/1000 条）均正常保留，切到安静会话也能看到 Flutter 输出。
- 修复日志页勾选/取消「设备日志」时整页卡顿（勾选后页面持续发涩）：原实现两个来源开关变化都会触发 `renderLogs()` 全量重建，实测 3600+ 行日志（约 980KB HTML）时每次重建约 39ms 且随行数线性变慢；页面还挂着全部命中行（最多 5000），每批新日志逐行读 `offsetHeight` 裁剪，12 秒内布局开销达 814ms。现在：① 来源开关只切 `#logview` 的 `nodev`/`noflutter` class（行带 `fline`/`devline` 标记），不重建 DOM，实测 20 次切换共 2ms；② 贴底改到 `requestAnimationFrame`，并用滚动事件维护的 `logFollow` 判断，点击时不再同步读写布局；③ DOM 批量裁剪：超过 4200 行才裁回 4000，一次只读一次高度差补偿，已关闭来源的隐藏行优先丢、当前显示的来源优先保留（实测 12 秒布局开销降到 10ms）；④ `logFlushNew` 从尾部找本批新行，不再每批全量扫 5000 条；⑤ `trimLogs` 改为超过 5500 条才裁回 5000（每 500 条一次）；⑥「复制」只复制当前可见行（被来源开关隐藏的不计入）。边界：若取消设备日志后对应 Flutter 行早已被渲染上限裁掉（缓冲里还有），切开关时检测到 DOM 缺该来源则重建一次补齐（实测 29ms），正常切换不走重建。
- 修复 Storage 页「保存写入」报 `Expected one expression, but found additional input`（鸿蒙 preferences 实测表达式达 4.8MB）：原实现把整份 XML 拼进单个 eval 字符串 `writeAsStringSync('…'); return 'ok';`，一是两条语句不构成合法表达式，二是超长内容 + 转义在 VM 侧解析失败。现在改为临时文件分块写入（64KB/块 `writeAsBytesSync`，逐块校验累计长度）后同目录 `rename` 原子替换，中途失败不会把原文件写成半截；body 改 JSON `{xml, dirty}`（纯 XML 旧格式仍兼容）。
- Storage 保存改为「写文件 + 经 app 内 SharedPreferences API 写回改动项」：前端记录用户改过的行（值/类型/删除），保存时经 VM service 在 app 内的 `SharedPreferences` 实例（legacy / WithCache / Async 任一）上先 `reload()`、再逐项 `setBool/setString/setInt/setDouble/setStringList/remove`，同时更新插件内存缓存与原生存储，**保存后立即生效、无需重启 app**；写回后读回一项校验并返回结果（按钮提示「✓ 已写入并生效（N 项）」/「需重启 app」/「部分需重启」+ 明细）。无 `flutter.` 前缀的 key、非法值、找不到实例（app 未读写过 preferences）时只写文件并明确提示需重启。实测 macOS 探针 app：`setBool('probe_flag', true)` 后 `getBool` 立即为 true、`remove` 后 key 数 3→2，`/api/storage/reload` 返回 `{ok:true,keys:3}`。
- Storage 工具栏新增「刷新 app 缓存」（`/api/storage/reload`）：调用 app 内 `reload()`/`reloadCache()` 让插件重读存储，用于直写文件后手动刷新；提示里说明「若值仍是旧的说明平台层自己缓存了文件（Android/鸿蒙/iOS 都可能），需重启 app」。
- 修复 iOS 会话 Storage 页报「无法获取 app 沙盒 HOME」：iOS 不注入 `HOME` 环境变量，改为为空时退回 `Directory.systemTemp` 的父目录（即沙盒根）。实测 iOS 模拟器会话可列出 `Library/Preferences`、写回沙盒 `/tmp` 下 200KB binary plist 并读回一致（分块 4 块 + rename）。
- 新增 `sharedPrefsSetExpr` 单测 3 项（类型映射、`$`/引号/换行转义、无前缀与非法值返回 null），`flutter test --concurrency=1` 80 项全过。
- Storage 保存反馈：点「保存写入（写回手机）」后按钮立即变为「写入中…」并禁用（分块写大文件期间可见进度、防重复点击），完成后**成功与失败都弹窗反馈**（原成功只改按钮文案 2.6 秒，容易被忽略）：成功提示「✓ 已写入并生效（N 项）」/「✓ 已写入并刷新缓存」，需重启或写回失败时给出具体原因与失败项；弹窗末尾统一附写入的文件名与字节数；未选会话/文件时点保存也会明确提示，不再静默返回。
- AI 自动化报告新增「AI 总结」：运行结束（完成/异常终止/手动停止）后，把指令原文、运行概况与逐轮记录（think、步骤结果、路由/页面文本/网络/日志证据）交给总结模型，按指令逐条拆解要求并核对是否满足——输出总体结论、指标表（值 + 计数依据，如成功率=成功 17/总 20）、需求覆盖表（满足/部分满足/未满足/无法判断 + 依据）、详细总结与问题建议，报告顶部与页面同步展示。指令中的数字要求（如「连续测 20 次」）做覆盖自检，缺失时自动补一次调用，仍缺失则标「覆盖可能不全」；执行期提示词新增规则：重复/统计类目标每轮 think 记录「第 k/N 次：成功/失败」。总结只发文本不带截图，最多调用 3 次（含解析失败重试与覆盖补全，退避 2s/4s，单次 45s、总时长 100s 双上限）；生成期间页面显示「正在生成 AI 总结…」并继续轮询，完成后才显示导出按钮；未配置、调用失败或回复非 JSON 时报告照常导出并显示未生成原因，原有结论/统计/明细不受影响。新增 `aiSummaryMissingRequirements` / `buildAiSummaryHtml` 纯函数与 8 项单测（mock 验证了重试、覆盖补全、降级三条路径）。
- 电脑端 GUI 安全加固：启动时生成随机访问令牌（写入 `~/.xb_ume_ide/gui.token`，POSIX 权限 0600），根页面下发 `HttpOnly + SameSite=Strict` Cookie；页面 `fetch` 自动带 `X-XBUME-Token`，WebSocket 带 `?token=`；校验 `Host` / `Origin`，拒绝 DNS rebinding 与跨站页面（`/ping` 豁免以保留单实例检测）。
- GUI 请求体统一 24MB 上限（Content-Length 提前 413，chunked 累计兜底）；`/api/network/clear|replay` 仅允许 POST；跨 host 重放按原值剥离 `Authorization` / `Cookie` 等凭据头；日志入缓冲与导出时把 VM service URL token 打码。
- evaluate 字符串统一转义 `\`、`$`、`'` 与换行（路径/类名/请求 id），修复 query 参数拼接注入；`/api/ideorder` GET 改为只读扫描，新增/去重由前端显式 POST 保存。
- 截图工具栏「下载 PNG」后新增「复制图片」：把当前显示的画面（不重新截图）经浏览器 Clipboard API 复制为 PNG 到系统剪贴板；浏览器不支持时提示改用「下载 PNG」。
- 新增「性能」Tab（当前调试会话 CPU/内存实时监控）：`getCpuSamples` 按采样窗口估算 Dart 主 isolate CPU 占用率（Idle 不计入，只反映 UI 线程）、`getMemoryUsage` 展示 Dart 堆/堆容量/堆外内存、`getProcessMemoryUsage` 展示进程总内存与顶层分桶构成；含 CPU/内存双曲线、会话内峰值、可调采集间隔（1/2/5 秒，采样窗口上限 2 秒）、暂停/继续/清空/触发 GC；仅在页面激活时采集，离开或暂停即停止，切换会话自动清空重采；新增 `GET /api/perf`，单个指标失败不影响其余指标；OHOS 等启动引擎时未开采样器的调试会话（`aa start` 不带 `--enable-dart-profiling`，`getCpuSamples` 报 `Profiler is disabled`）首次采集会自动 `setFlag('profiler', true)` 后重试，无需重启 app。app 端 xb_ume 另注册 `ext.xbume.processStats`（iOS/macOS 用 `getrusage` 取进程 user+sys CPU 时间，Android/OHOS 读 `/proc/self/stat`），CPU 卡片优先显示「整进程 · Xcode 口径」（全部线程、多核可超 100%，副标题保留 Dart isolate 值），进程内存副标题补充 `phys_footprint`（Xcode 内存口径）；旧版 SDK 未注册扩展时自动回退到 isolate 采样，无需配置。
- 性能页 Android / 鸿蒙指标对齐官方工具：CPU 百分比按官方口径换算——Android 按 Android Studio CPU Profiler、OHOS 按 DevEco Profiler 以「全部核心容量」为 100%（副标题标出核数，8 核下单线程满载约 12.5%），iOS/macOS 仍按 Xcode 单核 100%；进程内存改取 `/proc/self/smaps` 的 PSS（与 Android Studio Memory Profiler 的 Total、DevEco Memory 泳道同源），构成表按官方分类拆分：Android 照 `dumpsys meminfo` App Summary 的私有页公式算 Java / Native / Code / Stack / Graphics / Private Other / System（System 为 PSS 减私有页余量，各行之和恒等于 PSS 总量），OHOS 按 DevEco 内存类型拆 Native Heap / ArkTS Heap / Stack / GL·Graph / .so / .ttf / .hap / Dev / AnonPage Other / FilePage Other（均为 PSS）。iOS/macOS 的进程内存主数字改为 `phys_footprint`（Xcode 内存 gauge 口径），RSS 移到副标题。smaps 受限时退回 `smaps_rollup`（仅 PSS 总量）再退回 `getProcessMemoryUsage`；GPU memtrack 显存在 app 内不可读，Android 的 Graphics 仅为 smaps 可见部分、OHOS 总量不含 GL/Graph，可能略低于官方。PSS 整份 smaps 解析有主 isolate 开销，加 3 秒缓存；新增 smaps 解析与两套官方分类单测 7 项。构成表标题按口径标注（PSS / RSS），避免与卡片的 footprint 混读；CPU 相邻采样窗口超过 10 秒（页面隐藏后恢复）时丢弃当次百分比，避免显示长时间均值。
## 0.2.0

- GUI 新增「时间轴」Tab：把路由、网络、日志、异常四类调试事件按时间合并为一条流，用来对齐「一次操作前后 app 内先后发生了什么」。
  - 数据来源：路由 / 网络仅在时间轴 Tab 激活时由服务端每 1.5s 经 VM service eval 增量拉取（`XBUme.controller.routes` / `XBUme.controller.network`），经 WebSocket 只推送新增或状态变化的条目；日志 / 异常复用页面已实时接收的数据在前端本地合并，不重复传输。
  - 过滤与操作：时间范围（1/5/30 分钟/全部，默认 5 分钟）、事件类型（路由/网络/日志/异常分别开关）、日志级别（Flutter I / W·E / D·V）、空格分隔多关键字、暂停/恢复、一键回到最新、清空、复制当前视图。
  - 展示：按时间升序合并（同一毫秒权重 异常 > 网络 > 路由 > 日志），行内为时间、类型徽标、摘要与状态；点击行展开详情——路由含前后路由与 phase，网络含方法/URL/状态码/耗时与错误，异常含摘要/相关 Widget/栈帧，日志含来源/tag/完整消息，详情内可跳转到对应 Tab 查看完整内容。
  - 暂停时底部浮条提示有新事件，点击恢复并跳到底部；清空只清 GUI 视图里的路由/网络副本（不动 app 内记录），并以时间下限阻止旧记录回填；同一会话切走再切回保留已合并的历史。
  - 详情内的跳转链接会定位到目标 Tab 的具体位置：滚动到对应行/卡片并闪烁高亮；Network 自动展开该条请求，日志定位时自动放开挡住目标行的过滤；路由事件定位到当前栈中同名路由（已 pop 时给出提示）。
  - 修复时间轴实时刷新时点击偶发无效（需点两次才跳转）：按住鼠标期间推迟合帧重渲染，避免 mousedown 与 mouseup 之间的行被替换导致 click 丢失。
  - 日志与异常使用本机接收/捕获时间，路由与网络使用 app 端事件时间；手机与本机时钟偏差大时跨源排序可能有偏差（页面说明文案已注明）。

## 0.1.8

- 路由栈名称列新增 XBVM：`/api/routeinfo` 除了 State / ChangeNotifier，还会静态解析页面的 XBVM 子类（`extends XBPage<HomeVM>` 泛型实参、`generateVM` 返回类型或构造调用、State 字段、`vmOf/vmWatch/Provider.of/Consumer` 等泛型实参，沿 extends 链验证 XBVM / XBPageVM 体系）；表格列改为「Widget / State / VM / Notifier」，VM 名可点击跳到「实例」Tab 扫描堆上实例。
- 隐藏「状态」Tab（ChangeNotifier 聚合面板），代码保留，恢复时去掉页头 tab 的 `display:none` 即可。

## 0.1.7

- 修复路由栈 Tab 可能诱发的 App 端 framework 断言（`InheritedElement.notifyClients` 的 `check that it really is our descendant`，多发生在 `UnmanagedRestorationScope` 重建时）：`/api/routelocate` 原先用 `ModalRoute.of(e)` 遍历整棵 Element 树来收集目标路由的候选 Widget，而 `ModalRoute.of` 会给每个 Element 注册 `_ModalScopeStatus` 依赖——相当于让全树的 `didChangeDependencies` 在每次路由状态变化（isCurrent/canPop）时都被触发，可能诱导业务代码在构建/转场期间执行导航或重建，进而触发 framework 断言。现改为只从目标路由自己的 `ModalRoute.subtreeContext` 向下遍历页面子树，不再注册任何 InheritedWidget 依赖，同时避免 250 候选上限把深页面的用户 Widget 截掉。
- 新增路由调试日志 `~/.xb_ume_ide/logs/route_debug.log`（超 2MB 轮转）：记录路由栈读取、路由定位、路由操作的端口/耗时/结果；当 App 端框架异常或未捕获异常到达时，自动追加最近 25 条路由操作快照，便于复现「切到路由栈 Tab 后操作手机出现异常」时直接对齐电脑端操作与手机端异常的时间线。
- 上述 `check that it really is our descendant` 断言到达后，额外在 App 内只读跑一次依赖一致性探针，把「仍登记在 InheritedElement._dependents 里、但祖先链已回不到该 InheritedElement」的元素以 `[deps]` 写入 `route_debug.log`（继承点/失效 dependent/生命周期/祖先链，最多 8 对），用于确认断言是哪一对依赖失效导致。

## 0.1.6

- 修复 GUI 临时连接泄漏：`/api/sandbox/read`（监听页 50ms~2s 轮询）、`/api/screenshot`（自动刷新）、`/api/wtree`、`/api/wtree/pick`、`/api/sandbox/delete`、`/api/sandbox/upload`、`/api/runtime/op` 七处未关闭 `_SandboxRpc`，长时间使用会累积 WebSocket 与文件描述符（对端 app 进程内同样被占用）；关闭流程统一加超时，避免握手挂住阻塞 HTTP 响应。
- 修复 GUI 轮询重入：设备轮询加互斥，设备日志进程启动期间占位去重，避免慢设备下重复启动 logcat/hilog 并遗留孤儿进程。
- 修复 VM 会话失效不恢复：建连失败或连接断开后按轮询周期自动重建（原实现会永久失效到 GUI 重启），握手增加 5s 超时。
- 修复实例字段写回字符串转义：值中的 `$`、换行、制表符改用 `_escEvalString`，并校验字段名，避免写回失败或写错值。
- 路由操作新增 `_debugLocked` 保护：App 正在转场时返回 `BUSY`，避免与自身导航竞争触发 Navigator 断言。
- GUI 退出新增 SIGHUP 处理（关闭终端窗口也会先断开 VM 会话，降低 DDS 死锁风险）。
- 守护进程：修复实例指纹去重集合从未写入导致跨轮去重失效；`--uri` 模式断线后自动重连（原实现永久挂起）；事件年龄过滤兼容手机与本机时钟偏差；停止旧实例时优先用状态 pid 精确停止，并以 `ps` 严格校验命令行，避免误伤其他调试进程。
- 修复 Widget 树输出缺段时的 `RangeError`。

## 0.1.5

- 调试会话来源标签增强：自动发现时经 `adb forward --list` / `hdc fport ls` 把本机转发端口映射到设备号，会话标签由 `port:端口` 升级为 `adb:设备号#port:端口`（无转发表时保持 `port:端口`），多台手机 / 同一手机多个 app 同时调试时可读可区分。
- 新增电脑端 GUI 工具箱（`bin/ide_gui.dart`，本机 Web GUI、零新增依赖）：`--install` 时随守护脚本一并部署，并在系统常用位置创建桌面入口（macOS 应用程序文件夹 `xb_ume 工具箱.app` 可从 Launchpad/Spotlight 启动，无写权限时装到 `~/Applications`；Windows 桌面快捷方式），另有启动器与 `dart run xb_ume:ide --gui` 命令入口；三个 Tab——设备管理（adb/hdc/Xcode 模拟器/idevice_id 发现与选择）、守护进程（状态查询经互斥端口 status 协议、一键重启、IDE 优先级展示）、日志（选中设备的全量设备日志 + 全部调试会话 stdout/stderr 实时展示，支持来源/级别/关键字过滤、暂停、清屏、导出）；`--uninstall` 一并移除桌面入口。
- 守护进程增加单实例接管锁：新实例启动时自动停止旧实例（命令行匹配 + 回环端口互斥双保险），只保留最新实例，避免多实例重复消费事件导致一次点击唤起多个 IDE；`--uninstall` 现在会停止所有 daemon 实例后再清理文件。
- 修复 Windows 下 Android Studio 已安装但检测不到的问题：`_hasAndroidStudio` 原先仅对 macOS 检查二进制路径，现按平台路径（含 `%LOCALAPPDATA%\Programs\Android Studio`）与命令名统一检测；同时修复文档示例中不存在的 `XBUme.app` API，新增 IDE 跳转使用指南 `IDE_JUMP_GUIDE.md`。

## 0.1.4

- locator 选中组件新增宽高标注：气泡内新增 size 行展示组件真实宽高（逻辑像素），高亮框边缘新增 W/H 青色标签，组件超出屏幕时仍显示真实值；不影响现有边框、间距标注与拖拽功能。

## 0.1.3

-  优化 locator 层级展示

## 0.1.2

-  优化 locator 定位精度

## 0.1.1

- optimized.

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

