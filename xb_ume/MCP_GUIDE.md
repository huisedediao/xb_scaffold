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

启动后 stderr 会打印可直接粘贴的配置片段。

### 常用参数

| 参数 | 说明 |
| --- | --- |
| `--stdio` | stdio 传输（默认） |
| `--http <port>` | Streamable HTTP，默认 46140 |
| `--uri <port\|ws-url>` | 手工指定调试会话，跳过自动发现；可重复 |
| `--tool-groups <list>` | `all` 或逗号分隔；目前可用的扩展组是 `act`、`device-write` |
| `--no-tool-groups` | 只暴露 core 组 |
| `--device-backend <list>` | `auto`（默认）/ `adb,hdc,simctl,idevice` / `mobile-mcp` |
| `--allow-eval` | 预留开关，当前无对应工具（见「已知缺口」） |

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

> GUI「守护进程」页的「复制 MCP 配置」会按当前运行状态生成上面两种片段之一
> （HTTP 模式自动带上 token），直接粘贴即可。

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
# 默认：core + diagnose + run-safe（20 个工具，全是只读或 app 内注入）
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

工具名统一前缀 `xbume_`。默认暴露 **20 个**（core 14 + diagnose 3 + run-safe 3）。

### core（14 个）

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
| `xbume_console` | `level?`, `keyword?`, `sinceMs?`, `limit?` | app 内 xb_ume 日志 |
| `xbume_scenario_run` | `name?` 或 `steps?`, `continueOnFail?`, `shotEveryStep?` | 异步运行，立刻返回 `runId` |
| `xbume_scenario_status` | `runId?` | 逐步骤 pass/fail/skip + 错误 + 耗时 + 报告路径 |
| `xbume_app_launch` | `deviceId`, `via?`(flutter-run 默认), `packageId?`, `target?`, `waitVm?` | `via=flutter-run` 顺带把新会话设为当前 |

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

自然语言直接说目标即可，模型会自己串工具。以下是实测可用的五个：

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
- `idevice` 依赖本机 `idevice_id` / `ideviceinstaller` / `idevicecrashreport`（brew 安装）。
  缺哪个就少哪个能力，`xbume_devices` 会列出来。
- `mobile-mcp` 是可选适配器：需要 Node 18+ 与 `npx`，首次调用会
  `npx -y @mobilenext/mobile-mcp@latest --listen 46150`（可能触发外网下载）。
  探测不到就整体降级为不可用并给出 reason，不影响其他后端。
- macOS 桌面 app 没有 adb/hdc/simctl 概念，装包/起进程走 `xbume_app_launch` 的
  `via=flutter-run` 分支（`flutter run -d macos`）。

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

---

## 9. 已知缺口

按「不做假装支持」原则显式列出，后续版本补齐：

- **`record` 场景步骤未实现**：录屏涉及设备端进程生命周期，未实测前不提供假实现；
  请用系统录屏。GUI 与 CLI 都会明确报「尚未实现」。
- **`inspect` / `ai` / `ide` 三个工具组为预留**：目前没有对应工具，
  `--tool-groups inspect` 之类只是允许但不会多出工具。
- **`--allow-eval` 为预留开关**：`xbume_eval` 尚未注册；场景里的 `eval` 步骤与
  GUI 的沙盒求值不受影响。
- **`assertLog` 在 CLI/MCP 下跳过**：它依赖 GUI 的日志订阅上下文（`skip`，不算失败）。
- **mobile-mcp 的常驻进程不由我们回收**：`mobilecli-* daemon` 若被适配器拉起，
  退出后可能仍在运行；需要时手动结束。xb_ume 只负责自己拉起的 `npx` 子进程。
- **mobile-mcp 能力是「探测到的」而非保证的**：适配器版本变化会改变可用工具集，
  以 `xbume_devices` 返回的 capabilities 为准。
- **HTTP 传输不提供 SSE 流**：`GET /mcp` 返回 405。需要流式通知的客户端请用 stdio。
