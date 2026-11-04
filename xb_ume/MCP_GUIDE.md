# xb_ume MCP 接入指南

让 AI 助手（Qoder / Cursor / Claude Code 等）通过 [MCP](https://modelcontextprotocol.io)
直接驱动你正在调试的 Flutter app：看当前页面、点按钮、填表单、跑场景、起停设备上的包。

xb_ume 的 MCP 服务有两种视角，这是它和其他移动端 MCP 的根本区别：

| 视角 | 谁提供 | 能做什么 | 限制 |
| --- | --- | --- | --- |
| **进程内白盒**（xb_ume 本体） | VM service + app 内 xb_ume | 按 Widget 树找组件（ref + 源码位置）、注入真实手势、读路由栈/网络/日志、跑场景 | app 必须是 debug 模式且已连上 VM service |
| **进程外黑盒**（设备后端） | adb / hdc / simctl / idevice / flutter run | 装包、起停 app、按键、原生坐标点击、抓崩溃日志 | 不知道 Widget 结构，坐标要自己算 |

模型通常先用白盒找 `ref` 再点，需要装包/起进程时切黑盒后端。

---

## 最快上手：AI 调试模式（一条命令 / 一个 Tab）

不想先学 MCP、eval、鉴权这些前置？用这个入口，它把三件事一次做完：
**拉起带 `xbume_eval` 的 MCP** → **生成一段可直接粘给 AI 的指令** → **把指令写进剪贴板**。

```bash
# 在 Flutter 项目根目录（含 pubspec.yaml）
dart run xb_ume:ai

# 指定项目 / 设备 / 只生成不动服务
dart run xb_ume:ai --dir ~/work/my_app --device macos
dart run xb_ume:ai --print-only     # 服务现状不动，只输出指令
```

GUI 里同一个东西叫「AI 调试」Tab：项目目录从下拉里选（候选 = 当前调试会话反推的项目根、
最近用过的目录，也可直接粘路径）→ 设备同样下拉选（默认跟随右上角设备）→ 点
「一键开启」，状态栏出现 `已就绪 · N 个工具 · eval 已开 · 指令已复制` 就可以往下走了；
旁边的「复制 AI 指令」「复制 MCP 配置」随时再取。深链
`http://127.0.0.1:46129/#ai` 直达该页（端口以实际打开的为准）。

注意右上角的「VM 会话」与这里无关：那是**已经在跑**的 app 会话（供日志/时间轴用），
而 AI 调试要自己 `flutter run` 拉起 app（热重载才有 stdin 句柄）；但项目目录候选会
从这些会话的库路径反推，不用手找。

拿到指令后**把它粘给 AI 即可**，中间这几步它自己会做，所以不需要你学：

| 原来要你做的事 | 现在谁做 |
| --- | --- |
| 启动 app，并把会话接到 MCP 上 | AI 调 `xbume_app_launch(via: "flutter-run", cwd: "<指令里的项目路径>")`；flutter run 的 stdin 在 MCP 进程手里，`xbume_hot_reload` 才有句柄 |
| 想用 `xbume_eval` 得手动加 `--allow-eval` | 入口自动带；已在跑但没 eval 时只重启**自己记录的那个**（pid 在 `~/.xb_ume_ide/mcp.pid`），外部服务不碰 |
| 记住端口 / token / 客户端 JSON | 入口直接打印（GUI 里点「复制 MCP 配置」），token 自动读 `~/.xb_ume_ide/mcp.token` |

唯一省不掉的一步：把 MCP 地址填进 AI 客户端（每个客户端只做一次，见
[第 2 节](#2-客户端配置)）。指令里已写明「别让我手动启动 app」，AI 会自己拉起。

---

## 1. 启动

零新增依赖：MCP 协议层与传输层都是手写的 `dart:io`，不需要 Node。

### stdio（推荐）

由客户端把服务作为子进程拉起，配置最省事：

```bash
# 全局 activate 过（pubspec 已声明 executables: xb_ume_mcp: mcp）
dart pub global activate --source path /path/to/xb_ume
xb_ume_mcp

# 或在某个依赖了 xb_ume 的项目里
dart run xb_ume:mcp

# 或直接指向源码（任何目录都能跑）
dart run /path/to/xb_ume/bin/mcp.dart
```

stdio 模式下 stdout 只走协议，所有日志写 stderr。

### Streamable HTTP

多客户端复用、或客户端只支持远程 MCP 时用：

```bash
dart run xb_ume:mcp --http 46140
```

- 只绑定 `127.0.0.1`，默认端口 `46140`；
- 首次运行生成 token 到 `~/.xb_ume_ide/mcp.token`（`XB_UME_HOME` 可改数据目录）；
- 每个请求必须带 `X-XBUME-Token` 或 `Authorization: Bearer`，否则 401；
- `POST /mcp` 返回单条 JSON 响应（不提供 SSE 长连接，`GET` 明确 405）。

启动后 stderr 会打印可直接粘贴的配置片段，拼好的客户端配置见
[第 2 节](#2-客户端配置)。

### GUI 一键启动

装过工具箱（`dart run xb_ume:ide --install`）就不用再敲命令：打开 GUI →
「守护进程」Tab →「MCP 服务」卡片点「启动」，它在后台拉起部署副本
`~/.xb_ume_ide/mcp.dart --http <46140-46149 首个空闲端口> --tool-groups all`，
输出同时写入 `~/.xb_ume_ide/logs/mcp.log`；点「停止」结束该进程。

- 勾选「随工具箱启动」后，每次打开工具箱都会自动拉起（状态存在
  `~/.xb_ume_ide/config.json` 的 `mcpAutoStart`，默认关）；取消勾选不会停掉
  正在运行的服务，要停点「停止」。
- 卡片上的「允许 eval」对应 `--allow-eval`（`config.json` 的 `mcpAllowEval`）：
  勾选后拉起的服务多出 `xbume_eval`，能在 app 进程内求值任意表达式（可读也能改
  运行时状态），默认不勾。它只影响**下次启动**：服务正在跑时要「停止」再「启动」
  才生效。**用「AI 调试」Tab 的一键开启则不用管这个开关**，它会按需自动带上。
- 一次开全 **55 个**工具（core 19 + diagnose 4 + run-safe 3 + act 3 + device-write 3 +
  debug 6 + inspect 4 + data 4 + env 8 + ai 1）；其中 `xbume_eval` 还要 `--allow-eval`
  （不加是 54 个），「AI 调试」入口会自动带上：
  装包/卸包/停进程这类高危操作仍要求参数里的 `confirm`，但**服务本身对本机任何进程都可见**，不需要时就把服务停掉。
- GUI 只停自己拉起的进程（pid 记在 `~/.xb_ume_ide/mcp.pid`）；客户端以
  stdio 拉起的进程要去客户端里关。
- 重复点「启动」是幂等的：端口即单实例锁，不会起第二个实例；端口全占时
  （46140-46149）直接报错，不会杀别人的进程。

### 常用参数

| 参数 | 说明 |
| --- | --- |
| `--stdio` | stdio 传输（默认） |
| `--http <port>` | Streamable HTTP，默认 46140 |
| `--uri <port\|ws-url>` | 手工指定调试会话，跳过自动发现；可重复 |
| `--tool-groups <list>` | `all` 或逗号分隔；可用组：`act`、`device-write`、`debug`、`inspect`、`data`、`env`、`ai`（`core` / `diagnose` / `run-safe` 默认开） |
| `--no-tool-groups` | 只暴露 core 组 |
| `--device-backend <list>` | `auto`（默认）/ `adb,hdc,simctl,idevice` / `mobile-mcp` |
| `--log-file <path>` | 日志同时追加到文件（GUI 启动时为 `~/.xb_ume_ide/logs/mcp.log`） |
| `--allow-eval` | 额外开放 `xbume_eval`：在 app 进程内求值单行表达式（可读可改运行时状态），默认关；GUI 卡片上的「允许 eval」即此开关 |

不带 `--uri` 时，服务会自己扫描本机回环端口上的 VM service（含
`adb forward` / `hdc fport` 转发来源），逻辑与电脑端守护进程共用一份实现。

---

## 2. 客户端配置

### 通用 JSON 片段

放在客户端的 MCP Servers 配置里（Qoder 在「设置 → MCP 服务 → 添加」里粘贴，
Cursor 用 `~/.cursor/mcp.json`，其他客户端用各自的 servers 字段）：

stdio：

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

HTTP：

```json
{
  "mcpServers": {
    "xb_ume": {
      "type": "http",
      "url": "http://127.0.0.1:46140/mcp",
      "headers": {
        "X-XBUME-Token": "<~/.xb_ume_ide/mcp.token 的内容>"
      }
    }
  }
}
```

> GUI「守护进程」页的「复制 MCP 配置」、以及「AI 调试」页的「复制 MCP 配置」
> 都会按当前运行状态生成上面两种片段之一（HTTP 模式自动带上 token），直接粘贴即可。

### Claude Code

```bash
# stdio
claude mcp add xb_ume -- dart run /path/to/xb_ume/bin/mcp.dart

# HTTP
claude mcp add --transport http xb_ume http://127.0.0.1:46140/mcp \
  --header "X-XBUME-Token: $(cat ~/.xb_ume_ide/mcp.token)"
```

### 只想给某类操作临时放权

```bash
# 默认：core + diagnose + run-safe（25 个工具，全是只读或 app 内注入）
dart run xb_ume:mcp

# 断点 / 单步 / 调用栈 / 变量 / 运行输出（直连 VM，不依赖 GUI）
dart run xb_ume:mcp --tool-groups debug

# 数据面：shared_prefs / SQLite / 沙盒文件 / 表达式监听
dart run xb_ume:mcp --tool-groups data

# 观测与环境：Widget 树 / 实例 / 性能泄漏 / 路由定位 / IDE / 守护进程 / 时间轴
dart run xb_ume:mcp --tool-groups inspect,env

# 加上按键 / 原生点击
dart run xb_ume:mcp --tool-groups act

# 加上装包 / 卸包 / 停进程（高危，见「安全模型」）
dart run xb_ume:mcp --tool-groups act,device-write

# 全开（55 个，含 xbume_eval）
dart run xb_ume:mcp --tool-groups all --allow-eval

# 再加可选后端（会拉起 npx，首次需联网下载）
dart run xb_ume:mcp --device-backend adb,hdc,simctl,idevice,mobile-mcp
```

---

## 3. 工具清单

工具名统一前缀 `xbume_`。默认暴露 **25 个**（core 18 + diagnose 4 + run-safe 3）；
加 `--allow-eval` 再多出 `xbume_eval`（26 个）。`--tool-groups all` 全开是 **55 个**
（debug 6 + inspect 4 + data 4 + env 8 + act 3 + device-write 3 + ai 1；不加 `--allow-eval` 时 54）。

debug 组直连 VM service（不依赖 GUI）；**data / inspect / env / ai 四组通过本机 GUI 的 HTTP
接口执行**——需要工具箱在跑（端口自动发现，令牌读 `~/.xb_ume_ide/gui.token`），所以这几组
连的是「GUI 当前选中的会话」，传 `sessionId` / `uri` 可覆盖。

### core（18 个）

| 工具 | 主要参数 | 返回 |
| --- | --- | --- |
| `xbume_sessions` | `refresh?` | 会话列表：id / 端口 / app 名 / 平台 / 来源（adb:hdc:port）/ 当前选中；有 `launcher` 标记的会话由本服务或 GUI 拉起（`mcp拉起·可热重载` / `gui认领·可热重载` / `…只读`），可直接复用 |
| `xbume_use_session` | `sessionId` | 选定后续工具默认会话，并读一次路由栈做连通性验证 |
| `xbume_screenshot` | `savePath?` | PNG（image content，模型可直接看）+ 像素尺寸；iOS 走 inspector 渲染兜底 |
| `xbume_find_widget` | `by`(type/key/text/semantics), `value`, `exact?`, `limit?` | `ref` / 类型 / Key / 文本 / 逻辑像素 bounds / 源码位置 |
| `xbume_tap` | `ref?` 或 `by`+`value` 或 `x`+`y`；`phys?`, `waitMs?` | 是否命中 + 操作后路由名 |
| `xbume_input` | `text` | 整体替换当前焦点输入框内容（需先 tap 输入框建立连接） |
| `xbume_swipe` | `from`+`to` 或 `direction`(+`distance`,`ref`), `durationMs?` | 注入带时间戳的 8 段移动事件 |
| `xbume_navigate` | `routeName?`, `back?` | pushNamed / pop，返回最新路由栈 |
| `xbume_route_stack` | — | 从底到顶：路由名 / Route 类型 / 参数类型 / isPresent |
| `xbume_network` | `urlContains?`, `method?`, `minStatus?`, `withinLastMs?`, `limit?` | app 内 xb_ume 拦截记录（需 app 接入 Network 模块） |
| `xbume_network_detail` | `id?` 或 `urlContains`(+`method?`), `maxChars?`, `limit?` | 完整请求/响应头、body、发起点调用栈（敏感头已 `***` 脱敏）；答「这个 500 返回了什么」 |
| `xbume_console` | `level?`, `keyword?`, `sinceMs?`, `limit?`, `offset?`, `tail?`, `maxChars?` | app 内 xb_ume 日志；默认取**最新** `limit` 条（`tail: true`），`tail: false` 时从 `offset` 往后取；返回 `nextSinceMs` 当游标，下一轮传 `sinceMs` 只拿新增 |
| `xbume_exceptions` | `kind?`(flutter/platform/app/all), `typeContains?`, `keyword?`, `sinceMs?`, `limit?` | 结构化异常：类型 / 摘要 / 库 / 上下文 / 栈 / 重复次数（比日志多出结构与合并计数）；渲染 / build 类错误额外给 `widget` 与 `source{file,line,column,snippet}`——直接指出出错的组件与业务源码位置，`snippet` 是 daemon 读的源码 ±2 行（真机调试时源码不在本机则只给路径） |
| `xbume_timeline` | `kinds?`(route/net/log/exception), `keyword?`, `sinceMs?`, `limit?` | 路由 + 网络 + 日志 + 异常按时间合并成一条流，定位「点一下之后发生了什么」 |
| `xbume_scenario_run` | `name?` 或 `steps?`, `continueOnFail?`, `shotEveryStep?` | 异步运行，立刻返回 `runId` |
| `xbume_scenario_status` | `runId?` | 逐步骤 pass/fail/skip + 错误 + 耗时 + 报告路径 |
| `xbume_app_launch` | `deviceId`, `via?`(flutter-run 默认), `packageId?`, `target?`, `config?`, `args?`, `listConfigs?`, `waitVm?`, `cwd?`, `force?`, `platform?` | `via=flutter-run` 顺带把新会话设为当前；**同设备 + 同目录 + 同 target + 同 config 已有本服务/GUI 拉起的会话时直接复用**（回 `reused: true`，不重装包）；`force: true` = 先停掉本服务那一个再重起；外部 IDE 起的同设 备同目录会话仍默认拒绝（继续会顶掉它），确认顶掉才传 `force: true`。`config` 指项目里的具名运行配置（`configs[].name`，GUI「调试」页下拉里看到的那些），决定入口 / 参数 / env / 预启动；名字写错当场报错并列出可用名。`args` 是**只对本次**生效的追加参数（不写进配置）；两者都会记成该项目的 `last`，下次不传也按它回填。`listConfigs: true` 只列出当前项目（`cwd`）的配置与上次选择，不启动。配置了「项目运行配置」的项目会先跑预启动命令（`structured.preRun` 回命令列表，`platform` 不传时按设备自动识别） |
| `xbume_hot_reload` | `sessionId?` 或 `pid?`, `mode?`(reload/restart), `timeoutMs?` | 向本服务拉起的 `flutter run` 写 `r`/`R`：改完代码就地热重载/热重启，返回耗时与完成行；热重启会清 isolate 缓存 |
| `xbume_eval` | `expr`, `lib?`, `maxChars?` | **需 `--allow-eval`**：在 app 进程内求值单行表达式，返回 `值` + 库 + 类型；编译错误与运行时异常分开报 |

### run-safe（3 个，默认开启）

| 工具 | 主要参数 | 说明 |
| --- | --- | --- |
| `xbume_scenario_list` | — | 列 `~/.xb_ume_ide/scenarios` 下 GUI 保存的场景与步数 |
| `xbume_scenario_stop` | `runId?` | 请求停止；已执行步骤保留，剩余标 skip |
| `xbume_report` | `runId?` | 自包含 HTML 报告的路径与大小 |

### diagnose（4 个，默认开启）

| 工具 | 主要参数 | 说明 |
| --- | --- | --- |
| `xbume_devices` | `refresh?` | 各后端可用性 + 能力矩阵 + 设备清单（不可用后端带 reason） |
| `xbume_device_logs` | `deviceId`, `keyword?`, `tag?`, `level?`, `lines?`, `dumpLines?`, `sinceMinutes?`, `durationMs?` | 设备系统日志**一次性 dump**：Android `adb logcat -d`、鸿蒙 `hdc hilog`、iOS 模拟器 `simctl log show`、iOS 真机 `idevicesyslog`（限时流式）。先抓 `dumpLines` 行原始日志再本地过滤，返回最后 `lines` 条；`level` 过滤会保留认不出级别的续行，异常栈不会断头。不驻留进程、不留孤儿 |
| `xbume_crash_list` | `deviceId`, `packageId?`, `limit?` | Android logcat crash 缓冲区 / iOS DiagnosticReports / idevicecrashreport |
| `xbume_crash_get` | `deviceId`, `crashId` | 取原始日志（超 64KB 截断） |

### act（3 个，需 `--tool-groups act`）

| 工具 | 主要参数 |
| --- | --- |
| `xbume_press_key` | `deviceId`, `key`（back/home/enter/delete/tab/escape/menu/appSwitch/volumeUp/volumeDown/power） |
| `xbume_native_tap` | `deviceId`, `x`, `y`（屏幕物理像素） |
| `xbume_keep_awake` | `deviceId`, `on?`（默认 true）—— 调试期间保持屏幕常亮。鸿蒙走 `power-shell timeout -o 2147483647`（≈24.8 天，手机或 powermgr 重启后失效）；Android 走 `svc power stayon true`（仅充电时生效，拔线自动恢复）；iOS 无等价命令，返回 unsupported |

### device-write（3 个，需 `--tool-groups device-write`，高危）

| 工具 | 主要参数 | 保护 |
| --- | --- | --- |
| `xbume_app_install` | `deviceId`, `artifact`（.apk/.ipa/.app/.hap） | 校验后缀与文件存在 |
| `xbume_app_uninstall` | `deviceId`, `packageId`, `confirm` | 必须显式 `confirm: true` |
| `xbume_app_terminate` | `deviceId?`, `packageId?` 或 `pid`, `confirm` | 必须显式 `confirm: true`；支持停 `flutter run` 进程 |

### debug（6 个，需 `--tool-groups debug`）

直连 VM service，不经过 GUI；和 GUI 的「调试」Tab 看的是同一套 `DebugHub`。

| 工具 | 主要参数 | 说明 |
| --- | --- | --- |
| `xbume_debug_attach` | `sessionId?`, `projectRoot?` | 接入会话：建调试连接、认领项目根、按落盘清单恢复「已记住」的断点。后续 debug 工具复用这条连接 |
| `xbume_debug_state` | `sessionId?`, `withOutput?`, `outputLines?` | 连接状态 / 是否暂停 / 暂停原因 / 当前帧位置 / 断点表 / 最近运行输出 |
| `xbume_debug_breakpoints` | `action`(list/add/remove/update/toggle/toggleAll/remember/enableSaved/forget/saved/forgetSaved/savedAll), `path?`, `line?`, `column?`, `condition?`, `logMessage?`, `id?`, `enabled?`, `dir?` | 会话断点与落盘清单两套：add/remove/update/toggle 可按 `path+line`（不必先查 id）；remember/saved 跨重启保存；`logMessage` 是日志断点（不暂停） |
| `xbume_debug_control` | `action`(pause/continue/resume/stepOver/stepInto/stepOut/detach/hot/stop) | pause 会等到真的暂停再返回；单步要求当前暂停；hot 只作用于本服务/GUI 拉起的 `flutter run`（外部 IDE 会话会明确拒绝，不会误发按键） |
| `xbume_debug_inspect` | `action`(stack/vars/eval), `frameIndex?`, `withVars?`, `objectId?`, `keyword?`, `expression?` | 调用栈、逐层展开变量（`getObject`，配合 `objectId`）、暂停帧内求值（能读私有作用域里的局部变量） |
| `xbume_debug_output` | `action`(tail/log/source/files), `lines?`, `keyword?`, `regex?`, `offsetLine?`, `scanLines?`, `maxChars?`, `withLineNo?`, `path?`, `centerLine?`, `window?`, `maxLines?`, `max?` | 运行输出尾部（300 行镜像）/ **`log`：分页读 `flutter run` 落盘的日志文件（全量、无 300 行上限）**，`kw`/`regex` 过滤 + `offsetLine` 游标返回 `nextLine` / `hasMore` / `totalLines` / 源码窗口 / 项目 dart 文件列表 |

### inspect（4 个，需 `--tool-groups inspect`）

| 工具 | 主要参数 | 说明 |
| --- | --- | --- |
| `xbume_instances` | `action`(stores/find/tree/set), `class?`, `limit?`, `id?`, `depth?`, `field?`, `value?`, `vtype?` | 实例注册表、按类查所有存活实例（VM `getInstances`）、按 `id` 展开字段树、改字段值 |
| `xbume_widget_tree` | `action`(tree/pick), `x?`, `y?` | 整棵 Widget 树（类型 / Key / 深度 / 逻辑像素 bounds，千节点级）；pick 按屏幕坐标反查组件，等价 GUI 点选 |
| `xbume_perf` | `action`(snapshot/leak/gc/reassemble), `windowMs?`, `classes?` | CPU / 内存 / 帧耗时快照；leak 不传 `classes` 时自动按路由栈 + 项目内 State 类普查（结果为「栈中存活 / 树上 / 堆上 / 疑似泄漏」）；gc 强制回收；reassemble 触发重建（命中断点会返回「app 可能已暂停」而不是超时） |
| `xbume_compare` | `action`(run/status/stop), `sessionA`+`sessionB?`（或 `uriA`+`uriB`）, `name?`, `steps?` | 两个会话并行跑同一场景并逐步骤对比（同一份用例在改动前后 / 两个设备上） |

### data（4 个，需 `--tool-groups data`）

| 工具 | 主要参数 | 说明 |
| --- | --- | --- |
| `xbume_storage` | `action`(list/read/write/reload), `file?`, `xml?`, `dirty?` | 直接读 shared_prefs XML（Android/鸿蒙）或 plist（iOS）；write 先落文件、再经 app 内 SharedPreferences 回写生效；桌面端没有 prefs 文件时给出改用沙盒/DB 的提示 |
| `xbume_db` | `action`(open/schema/query/csv/close), `path?`, `dbId?`, `table?`, `sql?`, `force?` | app 沙盒里的 SQLite：open 拿 `dbId`、schema 省略 `table` 时列出全部表、query 默认只读（写要 `force`）、csv 导出 |
| `xbume_sandbox` | `action`(list/read/download/downloadDir/upload/delete), `path?`, `offset?`, `max?`, `content?`, `contentBase64?`, `name?`, `saveTo?` | 浏览 / 读写 app 沙盒；`upload` 的 `path` 是目标目录 + `name` 是文件名（也可以直接传完整文件路径，工具会拆）；`downloadDir` 打成 tar |
| `xbume_watch` | `action`(add/list/events/pause/remove/clear), `kind?`, `expr?`, `targetId?`, `lib?`, `condition?`, `id?`, `on?` | 监听**表达式 / 字段**的变化（不是文件监听），可带命中条件；事件按时间返回 |

### env（8 个，需 `--tool-groups env`）

| 工具 | 主要参数 | 说明 |
| --- | --- | --- |
| `xbume_ide` | `action`(open/order/setOrder), `file?`, `line?`, `ideOrder?` | 按守护进程里排好的 IDE 顺序打开源码并定位到行列；也可只查 / 改这个顺序 |
| `xbume_daemon` | `action`(status/restart/svc/svcLog/clientLog), `offset?`, `tag?`, `msg?` | 守护进程 / GUI 状态、重启、服务控制（start/stop/restart）、daemon 与前端日志 |
| `xbume_route_locate` | `action`(locate/stack/info/op), `sessionId?`, `uri?`, `idx?`, `nav?`, `open?`, `file?`, `class?`, `op?`, `name?` | 路由栈、按路由定位到源码（`info` 支持相对路径，`locate` 的 `nav/idx` 省略时取栈顶）、GUI 侧路由操作 |
| `xbume_timeline_control` | `action`(list/sub/off/clear), `limit?` | 时间轴订阅开关与清空（GUI 侧），配合只读的 `xbume_timeline` 使用 |
| `xbume_log_history` | `keyword?`, `source?`, `sinceMs?`, `offset?`, `limit?`, `tail?`, `maxChars?` | GUI 一直在采集的日志历史（设备日志 + `flutter run` 输出，跨会话留存、含 iOS 真机拿不到的部分）；`source` 精确过滤、`keyword` 忽略大小写；两个游标：`nextOffset` 从头翻页读全量，`nextSinceMs` 只取增量 |
| `xbume_network_control` | `action`(replay/clear), `id?`, `url?`, `headers?`, `body?`, `maxBody?` | 重放某条请求（可改 URL / 头 / 体）与清空记录；replay 真的会再发一次请求 |
| `xbume_exceptions_hub` | `action`(list/clear/analyze), `id?`, `limit?` | 跨会话异常汇总；analyze 调 AI 给出根因与修复建议（需先在 GUI 配好模型） |
| `xbume_automation` | `action`(list/get/save/delete/run/status/stop/artifact), `name?`, `steps?`, `continueOnFail?`, `file?`, `saveTo?` | 自动化场景的存取、执行、进度与产物（报告 / 截图）下载 |

### ai（1 个，需 `--tool-groups ai`）

| 工具 | 主要参数 | 说明 |
| --- | --- | --- |
| `xbume_ai` | `action`(status/run/stop/goals/report/config), `goal?` | 自然语言目标 → AI 自动操作 app；report 取 HTML 报告，config 读写模型配置（需已在 GUI 里配好 key） |

---

## 4. 典型 prompt

自然语言直接说目标即可，模型会自己串工具。以下是实测可用的九个：

**① 看当前页面有什么**

> 列出当前 app 页面上所有可点的元素，带文字和位置；点第一个有文字的看看跳到哪个页面。

走 `xbume_sessions` → `xbume_screenshot` → `xbume_find_widget` → `xbume_tap`。

**② 按业务源码定位**

> 找到 `XBCellTitleSubtitle` 这个组件，告诉我它由哪个源文件的哪一行创建，然后点它进入详情页。

`xbume_find_widget` 返回的 `source` 字段是 `文件名:行号`，让模型能直接对着代码说话。

**③ 走一遍登录并断言**

> 打开 Login Demo 页，账号填 demo，密码填 123456，点登录，确认页面出现「登录成功」，然后截图给我。

`xbume_tap`(ref) → `xbume_input` → `xbume_tap` → `xbume_find_widget`(text) → `xbume_screenshot`。

**④ 复跑已保存的场景**

> 把 `p10-smoke` 场景跑一遍，失败了告诉我是第几步、错误是什么。

`xbume_scenario_list` → `xbume_scenario_run` → `xbume_scenario_status`（轮询）→ `xbume_report`。

**⑤ 从装包到跑通**

> 把 build/app/outputs/flutter-apk/app-debug.apk 装到那台 Android 上，启动后确认首页渲染出来了。

需 `--tool-groups act,device-write`：`xbume_devices` → `xbume_app_install` →
`xbume_app_launch` → `xbume_screenshot`。

**⑥ 复现一次报错并定位**

> 点「提交」后报错了，帮我看看是哪个异常、发生在哪一行，顺带把之前那次 500 的返回体贴出来。

`xbume_timeline`（把点击后的路由/网络/日志/异常按时间排开，找到出错时刻）→
`xbume_exceptions`（拿到类型/库/上下文/首帧；渲染类错误直接给 `widget` + `file:line:column`
与源码片段，不用再让 AI 猜是哪个组件）→ `xbume_network_detail`（按 id 或
URL 片段取完整响应体）。

**⑦ 改代码 → 选重载级别 → 复跑**

> 把这个标题改成「已修复」，热重载，然后重新点一次提交，确认不再报错。

`xbume_hot_reload`(`mode: reload`，实测空改动 ~150ms、改一个文件 ~230ms) → 改动大时用
`mode: restart`（isolate 会换，缓存自动重建）→ `xbume_tap` / `xbume_scenario_run` 复跑。
前提：会话由 `xbume_app_launch(via: "flutter-run")` 或 GUI「调试」页拉起（落盘清单里有 FIFO），或在 GUI「调试」页「接入」认领到句柄；外部 IDE 终端里的进程不归 MCP 管，只能手动按 `r`。

**三档重载：选错会在旧进程上得出「已修复」**

| 档位 | 调用 | 适用 | 边界 |
| --- | --- | --- | --- |
| ① 热重载 | `xbume_hot_reload {mode:"reload"}` | 函数体 / widget / 文案 / 局部逻辑 | 状态保留，初始化只跑一次的东西不会重跑 |
| ② 热重启 | `xbume_hot_reload {mode:"restart"}` | `initState` / 全局单例 / 路由表初值 / `main()` 里的初始化顺序 | 重跑 `main`、Dart 状态清空，但**不会重装包、也不会重编原生** |
| ③ 进程级重启 | `xbume_app_launch {…, "force": true}` | `pubspec.yaml` / 依赖与资源、原生侧（gradle / plist / 权限 / 插件注册 / MethodChannel 实现）、启动参数（`--dart-define` / flavor / 入口 target）、只在启动那一刻读一次的东西 | 会先按精确 PID 停旧会话（含 app 子进程）再重新编译装包启动，新会话自动设为当前；重启后要重新走一遍路径 |

判断不了属于哪一档时按最重的来（③）：宁可多等一次构建，也不要在旧进程上验收。只想单独停掉进程（不重启）用 `xbume_debug_control`(`action: "stop"`，debug 组)，它只停本服务 / GUI 拉起的会话，IDE 终端里自己起的 `flutter run` 会明确拒绝。

实测（macOS example，`tmp_test/force_restart_probe.py`）：首启 31s → 再调一次 `reused:true`（同 pid、未重装包）→ 改 `main()` 启动标记后 `force:true`，24s 拿到新 pid 且落盘日志里读到新标记 → `stop` 精确结束该 pid 与 3 个子进程。

**⑧ 命中断点看现场**

> 点进列表页是空的，帮我在列表的 build 里下个断点，复现后看 items 为什么是空，查完把断点删掉。

`xbume_debug_attach` → `xbume_debug_breakpoints`(`action: add`, `path` + `line`，可带 `condition`)
→ `xbume_tap` 复现 → `xbume_debug_state`（确认停在哪个文件第几行）→
`xbume_debug_inspect`(`stack` / `vars` / `eval`，表达式能读局部变量) →
`xbume_debug_control`(`stepOver` / `continue`) → `xbume_debug_breakpoints`(`remove`，或 `remember` 留到下次)。

**⑨ 拿数据当证据**

> 这个开关到底存在哪个 prefs 文件里？顺便把数据库 user 表最近 10 条和沙盒里的日志文件都贴出来。

`xbume_storage`(`list` → `read`，必要时 `write` 改回) → `xbume_db`(`open` → `schema` → `query`)
→ `xbume_sandbox`(`list` → `read`，大文件 `download` / `downloadDir` 到本机)。

### 日志取证闭环：让 AI 真的能「读完」日志

验收任务 / 修 bug 的证据链都是「跑一遍 → 读日志 → 判断 → 再改再跑」。五条读日志的通道，
按「要内存里的还是要落盘的」选：

| 通道 | 工具 | 覆盖面 | 上限 |
| --- | --- | --- | --- |
| **运行输出全量** | `xbume_debug_output`(`action: "log"`) | `flutter run` 落盘的 stdout/stderr，等于 IDE 里看到的全部打印 | 无硬上限，靠游标分页 |
| 运行输出尾部 | `xbume_debug_output`(`action: "tail"`) | 同一份输出的内存镜像 | 最近 300 行 |
| app 内日志（内存） | `xbume_console` | app 内 xb_ume 缓冲（含 `debugPrint` 钩子 + 业务日志），`tail` / `offset` / `sinceMs` 三种取法 | 环形缓冲 2000 条 |
| app 内日志（落盘） | `xbume_console` → `logFilePath` + `xbume_sandbox`(`read`) | app 自己把日志写进沙盒文件（默认 `${tmp}/xb_ume_logs/console.log`），跨会话 / 重启可回溯 | 单文件 4MB 轮转，保留 2 个历史文件，按字节分页读 |
| **GUI 日志历史** | `xbume_log_history` | GUI 一直在采集的设备日志 + `flutter run` 输出（含 iOS 真机 `idevicesyslog` 拿不到的历史） | 服务端缓冲 5000 行 / 每来源 1000 行，靠游标分页 |
| 设备系统日志 | `xbume_device_logs` | Android logcat / 鸿蒙 hilog / iOS 模拟器 log show / iOS 真机 idevicesyslog | 单次 dump 的最后 `lines` 条（最多 5000） |

**读完整个文件的正确姿势**（不要用大 `limit` 硬拉，几万行会直接吃掉上下文）：

1. 先带过滤：`{"action":"log","keyword":"ERROR"}`，或 `regex` 精确匹配——大多数排障一次就够；
2. 不知道关键字的先看尾：`offsetLine` 省略（或 ≤0）**且**不带 `keyword` / `regex` 时是
   **tail 语义**，直接给最后 `lines` 行；
3. 要通读就用返回的 `nextLine` 当游标反复调：
   `{"action":"log","lines":200}` → 回 `nextLine: 200, hasMore: true` →
   `{"action":"log","offsetLine":200,"lines":200}` → …直到 `hasMore: false`
   （`offsetLine` 是 1-based，翻页不重不漏）；
4. 命中行要原样贴时传 `withLineNo: false`；单行过长用 `maxChars`（默认 400）截断，
   `scanLines`（默认 20000）限制单次扫描量；
5. 设备侧崩溃 / 系统日志用 `xbume_device_logs`，先 `keyword` / `tag` 过滤，
   `level: "E"` 只留 E 及以上、认不出级别的续行照旧保留；
6. 增量跟日志用游标而不是重拉：`xbume_console` / `xbume_log_history` 都把上一轮的
   `nextSinceMs` 传回 `sinceMs`（只拿新行，开销与历史量无关）；
7. app 重启 / 换会话后要跨会话回溯，读落盘文件：`xbume_console` 返回的 `logFilePath`
   直接喂给 `xbume_sandbox`(`action: "read"`, `offset` / `max` 分页) 或 `download` 到本机
    grep——内存缓冲只有 2000 条，文件才是完整历史；
8. 设备日志历史（包括已经滚出终端窗口的）用 `xbume_log_history`，
   `source` 先看返回值里的 `sources` 有哪几路（如 `logcat` / `flutter` / `hilog`）；
9. 再补结构化证据：`xbume_exceptions`（合并计数 + 源码位置）、`xbume_timeline`
   （路由 / 网络 / 日志 / 异常合成时间线）、`xbume_network_detail`（请求 / 响应体）。

AI 侧一句话模板：

> 跑完之后用 `xbume_debug_output`(`action: "log"`) 按 `nextLine` 游标把日志读完，
> 只把命中关键字的行贴给我；再用 `xbume_device_logs`(`level: "E"`) 确认系统层没有崩溃。

---

## 5. 场景 DSL

`xbume_scenario_run` 的 `steps` 与 GUI「自动化」Tab、CLI `xb_ume run` 完全同一套语义，
场景文件放在 `~/.xb_ume_ide/scenarios/<名>.json`，内容是一个步骤数组。

### 步骤

| type | 参数 | 说明 |
| --- | --- | --- |
| `tap` | `x`,`y`,`phys?` | 逻辑像素坐标；`phys: true` 表示截图物理像素 |
| `swipe` | `x1`,`y1`,`x2`,`y2`,`ms?`,`phys?` | 起终点 + 时长 |
| `input` | `text` | 需先 tap 输入框 |
| `wait` | `ms` | 最长 60s |
| `back` | — | pop 栈顶 |
| `navigate` | `name` | pushNamed（需 app 配了 onGenerateRoute） |
| `assertVisible` | `widget` | 树中存在**可见**的该类型组件 |
| `assertRoute` | `name` | 栈顶路由包含该名 |
| `assertInstance` | `class` | 堆/树上该类型实例数 > 0 |
| `assertText` | `contains?` / `notContains?` | 页面文本断言 |
| `assertRequest` | `urlContains`,`method?`,`not?`,`withinLastMs?` | 网络断言；`not: true` 表示不应出现 |
| `eval` | `expr`,`expect?` | 在 app 内求值，结果需包含 `expect` |
| `waitFor` | `until`, `timeoutMs?`(5000), `intervalMs?`(250) | 轮询到条件满足或超时 |
| `retry` | `steps`, `max?`(3), `intervalMs?`(300) | 子步骤整组重试，全过才算过 |
| `if` | `condition`, `then`, `else?` | 条件分支 |
| `observe` | `include`（routes/text/network/tree/shot） | 把状态快照写进报告 |
| `scrollUntil` | `condition`, `max?`(6), `direction?`(up), `amount?`(0.5), `ms?`(300) | 边滚边等条件 |
| `install` | `deviceId`, `artifact` | 装包 |
| `uninstall` | `deviceId`, `packageId`, `confirm: true` | 高危，必须写 confirm |
| `launchApp` | `deviceId`, `packageId` | 只启动已安装的包 |
| `pressKey` | `deviceId`, `key` | 同 `xbume_press_key` |
| `nativeTap` | `deviceId`, `x`, `y` | 物理像素 |
| `assertNoCrash` | `deviceId`, `packageId?`, `withinLastMs?`(600000) | 窗口内没有崩溃记录 |
| `assertLog` | `contains` 等 | **CLI/MCP 下跳过**（无日志订阅上下文，需 GUI） |
| `record` | — | **未实现**，显式报错而不是假成功 |

### 条件（`waitFor` / `if` / `scrollUntil` 共用）

| kind | 字段 | 说明 |
| --- | --- | --- |
| `visible` | `widget` | 树中存在可见组件 |
| `text` | `contains` / `notContains` | 页面文本 |
| `route` | `name` | 栈顶路由包含 |
| `request` | `urlContains`, `method?`, `withinLastMs?` | 近窗口内命中请求 |
| `expr` | `expr`, `expect?` | app 内求值 |
| `log` | `contains` | 仅 GUI 可用；CLI/MCP 会明确拒绝 |

省略 `kind` 时按字段自动推断（`widget`→visible、`contains`→text、`urlContains`→request、
`expr`→expr、`name`→route），手写场景可以更短。

### 示例

```json
[
  {"type": "waitFor", "until": {"kind": "text", "contains": "Login Demo"}, "timeoutMs": 3000},
  {"type": "observe", "include": ["routes", "text"]},
  {"type": "retry", "max": 2, "intervalMs": 200, "steps": [
    {"type": "tap", "x": 400, "y": 280},
    {"type": "wait", "ms": 600},
    {"type": "assertRoute", "name": "/Login"}
  ]},
  {"type": "if", "condition": {"expr": "1+1", "expect": "2"},
   "then": [{"type": "assertText", "contains": "账号"}],
   "else": [{"type": "observe", "include": ["text"]}]},
  {"type": "scrollUntil", "condition": {"kind": "text", "contains": "提交"}, "max": 3},
  {"type": "assertNoCrash", "deviceId": "emulator-5554", "withinLastMs": 120000}
]
```

CLI 直接跑同一个文件：

```bash
dart run xb_ume:run ~/.xb_ume_ide/scenarios/login.json --uri 52111 --json
```

---

## 6. 设备后端与能力矩阵

`--device-backend` 决定启用哪些后端，默认 `auto` = 自研的四个；**`mobile-mcp` 从不自动启用**。

| 能力 | adb | hdc | simctl | idevice | mobile-mcp |
| --- | --- | --- | --- | --- | --- |
| 列设备 | ✓ | ✓ | ✓ | ✓ | ✓ |
| `install` | ✓ | ✓ | ✓ | ✓ | 按适配器工具探测 |
| `uninstall` | ✓ | ✓ | ✓ | ✓ | 按适配器工具探测 |
| `launch` | ✓ | ✓ | ✓ | — | 按适配器工具探测 |
| `terminate` | ✓ | ✓ | ✓ | — | 按适配器工具探测 |
| `pressKey` | ✓ | ✓ | — | — | 按适配器工具探测 |
| `tapNative` | ✓ | — | — | — | 按适配器工具探测 |
| `crashList` | ✓ | — | ✓ | ✓ | 按适配器工具探测 |
| `crashGet` | ✓ | — | ✓ | ✓ | — |
| `logDump` | ✓ | ✓ | ✓ | ✓（需 `idevicesyslog`） | 按适配器工具探测 |

说明：

- `—` 是后端边界，不是 bug。调用时返回 `unsupported: true` 与原因，模型应改道（例如
  iOS 模拟器没有 pressKey，改用 `xbume_tap`/`xbume_navigate`）。
- `idevice` 依赖本机 `idevice_id` / `ideviceinstaller` / `idevicecrashreport`（macOS 用 brew 安装；
  Windows 需自行下载 libimobiledevice 工具集并加进 PATH）。缺哪个就少哪个能力，`xbume_devices` 会列出来。
- `mobile-mcp` 是可选适配器：需要 Node 18+ 与 `npx`，首次调用会
  `npx -y @mobilenext/mobile-mcp@latest --listen 46150`（可能触发外网下载）。
  探测不到就整体降级为不可用并给出 reason，不影响其他后端。
- 桌面 app（macOS / Windows）没有 adb/hdc/simctl 概念，装包/起进程走 `xbume_app_launch` 的
  `via=flutter-run` 分支（`flutter run -d macos` / `-d windows`）。

---

## 7. 安全模型

MCP 服务能做的事不少，默认值按「最小可用」设计：

1. **工具分组**：默认只有 core + diagnose + run-safe。按键/原生点击要开 `act`；
   装包/卸包/停进程要开 `device-write`。
2. **高危操作二次确认**：`xbume_app_uninstall` / `xbume_app_terminate` 必须显式传
   `confirm: true`，否则直接拒绝并说明将要做什么。
3. **输出路径白名单**：`savePath` 只允许写到 `XB_UME_HOME`、当前工作目录、系统临时目录
   或用户主目录，且拒绝 `..` 与经符号链接逃出白名单。
4. **HTTP 传输**：仅绑定回环地址、校验 `Host`、强制 token（`~/.xb_ume_ide/mcp.token`，0600）。
5. **写操作串行化**：同一会话的 tap/input/swipe/navigate 排队执行，避免注入的手势互相穿插。
6. **不假装支持**：后端缺能力返回 `unsupported` 而不是静默失败；`record` 步骤直接报未实现。
7. **eval 默认关**：`xbume_eval` 能在 app 进程内读写运行时状态，必须 `--allow-eval`
   （或 GUI 卡片勾「允许 eval」）才注册；只接受单条表达式，4000 字符上限，超长直接拒绝。

---

## 8. 排障

| 现象 | 原因与处理 |
| --- | --- |
| `xbume_sessions` 返回空 | app 不是 debug 模式，或没启动。`flutter run` 后重试；也可用 `xbume_app_launch`。 |
| 工具报「未选择会话」 | 先 `xbume_sessions` 看列表，再 `xbume_use_session`；只有唯一会话时会自动选中。 |
| 截图返回空（iOS） | release/AOT 没有 inspector；iOS 需要真机 debug 模式。 |
| `xbume_input` 返回 NO_CONN | 没有焦点输入框：先用 `xbume_tap` 点输入框（用 `ref` 更稳），再 input。 |
| `xbume_navigate` 报 `NO_ROUTE_TABLE` | app 没配 `onGenerateRoute`/`routes`；改用 `xbume_tap` 点入口按钮。 |
| `xbume_network` / `xbume_console` 空 | app 未接入 xb_ume 的 Network / Console 模块，这两个工具读的是 app 内缓冲。 |
| `xbume_console` 看不到刚打的日志 | 老版本默认从最旧处往后取，`limit` 小时拿的是「最早的 N 条」；现在默认 `tail: true` 取最新的。真拿不到再看 app 是否改动了日志模块、或缓冲已满 2000 条环回（更早的读 `logFilePath` 里的落盘文件）。 |
| `xbume_debug_output`(`log`) 报「没有可读的运行日志文件」 | 这个会话不是本服务/GUI 拉起的 `flutter run`（外部 IDE 终端的日志在它自己的控制台），或落盘文件已被清理；用 `xbume_app_launch(via: "flutter-run")` 重新拉起，或改用 `action: "tail"` / `xbume_console`。 |
| `xbume_debug_output`(`log`) 翻页出现重复 / 漏行 | `offsetLine` 是 **1-based** 的下一行位置，把上一轮返回的 `nextLine` 原值传回去即可（不要 ±1）；带过滤时 `nextLine` 指向最后一个命中行的下一行。 |
| `xbume_device_logs` 报 unsupported | 当前后端没声明 `logDump`（`mobile-mcp` 按适配器工具探测，iOS 真机需要本机有 `idevicesyslog`）；`xbume_devices` 的能力矩阵里能直接看到。 |
| `xbume_device_logs` 返回 0 行 | Android 先确认 `adb logcat -d` 能出内容；鸿蒙 `hilog -x` 个别固件不支持时会回退限时流式，此时只衔接到调用那一刻的日志，先把 `durationMs` 调大再重试；iOS 模拟器看 `sinceMinutes` 窗口是否太小。 |
| HTTP 模式 401 | 请求少了 `X-XBUME-Token`；从 `~/.xb_ume_ide/mcp.token` 读，或看 GUI「守护进程」页复制的配置。 |
| HTTP 端口占用 | 换端口：`--http 46141`；GUI 探测会扫 46140-46149。 |
| 会话在但工具全失败 | 常见于鸿蒙 Flutter 引擎（无 expression compilation service）：路由栈/字段树/沙盒等依赖 eval 的功能不可用，会给出明确提示。 |
| macOS 上自动化卡在导航 | app 在后台时帧会被冻结：`open -a <绝对路径>` 把它切到前台再跑。 |
| `xbume_hot_reload` 报「未找到由本服务拉起」 | 会话来自外部 IDE/终端的 `flutter run`（没有本服务的落盘清单 / FIFO）；用 `xbume_app_launch(via: "flutter-run")` 重新拉起（同设备同目录已有本服务会话时会直接复用），或手动按 `r`。 |
| `xbume_app_launch` 报「已有 flutter run 正在同一目录跑」 | 外部（IDE/终端）已经在这个设备的这个项目上跑着 `flutter run`；继续会重装包并顶掉它（IDE 会报 Lost connection）。只是要接入就 `xbume_sessions` → `xbume_use_session`（只读，无热重载），或在 GUI「调试」页「接入」；确认顶掉才传 `force: true`。 |
| `xbume_eval` 不在工具列表里 | 没开 `--allow-eval`（GUI 卡片上的「允许 eval」）；开启后要重启服务。 |
| debug 组报「连不上 VM service」 | 会话必须是 debug 模式且端口可达；release / AOT 没有 VM service，做不了断点与单步。 |
| `xbume_debug_attach` 接上了，但 `vars` 空空 | 进程没暂停；先 `xbume_debug_control`(`pause`) 或命中一个断点，再看 `xbume_debug_state` 确认 `paused: true`。 |
| `xbume_debug_control`(`hot`) 报「不是由本服务拉起」 | 同 `xbume_hot_reload`：外部 IDE / 终端里的 `flutter run` 不归 MCP 管，只能手动按 `r` / `R`（不会盲发到其他会话）。 |
| data / inspect / env / ai 组报「连不上 GUI」 | 这几组走本机 GUI 的 HTTP 接口，先把工具箱打开（端口自动发现）；`403` 是令牌轮换了，重开 GUI 或重读 `~/.xb_ume_ide/gui.token`。 |
| `xbume_perf`(`leak`) 报「自动收集为空」 | 目标页面没进过路由栈，或 State 类名不以 `State` 结尾；直接传 `classes: "XxxState,YyyState"`。 |
| `xbume_db`(`schema`) 回来是空 | 没 `open` 或路径不对；先 `open` 拿 `dbId`，再 `schema`（省略 `table` 会列出全部表）。 |
| `xbume_watch` 收不到事件 | 它监听的是**表达式 / 字段**（不是文件），表达式要在表达式编译环境里可求值，且值真的变过；Android/鸿蒙部分引擎没有 expression compilation，会报错。 |
| `xbume_sandbox` 找不到文件 | 沙盒根是 app 自己的容器目录（macOS 在 `~/Library/Containers/<id>/Data`），不能用 `/tmp` 或宿主机路径；先 `list` 看真实目录。 |
| `xbume_storage` 桌面端没数据 | macOS / Windows 桌面 app 没有 shared_prefs 文件（不是 Android 的 XML）；改用 `xbume_sandbox` 或 `xbume_db`。 |

---

## 9. 已知缺口

按「不做假装支持」原则显式列出，后续版本补齐：

- **日志通道是「拉」不是「推」**：MCP 是请求-响应，没有推送订阅；要看最新的就再调一次
  （`xbume_debug_output`(`log`) 不带 `offsetLine` 即取尾部，`xbume_console` 传上一轮的
  `nextSinceMs` 只拿新增），不要在客户端等通知。
- **`xbume_debug_output`(`log`) 只覆盖本服务/GUI 拉起的 `flutter run`**：外部 IDE / 终端起的进程
  日志在它自己的控制台，落盘文件不在 `~/.xb_ume_ide` 下，只能走 `action: "tail"`（内存镜像，300 行）
  或 App 内缓冲（`xbume_console`）。
- **设备日志只能取快照**：`xbume_device_logs` 是一次性 dump（不驻留进程），iOS 真机经
  `idevicesyslog` 只能限时流式读、没有历史回溯；真正的「长时间、全量、可回溯」靠 app 自己
  将日志写入沙盒文件，再用 `xbume_sandbox`(`read` / `download`) 分页读。

- **`record` 场景步骤未实现**：录屏涉及设备端进程生命周期，未实测前不提供假实现；
  请用系统录屏。GUI 与 CLI 都会明确报「尚未实现」。
- **桥接类工具依赖本机 GUI 在跑**：data / inspect / env / ai 四组走 GUI 的 HTTP 接口
  （不直连 VM），GUI 关着就只能用 core / debug；debug 组不受影响。
- **`xbume_instances` 只认已加载的类**：底层是 VM `getInstances`，JIT 懒加载导致
  没进过内存的类查不到；`xbume_perf`(`leak`) 的自动普查同理，只覆盖已加载的 State。
- **`xbume_hot_reload` / `xbume_debug_control`(`hot`) 只作用于本服务/GUI 拉起或认领的 `flutter run`**：不接管外部 IDE/终端里的进程，也不按名字杀进程，那种情况只能手动按 `r` / `R`。`xbume_app_launch` 对**同设备 + 同目录 + 同 target 的本服务会话**直接复用（返回 `reused: true`，不重装包），对外部会话仍默认拒绝启动（它不会主动 kill 外部进程，但重装包会间接顶掉那个会话）。
- **有副作用的桥接动作要显式调用**：`xbume_automation`(`run` / `stop`)、
  `xbume_network_control`(`replay`)、`xbume_compare`(`run`)、`xbume_ai`(`run`) 会真的操作 app / 发请求；
  只读排查不要顺手带上。
- **`assertLog` 在 CLI/MCP 下跳过**：它依赖 GUI 的日志订阅上下文（`skip`，不算失败）。
- **mobile-mcp 的常驻进程不由我们回收**：`mobilecli-* daemon` 若被适配器拉起，
  退出后可能仍在运行；需要时手动结束。xb_ume 只负责自己拉起的 `npx` 子进程。
- **mobile-mcp 能力是「探测到的」而非保证的**：适配器版本变化会改变可用工具集，
  以 `xbume_devices` 返回的 capabilities 为准。
- **HTTP 传输不提供 SSE 流**：`GET /mcp` 返回 405。需要流式通知的客户端请用 stdio。
- **Windows 上「外部会话防顶掉」体检不生效**：启动前扫本机 `flutter run` 依赖
  `ps` + `lsof -d cwd`，Windows 没有这两个命令，扫描结果固定为空表，
  `xbume_app_launch` 不会拦外部（IDE）起的同设备同目录 `flutter run`。
  但**本服务/GUI 拉起的会话不受影响**（复用判定读落盘清单 `launch/live/<pid>.json`，跨平台一致）。
- **Windows 没有 LaunchAgent 的 KeepAlive**：`--install` 在 Windows 写 HKCU 注册表
  Run 键（登录自启），daemon 崩溃后不会被拉起；macOS 的 LaunchAgent 才会。
  Windows 的 daemon 日志在 `~/.xb_ume_ide/daemon.log`。
- **`xbume_keep_awake` 依赖设备端命令**：鸿蒙走 `power-shell timeout`，个别旧固件没有这个子命令（`power-shell` 对不认识的子命令仍返回 0，所以只能按输出里的 error / fail / not found 判失败）；遇到时改用应用内 `setWindowKeepScreenOn`（ArkTS，需重新编包，仅 app 前台生效）或 DevEco 的「屏幕常亮」。Android 的 `svc power stayon` 只在插电时生效，拔线自动恢复；两边改的都是运行时状态，不做持久化。
- **iOS 专属能力的宿主限制**：模拟器（`simctl`）与 `idevice*` 系后端依赖 macOS 工具链；
  偏好设置 plist 编辑用本机 `plutil` 转换。在 Windows 上这些入口会回「不支持」或
  报找不到工具，不影响 Android / 鸿蒙 / Windows 桌面链路。
- **sqlite3 查询依赖本机命令行**：macOS 自带；Windows 需自行安装并加入 PATH
  （`winget install SQLite.SQLite`），缺失时 GUI 会明确报错而不是空白。
