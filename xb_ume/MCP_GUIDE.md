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
- 一次开全 29 个工具（core 18 + diagnose 3 + run-safe 3 + act 2 + device-write 3）；
  「AI 调试」入口另外带上 `xbume_eval`（共 30 个）：
  装包/卸包/停进程这类高危操作仍要求参数里的 `confirm`，但**服务本身对
  本机任何进程都可见**，不需要时就把服务停掉。
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
| `--tool-groups <list>` | `all` 或逗号分隔；目前可用的扩展组是 `act`、`device-write` |
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
# 默认：core + diagnose + run-safe（24 个工具，全是只读或 app 内注入）
dart run xb_ume:mcp

# 加上按键 / 原生点击
dart run xb_ume:mcp --tool-groups act

# 加上装包 / 卸包 / 停进程（高危，见「安全模型」）
dart run xb_ume:mcp --tool-groups act,device-write

# 再加可选后端（会拉起 npx，首次需联网下载）
dart run xb_ume:mcp --device-backend adb,hdc,simctl,idevice,mobile-mcp
```

---

## 3. 工具清单

工具名统一前缀 `xbume_`。默认暴露 **24 个**（core 18 + diagnose 3 + run-safe 3）；
加 `--allow-eval` 再多个 `xbume_eval`（25 个），`--tool-groups all` 全开则是 29 / 30。

### core（18 个）

| 工具 | 主要参数 | 返回 |
| --- | --- | --- |
| `xbume_sessions` | `refresh?` | 会话列表：id / 端口 / app 名 / 平台 / 来源（adb:hdc:port）/ 当前选中 |
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
| `xbume_console` | `level?`, `keyword?`, `sinceMs?`, `limit?` | app 内 xb_ume 日志 |
| `xbume_exceptions` | `kind?`(flutter/platform/app/all), `typeContains?`, `keyword?`, `sinceMs?`, `limit?` | 结构化异常：类型 / 摘要 / 库 / 上下文 / 栈 / 重复次数（比日志多出结构与合并计数）；渲染 / build 类错误额外给 `widget` 与 `source{file,line,column,snippet}`——直接指出出错的组件与业务源码位置，`snippet` 是 daemon 读的源码 ±2 行（真机调试时源码不在本机则只给路径） |
| `xbume_timeline` | `kinds?`(route/net/log/exception), `keyword?`, `sinceMs?`, `limit?` | 路由 + 网络 + 日志 + 异常按时间合并成一条流，定位「点一下之后发生了什么」 |
| `xbume_scenario_run` | `name?` 或 `steps?`, `continueOnFail?`, `shotEveryStep?` | 异步运行，立刻返回 `runId` |
| `xbume_scenario_status` | `runId?` | 逐步骤 pass/fail/skip + 错误 + 耗时 + 报告路径 |
| `xbume_app_launch` | `deviceId`, `via?`(flutter-run 默认), `packageId?`, `target?`, `waitVm?`, `cwd?`, `force?` | `via=flutter-run` 顺带把新会话设为当前；**同设备同目录已有 `flutter run`（如 IDE 起的）时默认拒绝**（继续会重装包并顶掉那个会话），确认重起传 `force: true` |
| `xbume_hot_reload` | `sessionId?` 或 `pid?`, `mode?`(reload/restart), `timeoutMs?` | 向本服务拉起的 `flutter run` 写 `r`/`R`：改完代码就地热重载/热重启，返回耗时与完成行；热重启会清 isolate 缓存 |
| `xbume_eval` | `expr`, `lib?`, `maxChars?` | **需 `--allow-eval`**：在 app 进程内求值单行表达式，返回 `值` + 库 + 类型；编译错误与运行时异常分开报 |

### run-safe（3 个，默认开启）

| 工具 | 主要参数 | 说明 |
| --- | --- | --- |
| `xbume_scenario_list` | — | 列 `~/.xb_ume_ide/scenarios` 下 GUI 保存的场景与步数 |
| `xbume_scenario_stop` | `runId?` | 请求停止；已执行步骤保留，剩余标 skip |
| `xbume_report` | `runId?` | 自包含 HTML 报告的路径与大小 |

### diagnose（3 个，默认开启）

| 工具 | 主要参数 | 说明 |
| --- | --- | --- |
| `xbume_devices` | `refresh?` | 各后端可用性 + 能力矩阵 + 设备清单（不可用后端带 reason） |
| `xbume_crash_list` | `deviceId`, `packageId?`, `limit?` | Android logcat crash 缓冲区 / iOS DiagnosticReports / idevicecrashreport |
| `xbume_crash_get` | `deviceId`, `crashId` | 取原始日志（超 64KB 截断） |

### act（2 个，需 `--tool-groups act`）

| 工具 | 主要参数 |
| --- | --- |
| `xbume_press_key` | `deviceId`, `key`（back/home/enter/delete/tab/escape/menu/appSwitch/volumeUp/volumeDown/power） |
| `xbume_native_tap` | `deviceId`, `x`, `y`（屏幕物理像素） |

### device-write（3 个，需 `--tool-groups device-write`，高危）

| 工具 | 主要参数 | 保护 |
| --- | --- | --- |
| `xbume_app_install` | `deviceId`, `artifact`（.apk/.ipa/.app/.hap） | 校验后缀与文件存在 |
| `xbume_app_uninstall` | `deviceId`, `packageId`, `confirm` | 必须显式 `confirm: true` |
| `xbume_app_terminate` | `deviceId?`, `packageId?` 或 `pid`, `confirm` | 必须显式 `confirm: true`；支持停 `flutter run` 进程 |

---

## 4. 典型 prompt

自然语言直接说目标即可，模型会自己串工具。以下是实测可用的七个：

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

**⑦ 改代码 → 热重载 → 复跑**

> 把这个标题改成「已修复」，热重载，然后重新点一次提交，确认不再报错。

`xbume_hot_reload`(`mode: reload`，实测空改动 ~150ms、改一个文件 ~230ms) → 改动大时用
`mode: restart`（isolate 会换，缓存自动重建）→ `xbume_tap` / `xbume_scenario_run` 复跑。
前提：会话由 `xbume_app_launch(via: "flutter-run")` 拉起；外部终端里的进程不归 MCP 管。

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
| HTTP 模式 401 | 请求少了 `X-XBUME-Token`；从 `~/.xb_ume_ide/mcp.token` 读，或看 GUI「守护进程」页复制的配置。 |
| HTTP 端口占用 | 换端口：`--http 46141`；GUI 探测会扫 46140-46149。 |
| 会话在但工具全失败 | 常见于鸿蒙 Flutter 引擎（无 expression compilation service）：路由栈/字段树/沙盒等依赖 eval 的功能不可用，会给出明确提示。 |
| macOS 上自动化卡在导航 | app 在后台时帧会被冻结：`open -a <绝对路径>` 把它切到前台再跑。 |
| `xbume_hot_reload` 报「未找到由本服务拉起」 | 会话来自外部终端或 IDE 的 `flutter run`；用 `xbume_app_launch(via: "flutter-run")` 重新拉起（若同设备同目录已有进程会先报错误让你确认，见下），或手动按 `r`。 |
| `xbume_app_launch` 报「已有 flutter run 正在同一目录跑」 | IDE/终端已经在这个设备的这个项目上跑着 `flutter run`；继续会重装包并顶掉它（IDE 会报 Lost connection）。要复用就 `xbume_sessions` → `xbume_use_session`（无热重载）；确认重起传 `force: true`。 |
| `xbume_eval` 不在工具列表里 | 没开 `--allow-eval`（GUI 卡片上的「允许 eval」）；开启后要重启服务。 |

---

## 9. 已知缺口

按「不做假装支持」原则显式列出，后续版本补齐：

- **`record` 场景步骤未实现**：录屏涉及设备端进程生命周期，未实测前不提供假实现；
  请用系统录屏。GUI 与 CLI 都会明确报「尚未实现」。
- **`inspect` / `ai` / `ide` 三个工具组为预留**：目前没有对应工具，
  `--tool-groups inspect` 之类只是允许但不会多出工具。
- **性能/内存证据仍只在 GUI**：CPU、内存、帧耗时等采样没有进 MCP；
  `xbume_eval` 只能读到 `ProcessInfo` 之类的单点值，看趋势要去「性能」Tab。
- **`xbume_hot_reload` 只作用于自己拉起的 `flutter run`**：不接管外部终端里的进程，也不按名字杀进程，那种情况只能手动按 `r` / `R`。`xbume_app_launch` 在**同设备同目录**已有 `flutter run` 时默认拒绝启动（它不会主动 kill 外部进程，但重装包会间接顶掉那个会话）。
- **`assertLog` 在 CLI/MCP 下跳过**：它依赖 GUI 的日志订阅上下文（`skip`，不算失败）。
- **mobile-mcp 的常驻进程不由我们回收**：`mobilecli-* daemon` 若被适配器拉起，
  退出后可能仍在运行；需要时手动结束。xb_ume 只负责自己拉起的 `npx` 子进程。
- **mobile-mcp 能力是「探测到的」而非保证的**：适配器版本变化会改变可用工具集，
  以 `xbume_devices` 返回的 capabilities 为准。
- **HTTP 传输不提供 SSE 流**：`GET /mcp` 返回 405。需要流式通知的客户端请用 stdio。
- **Windows 上「同设备同目录防顶掉」体检不生效**：启动前扫本机 `flutter run` 依赖
  `ps` + `lsof -d cwd`，Windows 没有这两个命令，扫描结果固定为空表，
  `xbume_app_launch` 不会拦「已有同设备同目录的 flutter run」。要复用会话请自己先
  `xbume_sessions` → `xbume_use_session`，否则重装包会顶掉 IDE 那个会话。
- **Windows 没有 LaunchAgent 的 KeepAlive**：`--install` 在 Windows 写 HKCU 注册表
  Run 键（登录自启），daemon 崩溃后不会被拉起；macOS 的 LaunchAgent 才会。
  Windows 的 daemon 日志在 `~/.xb_ume_ide/daemon.log`。
- **iOS 专属能力的宿主限制**：模拟器（`simctl`）与 `idevice*` 系后端依赖 macOS 工具链；
  偏好设置 plist 编辑用本机 `plutil` 转换。在 Windows 上这些入口会回「不支持」或
  报找不到工具，不影响 Android / 鸿蒙 / Windows 桌面链路。
- **sqlite3 查询依赖本机命令行**：macOS 自带；Windows 需自行安装并加入 PATH
  （`winget install SQLite.SQLite`），缺失时 GUI 会明确报错而不是空白。
