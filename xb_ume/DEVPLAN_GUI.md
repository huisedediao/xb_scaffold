# xb_ume GUI 迭代计划（本地持久化，防上下文丢失）

> 状态：进行中。完成一项把 `[ ]` 改 `[x]`，并在「进度记录」追加一行。
> 会话恢复指引：读本文件 + bin/ide_gui.dart 尾部注释即可续作。
> 硬约束：零 App 侵入（只用 VM service 协议）；部署流程 analyze → JS 提取 node --check → cp → pkill → open → curl 验证；文档 GUI_GUIDE.md 同步。

## P1 实时截图 `[x]`
- [x] 后端 `/api/screenshot?uri=<ws>`：rawRpc `_flutter.screenshot` → base64（data 字段）→ 解码 image/png；探针已验证（852KB PNG）
- [x] 前端「截图」Tab：img + 手动刷新 + 自动刷新（关/1s/2s/5s）+ 下载 PNG
- [x] 验证：curl 返回 PNG；GUI 显示
- 备注：DDS 转发私有方法 OK；响应字段 `data`（Screenshot 类型）；超时 15s

## P2 热重载 / 热重启 / GC `[x]`
- [x] 探针定论：ext.flutter.reassemble ✓（扩展名直接作 method，callServiceExtension 不是协议方法名）；_collectAllGarbage ✓；真热重载/热重启需编译器（reloadSources 无 kernel 报 "Error while starting Kernel isolate task"）——诚实降级：不做按钮，文档说明
- [x] 后端 /api/runtime/op（POST，op=reassemble|gc）；前端守护 Tab「UI 重建」「触发 GC」按钮 + 状态 span
- [x] 真机验证：reassemble {"ok":true}、gc {"ok":true}

## P3 异常实时捕获 `[x]`
- [x] 方案修正：VM service 无 ExceptionThrown 事件（探针证伪原假设）→ 双通道：① Extension 流 Flutter.Error 结构化事件（debug 自动启用，App 零接入）；② 输出流未捕获异常块解析（引擎 Unhandled Exception / xb_scaffold XBErrorHandler 两种头格式）
- [x] 后端：Extension 流订阅（每个会话第 3 条流）、_UncaughtParser 状态机（头/帧/省略行，无位置帧行保留 raw，800ms 无新行结算）、同 hash 10s 窗口合并 ×N、上限 200、ws 广播 + snapshot 携带、/api/exceptions、/api/exceptions/clear、/api/openide
- [x] 前端：异常 Tab（列表/过滤/清空/徽标）+ 栈帧/Widget「跳转」（复用 ideOrder）+ 红浮层（12s 自动消失，点击进 Tab）
- [x] 真机验证：CrashPage 框架异常（×2 合并、栈帧解析本机文件、widget 位置提取）+ eval microtask 未捕获异常（XBErrorHandler 块解析）；跳转 {"ok":true}
- [x] 修复两处解析 bug：widget 位置正则 file:/// 多一个斜杠永不匹配；无位置帧行（eval 生成栈 "#0 Eval...()"）被误判为块结束致整块丢弃
- [x] 加固：GUI 优雅退出（SIGTERM/SIGINT → 主动关闭全部 VM 流连接）——持有流订阅的连接被硬切断会令 DDS 永久死锁（实测 kill 旧 GUI 后本机全部 flutter run 会话无响应，DevTools 也连不上）

## P4 路由操作 `[x]`
- [x] 后端 /api/routeop（POST，op=pop|remove|push）：与 routestack 同款 walk 收集 Navigator，在 navigator.dart 库上下文 eval；pop 校验仅栈顶（NOT_TOP）；remove 保护唯一路由（LAST_ROUTE）；push 先经私有 _routeNamed 校验（解析不出报 UNKNOWN，路由框架抛错捕获为 ERR:FlutterError）再 push 生成的 Route，同步可控无悬挂 Future
- [x] 前端：路由栈行尾「操作」列（pop 仅栈顶 + 非唯一路由；remove 任意非唯一路由）+ 每个 Navigator 分组头 pushNamed 输入框（回车/按钮）；结果码映射友好提示；成功后双次延迟刷新（避免拉到出栈前旧栈）
- [x] macOS 会话验证：pushNamed('/') OK；未知名报错路径；pop 栈顶 OK / 非栈顶 NOT_TOP；remove ×12 全部生效（残留 7 层测试 CrashPage 全部清理）；LAST_ROUTE 保护；浏览器 UI 验证（列表/操作列/pushNamed/pop/remove/错误提示全通过）
- [x] 重要发现：macOS app 切后台（hidden）后帧调度冻结，未完成转场卡在 pushing，pop/remove 返回成功但不出栈——app 回前台即恢复；已写入 GUI_GUIDE 注意事项

## P5 内存泄漏检测 `[x]`
- [x] 后端 /api/leakcheck（POST，classes 逗号分隔）：先 _collectAllGarbage 再逐类双计数 —— 树上（Element 树遍历，树上=存活正常形态）+ 堆上（getClassList + getInstances totalCount，limit=1 只取计数）；带泛型 State 名（如 _FooState<T>）自动剥泛型再匹配 VM 类名（实测 getClassList 类名无泛型实参）
- [x] 前端：路由栈工具栏「泄漏检测」按钮 + 手动补类名输入框 + 结果表（四类结论：栈中存活/树上存活/疑似泄漏红色/已释放）；类名自动累积（rtInfo 回调记录当前栈 + rtRefresh 清理已退出行入历史集合，纯内存态）；判据 inStack→tree>0→heap>0 三层递减，Overlay 覆盖卸载（树上 0 但 State 由 Route 正常持有）不误报
- [x] macOS 验证：命令行阴/阳性对照（栈中 tree=1 heap=1；push→remove 已释放 heap=0；FocusManager 监听器闭包持有人为泄漏 remove 后 heap=1 判疑似泄漏）+ 浏览器 UI 两轮（A：绿栈中存活/已释放；B：红疑似泄漏/绿栈中存活全对）
- [x] 排障沉淀：后台 nohup flutter run 读 stdin 触发 SIGTTIN 使整个进程组 stopped（VM service 假死、树只剩骨架）—— 用 tail -f /dev/null 管道作 stdin 根治；探针 walk 一律用显式栈（递归闭包在 VM eval 中参数类型推断不可靠）

## P6 状态面板 `[x]`
- 新「状态」Tab：CN 类聚合（类名/实例数/监听者数/字段摘要/跳实例）

## P7 网络改参重放 + 响应 diff `[x]`
- Network 详情「编辑后重放」+ 与原响应逐字段 diff（复用前端快照对比思路）

## P8 沙盒文件上传 `[x]`
- `/api/sandbox/upload`（base64+path）→ 复用 Storage 写通道；文件树「上传到此处」

## P9 Widget 树浏览 + 截图高亮 `[x]`
- `ext.flutter.inspector.getRootWidgetSummaryTree`（groupName）→ 树 Tab；
- 树节点 ↔ 截图 bounds 高亮；点截图 hitTest 反查节点

## P10 自动化路径 `[x]`
- 场景存电脑端 `~/.xb_ume_ide/scenarios/*.json`；schema：
  `{name, steps:[{type: tap|input|swipe|wait|back|navigate|assertVisible|assertRoute|assertInstance|eval, ...}]}`
  （assertVisible 目标类型用独立 `widget` 字段，type 被步骤类型占用；tap/swipe 坐标 `phys:true` 为截图物理像素，默认逻辑像素）
- 执行引擎：GUI 串行队列；tap=eval GestureBinding.handlePointerEvent(down/move/up)；input=TextInput 注入；断言=eval/路由快照/堆扫描字段取值
- 录制：截图 Tab「录制」开关，点截图插 tap 步骤
- 报告：逐步 status/耗时/期望 vs 实际/每步截图；失败详细报告；导出 JSON/HTML
- UI：新「自动化」Tab（场景列表/步骤编辑/执行停止/进度/报告）

## P11 AI 驱动自动化 `[x]`
- 自然语言目标 → 循环「截图→AI 决策→执行→反馈」；AI 返回 `{done, think, steps}`，steps 限白名单类型复用 P10 `_autoExecStep`
- OpenAI 兼容 `/chat/completions`（vision）；配置 `~/.xb_ume_ide/ai_config.json`（baseUrl/apiKey/model，密钥打码）
- 防失控：每轮 ≤5 步（轮数不限制，AI done/手动停止结束）；失败截图反馈 AI 自适应；请求/解析失败即停
- 结束后「存为场景」拍平各轮已执行步骤 → P10 场景回放（无 AI 依赖）
- UI：自动化 Tab 底部「AI 驱动」区块（目标输入/执行/停止/设置/轮卡片报告）

## P12 AI 驱动增强：结构化上下文 + 非视觉断言 `[x]`
- 每轮上下文四项拼进消息（单项失败标 N/A 不中断）：路由栈（复用 _autoRoutesExpr）/ 页面文本（_aiPageTextExpr BFS Text.data+EditableText，去重、跳过 Offstage 保活子树、限 40 项/300 字）/ 最近网络请求（_aiNetRecords 复用 xb_ume core eval，e.time >= run startedAt，最近 8 条）/ 增量日志（GUI 日志 buffer 加 rcvMs 毫秒戳，游标式增量，E/W 全给 + I 级含 error/exception/fail/crash 关键字，上限 25 条）
- 三种非视觉断言（AI 与场景回放共用 _autoExecStep）：assertText contains/notContains、assertRequest urlContains/method/not/withinLastMs（时间窗默认 run 起点，回放兑底 5 分钟）、assertLog contains/notContains/level/source/withinLastMs
- 上下文开关 ai_config.json ctx{routes,text,net,log}（默认全开）：关闭项消息不出现、AI 返回的对应断言步骤被丢弃、回放时该断言报 SKIPPED；AI 设置弹层 4 checkbox
- system prompt 补三断言 schema + 「数据层问题优先用结构化上下文证据，截图只用于定位坐标」

## P13 AI 调用失败自动重试 `[x]`
- _aiLoop 轮内重试：接口请求异常/回复不可解析为 JSON/未给出有效步骤三类 AI 侧故障不再直接终止，同轮自动重试（上限 _aiMaxRetries=3，递增退避 2s/4s/6s，每次重试前检查 stopReq 可手动打断）；重试耗尽才停止并报「已重试 N 次仍失败」
- 轮报告加 retries 字段；前端轮卡片黄色显示「AI 调用重试 N 次」
- 验证（example macOS 会话 + 故障 mock）：mock 前 N 次请求故障两种模式——HTTP 500（retries=1 后成功）与 200+纯文本无 JSON（retries=2 后成功），均走完三段剧本至 done，任务不中断

## P14 swipe 滚动失效修复（合成事件 delta/timeStamp）`[x]`
- 症状：f_jlink 真机 AI 驱动连续多轮 swipe 全部 pass 但列表纹丝不动（r15-r18 截图字 节级相同），tap/input 正常；macOS example 同样复现
- 根因：合成 PointerMoveEvent 默认 delta=Offset.zero，DragGestureRecognizer 用 event.delta 累计位移判 touchSlop（monodrag.dart _pendingDragOffset += event.delta），永远超不过 18px slop → drag 永不启动；且 timeStamp 全为 Duration.zero，真实触摸时间戳递增（VelocityTracker 算 fling 速度依赖它）
- 修复：swipe 注入的 move 事件显式传 delta（相邻逻辑像素差）+ 按计划时刻生成递增微秒 timeStamp；验证：单 eval 同步派发探针 offset 0→416（含 fling 惯性）、example swipe-probe 场景前后截图不同且列表真实滚动

## P15 日志多关键字过滤 + 增量渲染（复制友好）`[x]`
- 多关键字 OR：f-kw 空格分隔多关键字，包含任一即显示（消息+tag 不区分大小写）；输入防抖 200ms
- 增量渲染：旧实现每条 WS 日志到达都全量 innerHTML 重建 + 无条件拉底——选区被清、视觉闪烁，用户被迫暂停才能复制。新实现：过滤条件签名比对，条件不变时新日志只 insertAdjacentHTML 追加命中行（无命中时 DOM 完全不动）；5000 行环形缓冲截断产生游标缺口时回退全量
- 滚动跟随改贴底判断（距底 <40px 才拉底）：往上翻阅/选中时不再被强制拉底
- 验证（浏览器 agent + example 5500 行 hilog/flutter 日志）：多关键字 OR（两不同源词交集命中行全显）、选中 167 字符 10 秒不丢（期间 scrollHeight 增长 922px）、上翻 scrollTop 精确保持、清空过滤全量恢复，全过
- 复制按钮：复制框中当前显示（含过滤）的全部日志到剪贴板；首版从 logs 缓冲重算，浏览器验证发现与显示不一致（5000 条全局缓冲被 hilog/其他会话高频挤占，选中会话行被挤出后重算远少于框中甚至为空）→ 改为直接读 DOM 渲染行（querySelectorAll lv-* 的 innerText）所见即所得；复验 6 步全过（无过滤/过滤/空结果三态，剪贴板与 DOM 首尾行逐字符一致）
- 已知遗留（预存在，非本次引入）：5000 条全局缓冲无会话配额，多来源高频日志会挤掉低频会话的历史行，过滤条件变化触发全量重建时显示会缩水；如需彻底解决可做会话隔离配额
- 到顶/到底按钮：一键滚到最早/最新日志；到底后距底 <40px 贴底跟随自动恢复（新日志持续可见），到顶后不被新日志拉走；浏览器验证 7 步全过（到底精确到底/到顶不被拉走/过滤态正常）
- 异常条目复制按钮：每条异常卡片头部行加「复制」链接，复制该条全部内容（头部[框架/未捕获]来源·app·os·×N / summary / desc 多行 / Widget含文件:行 / 栈帔逐行 raw）；缺省字段自动跳行；复用剪贴板写入+execCommand 兑底；浏览器注入 mock 验证 7 步全过（两种 channel、缺字段、剪贴板逐行比对、mock 清理零残留）
- IDE 跳转打开 VSCode 而非 Qoder 修复：qodercn CLI 实为 dispatcher，`-g` 直传被路由给独立安装的 qoderclicn（未装 exit 127）而非 IDE，优先级检测失败静默落到 code。修复：GUI _guiLaunchIde 与 daemon _launchIde 对 qodercn/qoder-cn 加 `ide` 子命令（qodercn ide -g file:line → IDE 原生 launcher）；验证：curl /api/openide 后 Qoder 前台窗口 = 目标文件、VSCode 未被打开

## P16 AI 驱动测试报告（结束后自动生成）`[x]`
- 运行结束（done/异常终止/手动停止）在 _aiLoop finally 自动生成自包含 HTML 测试报告（截图 base64 内嵌），落盘 `~/.xb_ume_ide/scenarios/reports/ai-<runId>.html`
- 报告内容：结论（✅ done / ❌ 异常终止+原因 / ⚠️ 手动停止）、遇到的问题清单（步骤 fail 期望 vs 实际+失败截图、AI 重试轮、轮级错误；无问题显「无」）、耗时与步数统计（pass/fail）、逐轮明细（AI 思考+步骤表+截图内嵌）
- 新增 `GET /api/ai/report`：优先回运行结束落盘的文件（GUI 重启后仍可下当前 runId 那份），无文件时从内存现场生成兑底，均无则 404；响应带 attachment 头
- 前端：结束后显示「⬇ 导出报告」按钮（window.open 下载）；aiStart 时隐藏
- 验证（example macOS 会话）：deepseek-flash 真实调用 3 轮 5 步全 pass → 报告结论 ✅、3 张截图内嵌、端点 200+attachment；故障 mock（前 2 次无效回复）retries=2 → 报告问题清单含「轮 1：AI 调用重试 2 次」、逐轮明细重试标注；analyze 无 issue

## P17 MCP 双向集成（xb_ume 作为 MCP Server）`[x]`
- 出口：`bin/mcp.dart` 独立进程，手写 JSON-RPC 2.0（零第三方依赖；声明 2025-06-18、兼容回显 2024-11-05 / 2025-03-26），stdio 换行分隔与 Streamable HTTP（POST /mcp 单条 JSON、GET 405、Host + token 双校验、只绑 127.0.0.1）双传输
- 工具默认 20 个（core 14 + diagnose 3 + run-safe 3）；act / device-write 有副作用需 `--tool-groups` 显式开启；inspect / ai / ide 为空预留组（帮助与文档如实标注，不假装支持）
- 设备后端可插拔：自研 adb / hdc / simctl / idevice + 可选 mobile-mcp 适配器（npx @mobilenext/mobile-mcp --listen 46150，不进 auto）；8 项能力显式声明，不支持返回 unsupported；DeviceRegistry 单实例同时供 MCP 工具与场景服务
- 场景 DSL 扩展：waitFor / retry / if / observe / scrollUntil + install / uninstall / launchApp / pressKey / nativeTap / assertNoCrash；条件 6 种（visible / text / route / request / expr，省略 kind 自动推断）
- AI 元素候选：截图外附 ref / 类型 / 文本 / 逻辑像素 bounds / 源码 文件:行，新增 tapRef 步骤（参数名 expectType，规避 JSON 重复键覆盖）；会话发现抽取为公共模块供 daemon 与 MCP 共用
- GUI：守护进程 Tab 新增「MCP 服务」卡片（探测 46140..46149 的 HTTP initialize + tools/list 计工具数，或按进程命令行识别 stdio；token 仅在点「复制 MCP 配置」时按需下发），首屏立即探测、复制的配置文本不被 15s 轮询覆盖
- 验证：MCP HTTP 实测 serverVersion 0.4.0 / tools=20 / 无 token 401；浏览器实测卡片「运行中 · HTTP 46140 · 20 个工具」、复制出带 X-XBUME-Token 的 HTTP 配置、跨 18s 轮询不丢、点刷新恢复摘要、console 零报错；`flutter test` 224 项全过、`dart analyze bin lib` 无 issue

## P18 AI 调试零学习入口（一条命令 / 一个 Tab）`[x]`
- 背景：P17 的「三前提」（会话必须 MCP 自己拉起、eval 要开开关、客户端要配 MCP）对新人学习成本太高；目标是「拿到就能用」，把前置知识全部内化到一次动作
- 一个动作 = 确保带 `xbume_eval` 的 MCP 在跑 → 按项目目录 + 设备生成可粘给 AI 的指令 → 写剪贴板；已在跑就复用，在跑但缺 eval 且 pid 是自己的才重启，外部服务拒绝不动，且不改 `config.json` 的 `mcpAllowEval`
- 不代劳拉起 app：指令让 AI 调 `xbume_app_launch(via: flutter-run, cwd: <项目>)`，flutter run 的 stdin 必须留在 MCP 进程里，`xbume_hot_reload` 才有句柄；拉起前先 `xbume_sessions`，已有会话先问用户（手机上重装包会顶掉 IDE 的会话）
- 不顶掉 IDE 会话：`xbume_app_launch` 启动前扫本机 flutter run（ps + lsof cwd），**同设备 + 同目录**已有时默认拒绝并给出 pid 与两条出路（复用现有会话无热重载 / `force: true`），路径符号链接归一；实测对外部会话命中、同设备异目录与异设备同目录均不误拦，MCP 端到端验证拒绝消息与放行路径
- 交付两面：命令 `dart run xb_ume:ai`（`--dir` / `--device` / `--print-only` / `--json`，设备留空按「唯一手机 > macOS > 首个可用」推荐）；GUI 「AI 调试」Tab（`#ai` 深链，项目目录/设备持久化到 `aiProjectDir` / `aiDevice`）
- 代码：`bin/src/ai/prompt.dart`（两边共用：目录校验、设备推荐、指令与客户端配置文本）、`bin/src/mcp/host.dart`（McpHost：46140-46149 握手探测 / 拉起 / 按 pid 停；包内脚本用 `Isolate.resolvePackageUri` 定位）、`bin/ai.dart`；GUI 侧 `startMcp({forceEval})` + `/api/ai/config|setup` + 页签切换重构为 `showTab()` 支持 `#<tab>` 深链
- 交互细节：项目目录输入框自适应剩余宽度（长路径不再被截断）、指令预览区随窗口高度并可内部滚动、剪贴板被浏览器策略拦下时提示改用「复制 AI 指令」而不是静默失败；项目目录与设备改为「选」——目录用带候选的下拉输入框（候选 = 当前调试会话按库路径反推的项目根 + `aiRecentDirs` 最近 8 个；`_VmSession` 解析 `getIsolate` 时顺手存 `projectRoot`），设备用 `<select>`（自动 / 手机 / macOS 桌面，默认跟随右上角设备），两者与右上角「VM 会话」的区别写进页面说明
- 目录可选普通文件夹：新增 `GET /api/fs/dirs`（后台列一层子目录，不读文件内容：隐藏目录跳过、Flutter 项目排前、符号链接归一、单层限 500 项）+ 前端目录选择器（路径框可粘绝对路径回车跳转、上级/主目录、会话与最近目录做快捷按钮、底部提示当前目录有没有 `pubspec.yaml`、Esc / 点遮罩关闭）——浏览器自己的 `webkitdirectory` 只给相对名，拿不到能当 `cwd` 的绝对路径，只能由后台代劳；实测 home → `dev/git/github` 9 项（`xb_logs_util` 带 Flutter 标记且排首）→ 进 `xb_scaffold/xb_ume` 提示含 `pubspec.yaml` → 选定回填 `#ai-dir`，根目录时「上级」禁用，Esc 关闭生效
- 验证（macOS example）：`--print-only` → 29 工具 / eval 未开；`dart run xb_ume:ai` 自动把 46140 从 29/无 eval 重启为 30/有 eval，`pbpaste` 校验剪贴板即指令；GUI `/api/ai/setup` 返回 ok + 30 工具；真实浏览器点「一键开启」→ `已就绪 · 30 个工具 · eval 已开 · 指令已复制`、`#ai-prompt` 1121 字符含项目路径与 `cwd`、console 0 错误；`flutter test` 252 → 258 项

## 进度记录
- 2026-10-14 P1 完成（探针 852KB PNG → /api/screenshot + 截图 Tab，自动刷新 + 下载；真机 1260×2720 PNG）
- 2026-10-14 P2 完成（reassemble/_collectAllGarbage 探针定论 → /api/runtime/op + 守护 Tab 按钮，真机双 op 通过；热重启不可行已文档说明）
- 2026-10-14 P3 完成（双通道：Extension 流 Flutter.Error + 输出流未捕获块解析；修 widget 正则与无位置帧两 bug；新增 GUI 优雅退出防 DDS 死锁；真机双通道+跳转 验证通过）
- 2026-10-14 P3 补验（macOS 桌面会话）：修订阅响应检查引入的 socket.first 重复监听 bug（令三通道全部失败重试死循环）；浏览器 UI 验证通过（列表/徽标/红浮层真实推送链路）；streamListen 响应改在 _onData 检查（被拒显式报 stderr）；mac 会话双通道实时捕获 + f_jlink 会话真实异常持续入库自证
- 2026-10-14 P4 完成（路由操作：/api/routeop pop/remove/pushNamed；前端操作列 + pushNamed 输入框；macOS 会话真实验证 + 浏览器 UI 验证；发现并记录 macOS 后台帧冻结致出栈延迟现象）
- 2026-10-14 P5 完成（泄漏检测：/api/leakcheck GC 后树上/堆上双计数；前端四类结论含红色疑似泄漏；泛型类名剥离修复；macOS 命令行阴/阳对照 + 浏览器 UI 两轮全过；排障中发现后台 flutter run SIGTTIN 停进程组问题并用管道 stdin 根治）
- 2026-10-14 P6 完成（状态面板：/api/status/cn 自动候选=树上 CN State + 泛型实参提取（如 XBWidgetState<ChoosePageVM>）+ getObject super 链校验（≤12 跳，拦截 GetX 非 CN 实参）；监听者数读 _listeners 非 Null 槽/老版 _count；字段摘要滤 CN 内部机制字段；类名点链接跳「实例」Tab；浏览器 UI 五步验证全过；排障沉淀：VM service 无 getClass 方法，查类对象用 getObject）
- 2026-10-14 P7 完成（编辑重放：/api/network/replay 支持 POST JSON 覆盖 url/headers/body，GUI 端 HttpClient 直发 + 显式 content-length（防 chunked）；前端编辑表单（预填原值、重放后保留编辑内容）+ 重放响应自动与原响应 JSON 逐字段 diff（●改/+增/−删 + 计数）；Network 记录 Map/List 改用 eval 内手写 JSON 序列化（xb_ume core 库上下文无 dart:convert、XBUme 符号只在 core 可见，手写 q/js 最小序列化）；验证环境：example DebugProfile.entitlements 补 network.client + 本地 echo 服务替代不可达外网；浏览器 UI 全过）
- 2026-10-15 P8 完成（/api/sandbox/upload：POST JSON {name,b64}，base64 解码后 512KB/块 eval 写入（首块 FileMode.write 覆盖、后续 append，防 eval 表达式过大）；eval 库上下文用 xb_ume persistence io 实现库——唯一同时 import dart:io 与 dart:convert 的现成库；文件名防护禁分隔符与 ..、深层目录自动创建、上限 12MB；前端文件树每行「上传」（目录行→该目录、文件行→所在目录）+ 隐藏 file input + FileReader.readAsDataURL；验证：小文本/1.2MB 二进制 3 块上传 MD5 一致、覆盖截断、目录自动建、穿越拦截、浏览器 UI 8 步全过）
- 2026-10-15 P9 完成（自研 eval 方案替代 inspector 树：实测 getRootWidgetSummaryTree(438 节点)与 renderViewElement 起 Element 树(1169)不同构不同源，DFS 对齐不可行；/api/wtree 一次 eval（binding.dart 上下文）显式栈拉全 Element 树，每节点输出 d/t/key/bounds（r is RenderBox 后 localToGlobal(paintBounds)——RenderObject 无 localToGlobal 需 cast）+ dpr/物理尺寸；前端左树右图：点击树节点红框高亮、点截图选最小面积包含节点反查并滚动定位（纯前端零额外调用）、过滤显祖先链、折叠懒渲染；验证：1169 节点 1162 有 bounds、Scaffold 全屏高亮、中心反查命中 KeyedSubtree、过滤/折叠全过）
- 2026-10-15 P9 修复（f_jlink 真机树深度 369 暴露：缩进=深度×14px 使深层行宽 3294px，点截图选中深层节点后树滚到全深层区域，文字全在横向视口外，视觉上树区「空白」。修复：缩进封顶 min(d,24)×14+4、d>24 行首显父链尾灰色前缀（如 Container/Padding/Align）、scrollIntoView block 改 center。f_jlink 4684 节点/dpr3.25 环境回归通过：行宽 572px、选中行居视口中部、可见行 padding 全部 ≤340px）
- 2026-10-15 P9 增强（点截图选业务组件 + 宽高/间距标注：用户反馈点截图选中的是最内层 SDK 节点（弹框文字选到 Image），要 locator 式只选非 SDK 组件并显示宽高与周围组件距离。新增 /api/wtree/pick：一次 eval（库上下文=xb_ume_widget_spacing_calculator.dart，直接复用 app 内已编译的 XBUmeWidgetSpacingCalculator，零复刻）——命中点收集→面积升序→逐 hit 向上（visitAncestorElements，该 Flutter 版本 Element 无 public parent getter）找 creationLocation 非 Flutter SDK 的最近组件（locator 同款判定 dart:/package:flutter//packages/flutter/，优先非 pub-cache）→调计算器得四向间距（searchRoot=xb_ume_app_root key 排除 ume 覆盖层）；信息条显类型/宽高/源文件:行:列/↑↓←→距离，截图叠加黄色参照框+距离标注；树中 SDK/系统包装类淡化（启发式名单，仅视觉）。GUI 页面响应加 Cache-Control: no-store 治浏览器旧缓存。example 验证：pick 命中 xb_button.dart:121 业务组件+间距正确、边界（MISS/400/会话断开）全过、浏览器 UI 全过（1169 行中 1004 淡化、参照框/标注/点树清参照正常））
- 2026-10-15 P9 收尾（用户反馈 bug 后续再调 → Widget树 Tab display:none 隐藏，代码保留；提交 0c2b7c7/b90cdd5）
- 2026-10-15 P10 完成（自动化路径：执行引擎 _autoExecStep 十类步骤全 eval 零侵入——tap=GestureBinding.handlePointerEvent down/up（phys 坐标除 dpr）、input=TextInput._instance._currentConnection._client.updateEditingValue（库上下文必须 services/text_input.dart，_instance 是库内私有；widgets/text_input.dart 路径不存在）、swipe=down+8 段 move+up、back=路由快照+popUntil 语义、navigate=_routeNamed、assertVisible=全树 BFS 类型匹配+RenderBox 有尺寸、assertRoute=栈顶名、assertInstance=GC 后 getClassList+getInstances 计数、eval=任意表达式 expect contains；/api/auto list/get/delete/save/run(409 冲突保护+inline steps)/status/stop/artifact（文件名正则防穿越）8 个端点；失败步截图落盘 ~/.xb_ume_ide/scenarios/artifacts/，默认失败即停、continue=1 跑全量、stop 请求当前步结束后 skip 余下；前端自动化 Tab（场景下拉/保存/删除/格式化/运行/停止/失败继续/报告表 pass 绿 fail 红 skip 灰+截图链接）+ 截图 Tab「录制点击」checkbox（点截图按显示比例换算物理像素追加 tap，导入录制生成步骤 JSON）。验证：example 场景全生命周期（save→list→get→run→status→报告→artifact→stop→delete）+ 冒烟 7 步全 pass（tap 驱动真实导航进 XBDialogInputDemo+back+assertInstance）+ input 端到端（tap 输入框→input 注入→eval 读 EditableTextState controller.text="hello p10"）+ assertRoute/swipe + 409/防穿越/浏览器 UI 全过；踩坑记录：场景 JSON 禁重复键（assertVisible 曾写 type 导致键覆盖变未知步骤）、save 落盘纯数组 list 计数需兼容、VM eval valueAsString 会静默截断长串、macOS app 后台帧冻结会致 push 动画中断+新页面元素不上树+absorbPointer 残留吞后续 tap（跑场景前把 app 置前台，真机不受影响））
- 2026-10-16 P11 完成（AI 驱动：_aiLoop 截图→AI→执行→反馈循环，_aiCall 显式 Content-Length（dart HttpClient 默认 chunked，python http.server 等本地服务读不到 body）；_aiParseReply 平衡大括号容错解析；AI 坐标自动 phys:true；失败步骤截图转 b64 附下一轮消息自适应；artifact 正则扩展 ai-<ts>-rN/stepN；/api/ai config/run/status/stop/save 5 端点 + 409/未配置/防穿越；前端 AI 区块（目标输入/执行/停止/设置/存为场景）+ 轮卡片报告（截图缩略图/AI 思考/步骤表）+ 切 Tab 自动恢复报告。验证：本地 mock OpenAI 服务端到端（轮0 tap+wait+assertVisible 全 pass 真实导航、轮1 done）、存为场景 3 步拍平落盘 + 普通回放全 pass 等价、错误路径（未配置/空步骤/防穿越）、浏览器 UI 全过 console 0 错误）

- 2026-10-16 P11 修复（f_jlink 21 轮实录两 bug：① tap/swipe 注入 PointerDownEvent 未指定 pointer（默认 0），down 派发中业务异常致 up 未发 → _hitTests 残留 pointer 0 → 后续所有 tap 撞 !_hitTests.containsKey 断言永久卡死（AI 误判为坐标问题连点 5 轮）。修复：唯一 pointer id（微秒时间戳）+ down try/catch 补发 up 并返回 ERR 摘要（不 rethrow，避免 FlutterError 上报时 inspector 序列化 eval 栈帧二次炸 stack_frame.dart 断言污染错误）；swipe 全程同一 pointer + down 失败即中止。② AI 不知道截图分辨率产生坐标系幻觉（前 17 轮把底部导航 y 估在 2255 实际应≈2600+，轮 18 幻觉出 924×2000 点出屏外）。修复：_aiLoop 解析 PNG IHDR 宽高写进消息（截图分辨率：W×H），system prompt 明确坐标系与「底部导航贴截图底边」。example 回归：p10-smoke 7 步全 pass + swipe×2/assertRoute 全 pass）
- 2026-10-16 P12 完成（四项结构化上下文 + 三断言端到端全通：mock 扩展剧本轮0 tap+wait+assertVisible 真实导航、轮1 assertText 命中 show + assertLog 命中 FlutterNapi(hilog) + assertRequest 反断言 pass、轮2 done；ctx 关闭 log/net 后消息无对应行且轮1 仅剩 assertText；Offstage 修复（back 回首页后 notContains "show" 误报——保活下层页面文本被收集）；p10-smoke 7 步回归全 pass；诊断插曲：合成 tap 失效排查（viewId/resampling/帧冻结逐一排除）最终定性 app 未真实前台——osascript activate 不可靠，CGEvent 真实点击强制前台化后合成 tap 恢复，GUI 日志 buffer 无 HTTP 端点故新增 _guiLogBuffer 全局引用供顶层断言函数读取）
- 2026-10-16 P13 完成（AI 调用失败/回复不可解析/无有效步骤自动重试：轮内重试 3  次退避 2s/4s/6s，重试耗尽才停，轮卡片显重试次数；f_jlink 用户实录反馈「AI 调用失败或回复为 null 时直接停下」改进；example 双模式故障 mock 验证：HTTP 500 retries=1 恢复、非 JSON 回复 retries=2 恢复，均走完剧本至 done 不中断）
- 2026-10-16 P14 完成（swipe 滚动失效修复：合成 PointerMoveEvent 默认 delta=Offset.zero 致 DragGestureRecognizer 永远达不到 touchSlop、drag 永不启动；timeStamp 全零影响 fling 速度计算。move 事件补显式 delta + 递增微秒 timeStamp；example swipe-probe 前后截图字节级对比验证滚动生效；f_jlink 真机 AI 驱动滚动待用户回归）
- 2026-10-17 P15 完成（日志 Tab：多关键字 OR 过滤 + 增量渲染 + 贴底跟随。根因是旧实现每条日志到达全量重建 DOM + 无条件拉底致选区丢失；新实现条件签名比对增量追加、无命中不动 DOM。浏览器 agent 验证四项全过：OR 过滤/选中保持/上翻不拉底/清空恢复）
- 2026-10-17 P16 完成（AI 驱动测试报告：结束后自动落盘自包含 HTML（结论/问题清单/统计/逐轮明细+截图内嵌），/api/ai/report 下载端点 + 前端「⬇ 导出报告」按钮；deepseek-flash 真实调用成功路径 + 故障 mock 重试路径双验证全过）
- 2026-10-19 会话选择保持 v2（掉选自愈 + localStorage 指纹持久化：回退不清指纹、每轮按 fp 自动找回，页面刷新/重开浏览器自动选回；node 状态机单测 10 断言 + 浏览器端到端全过）
- 2026-10-19 会话选择排障日志：`~/.xb_ume_ide/logs/vm_sel.log`（2MB 轮转）记录 daemon 会话增减（source|fp 集合差异，仅变化时记）与前端上报（页面加载恢复指纹/用户选择/指纹找回/缺失计数/回退/前后台切换/daemon 断连恢复，POST /api/clientlog）；验证：GUI 重启后页面自动恢复指纹 + 会话变化日志 + 上报链路落盘全通
- 2026-10-26 P17 完成（MCP 双向集成：MCP Server 双传输 + 默认 20 工具 + 设备后端可插拔 + 场景 DSL 复合/设备步骤 + AI 元素候选与 tapRef + GUI MCP 服务卡片；MCP_GUIDE.md 新建，README/GUI_GUIDE/CHANGELOG（转降序）与版本 0.4.0 同步；验证 HTTP tools=20/401 兜底 + 浏览器卡片与复制配置全过 + flutter test 224 项）
- 2026-10-26 P17 修复（时间轴清空：用户反馈「点清空要弹确认、确认后也没清空」。根因是时间轴为五类事件聚合视图，而清空只清路由/网络/监听，日志与异常原样留着；改为点即清、不再二次确认，日志/异常用视图下限 `tlFloor` 隐藏（各 Tab 原始数据不删），并处理服务端清空失败/订阅重放不回流、会话掉线不解除下限、非空会话之间切换才重置三个边界；新增 `test/gui_timeline_clear_test.dart`；浏览器实测：无弹框、1500→0 行、内存 5146 条旧日志被过滤不复活、切会话历史正常显示、console 无报错）
- 2026-10-26 P17 修复（守护进程起不来：`ide.dart` 改为依赖 `src/session/discovery.dart` 后，`--install` 仍只复制单文件，部署副本从 ~/.xb_ume_ide 解析不到 import 直接编译失败，GUI 只报「重启后未检测到 daemon」。修复：安装按 `_kIdeRuntimeDeps` 清单连同依赖复制并保持相对路径，GUI 重启前先检查部署副本相对依赖并点名缺失，新增 `test/ide_deploy_deps_test.dart` 锁住「相对 import ⇄ 清单」一致；实测 `--install` 后 daemon 监听 46128、launchctl 状态 0、GUI /api/daemon running=true 且已发现 1 个会话）
- 2026-10-27 P17 增强（MCP 一键启停：用户问「为什么不自动启动 MCP 服务」。卡片加「启动/停止」按钮与「随工具箱启动」开关（默认关，`config.json` 的 `mcpAutoStart`）；后端 `/api/mcp/start|stop|auto`：detached 拉起部署副本 `mcp.dart --http <46140-46149 首个空闲> --tool-groups all --log-file logs/mcp.log`，pid 记 `mcp.pid`，SIGTERM 停止并等端口释放，重复启动幂等、非自己拉起的服务拒绝停，拉起前 `ensureMcpToken()` 免首次 401，`/api/mcp` 回包补 `autoStart`/`launchable`/`managedPid`；`--install` 改为递归部署整棵 `bin/src` + `mcp.dart` + `version.txt`，`mcp.dart` 支持 `--log-file`、部署副本版本回退版本号文件；实测：启动 0.6s 返回 25 工具/0.4.0、重复启动幂等、停止 0.26s 端口释放、重启 GUI 后自动拉起、浏览器卡片四态/持久化/复制配置全过且 console 0 错误）
- 2026-10-27 P17 增强（MCP 自调试闭环：用户问「AI 能不能自己调试、要怎么做」后补齐两块短板。① `xbume_hot_reload`：`LaunchHandle` 增加 `process` 与广播输出流（`recent` 保 400 行），向 `flutter run` 的 stdin 写 `r`/`R`（非 TTY 可用：`resident_runner.dart` 的 `setupTerminal` 无条件调用，`processTerminalInput` 会 trim），按 flutter 完成行判定（`Reloaded N (of M) libraries` / `Restarted application`）、进程早退不干等、超时回最近 20 行；`pidForPort` 反查会话、热重启后 `resetIsolateCache()`。② `xbume_eval`（`--allow-eval` 显式开启）：`rawRpc('evaluate')`，库支持完整 uri 或子串匹配（业务库优先），Error 分支区分编译/运行时，`_Smi` 等内部类名归一化，4000 字符上限 + maxChars 截断。默认工具 23→24（core 17→18）、全开 28→29、加 eval 30；GUI 卡片新增「允许 eval」勾选（`mcpAllowEval` + `/api/mcp/eval`，重启生效）。修掉 hot reload 正则漏配（无改动时只报 `Reloaded 0 libraries`，没有 `of N`，曾白等 120s）。macOS example 实测：eval `1+1`/`XBUme.controller.logs.length`/运行时异常/编译错误四类正确，写日志后 `xbume_console` 可读；改标题 reload 229ms 截图确认生效、改回 234ms（`git status` 干净）、restart 360ms 后 eval 仍可用；定向测试 55 项全过。
- 2026-10-27 P18 补（项目目录可选）：用户反馈「这个地方，我希望可以选择本地目录」。新增 `/api/fs/dirs` 与目录选择器浮层（只列目录、不读文件、Flutter 项目排前带标记、隐藏目录跳过、符号链接归一、上层路径直接输入）；无头 Chrome 实测 5 步全过：浮层从当前值打开（9 行 + 1 个会话候选）、`dev/git/github` 列表与提示、`xb_scaffold/xb_ume` 提示含 pubspec、选定回填 `#ai-dir` 并关闭、根目录「上级」禁用 + Esc 关闭；`flutter test` 262 项全过，`dart analyze bin` 无 issue
- 2026-10-27 P18 完成（AI 调试零学习入口：用户反馈「三前提太复杂，希望一条命令或 GUI 一个 Tab 一键搞定」。`dart run xb_ume:ai` + GUI「AI 调试」Tab 共用 `bin/src/ai/prompt.dart`（目录校验 / 设备推荐 / 指令与客户端配置），命令侧新增 `bin/src/mcp/host.dart`（46140-46149 握手探测、拉起、按 pid 停）；一个动作完成「带 `--allow-eval` 的 MCP + 可粘给 AI 的指令 + 剪贴板」，不改 `mcpAllowEval`、不代劳拉起 app（stdin 句柄须留在 MCP 进程）；GUI 页签切换重构为 `showTab()` 并支持 `#<tab>` 深链。实测：`--print-only` 29 工具/eval 未开；`dart run xb_ume:ai` 把 46140 从 29/无 eval 重启为 30/有 eval 且剪贴板校验通过；浏览器点「一键开启」→ 已就绪 · 30 个工具 · eval 已开 · 指令已复制（console 0 错误，剪贴板被拦时降级提示）；`flutter test` 258 项）
- 2026-10-27 跨平台补齐（用户要求「检查整个 xb_ume，确保所有功能都支持 mac 和 Windows」）：按能力点（安装自启 / GUI 启停 / 会话扫描 / 设备 / flutter run / IDE 跳转 / 剪贴板 / MCP / 进程统计）逐项审查，修掉 Windows 上真会崩的四处——`flutter.bat` / `npx.cmd` 改 `runInShell`（只在 .bat/.cmd 时走 cmd）、`kill -0` 换成 `tasklist`、停自建 `flutter run` 用 PowerShell 求整棵子进程树（原来 Windows 返回空表，app 会留在后台）、性能页补 `GetProcessTimes` / `GetProcessMemoryInfo` 整进程统计（任务管理器口径）；另补 Windows 桌面设备项与 `-d windows` 推荐、netstat 通配绑定解析、chmod 跳过、`idevice` 提示与工具描述去 macOS 化；新增 `parseDescendantPids` 与 `windowsCpuNsFromFileTime` 纯函数测试；`flutter test` 266 项全过，analyze 仅两条既有 warning；Windows 仍有的降级项（防顶掉体检不生效、无崩溃自拉起）写入 MCP_GUIDE 已知缺口
- 2026-10-27 P19 完成（异常 → 源码定位闭环：用户问「基于现有 xb_ume 补一个『布局溢出 → 源码定位』的闭环工具」后同意实施）。GUI 异常 Tab 早有 widget/widgetFile/widgetLine 与跳转，真正缺口在 MCP：`xbume_exceptions` 只回 9 个字段。新增 `lib/src/core/xb_ume_error_source.dart` 纯字符串解析器（Flutter 真实输出是两行「The relevant error-causing widget was:」+「  Row」+「  Row:file:///...:21:20」，先在 hint 后 3 行找、再全文兜底，避开 framework 的 `flex.dart` 帧，`Uri.toFilePath` 还原 `%20`）；`XBUmeExceptionItem` 补四字段并同步 `copyWith`/`toJson`/`fromJson`，`XBUmeBinding` 从 `informationCollector` 采、`addException` 透传；`exceptionsExpr` 9 段 → 13 段且用 `e.toJson()` 取值（旧 app 无 getter 不会 NoSuchMethod，只回 9 段时 MCP 自动降级）；daemon 侧 `_readSourceSnippet` 读源码 ±2 行（>512KB 跳过）。验证：example 临时入口造真实 `RenderFlex overflowed by 400 pixels`（200 宽里放两个 300 宽），`flutter run` 日志与 MCP 返回的 `Row @ .../tmp_overflow_probe.dart:21:20` 完全一致，snippet 带 `>` 标记行；JSON-RPC 实调 `xbume_exceptions` 拿到 widget 与 source{file,line,column,snippet}；`dart analyze bin lib test` 仅 2 条既有 warning，`flutter test` 276 项全过；临时进程与文件已清理
- 2026-10-27 P20 完成（调试期保持屏幕常亮：用户问「是否有办法让手机保持常亮，鸿蒙这里只支持 10 分钟亮屏」后要求集成）。三种方案经交叉核实：鸿蒙 `hdc shell power-shell timeout -o 2147483647` 覆盖 PowerManagerService 的运行时熄屏值（≈24.8 天，`-r` 恢复；不 root、不写设置，手机或 powmgr 重启后失效），`settings put system screen_off_timeout` 在鸿蒙 shell 不存在，`power-shell setmode 602` 只是性能模式不可靠；Android `svc power stayon true` 同时置 AC/USB/Wireless 位（仅插电生效、拔线自动恢复，刻意不改 `screen_off_timeout`）；iOS 无等价命令。实现三层：`DeviceCapability.keepAwake` + `HdcBridge`（`hdcKeepAwakeArgs` 顶层纯函数；`power-shell` 对未知子命令仍回 0，故按输出里的 error / fail / not found 判失败）+ `AdbBridge`；`xbume_keep_awake`（`act` 组，`deviceId` + `on` 默认 true，iOS 回 unsupported）；GUI 页头设备选择器旁「常亮」勾选框 + `POST /api/keepawake`（后端 `_keepAwake` 集合随 `devices` 广播下发、poll 按在线设备剪枝、snapshot 全量、GUI 重启归零但命令幂等）。踩坑：ide_gui 整包 import 设备后端会与本地同名 `parseAdbDevices`/`parseHdcTargets` 冲突，改用 `show adbKeepAwakeArgs` / `show hdcKeepAwakeArgs`。验证：`dart analyze bin lib test` 仅 2 条既有 warning，定向 22 项全过，全量 `flutter test` 280 项全过（gui_security 一项首轮 `flutter_tester` WebSocket 握手环境性失败，单独重跑 15 项全过）；按约定未在用户真机上执行。
- 2026-10-28 P21 完成（GUI「调试」Tab：用户要求「像 IDE 的调试 Tab，用 xbume_app_launch 起，命中断点后能步进 / 热重载 / 热重启，类似 VSCode 调试 Flutter 的浮动工具栏」；拆四步：复用底座 → GUI 后端 → GUI 前端 → 文档）。① 复用底座：`bin/src/device/live_store.dart` 把 pid/设备/归一化 cwd/target/wsUri/logPath/FIFO/owner 落到 `$XB_UME_HOME/launch/live/<pid>.json`，flutter run 的 stdin 换成命名管道（`sh -c 'exec 3<>"$1"; shift; exec "$@" <&3'`，exec 不换 pid），同设备+同目录+同 target 已有会话直接复用（`reused:true`，不重装包），GUI/MCP 重启后按 pid 或端口重新认领，Windows 无 mkfifo 降级同进程 stdin；`xbume_app_launch` 回 `reused`、`xbume_sessions` 标 `launcher`，AI 指令改为「有自建会话先复用」。② 断点核心：`bin/src/debug/debug_client.dart` 手写 JSON-RPC，断点增删启停、条件断点客户端判定（VM 无 condition 参数，命中后 evaluateInFrame → false 自动 resume → conditionMissed 事件）、帧求值、栈与一层变量、四种 resume；热重启会为旧 isolate 逐个发 BreakpointRemoved 清空登记清单，改为重启前 `snapshotBreakpoints()`、重启后 `reapplyBreakpoints(from:)`。③ GUI：`/api/debug/op` + `bin/src/debug/debug_hub.dart`（start/adopt/attach/detach/pause/resume/step/breakpoint*/stack/eval/hot/stop，状态与日志增量经 WS 推），前端 `#debug` 页 + 底部浮动条 + 断点表 + 栈/变量/求值 + 输出跟随（250ms 轮询 logPath、120ms 批量，复用/接入先预读尾部 200 行），设备默认按 UA 取本机桌面。验证：`flutter test -j 1` 346 项全过（新增 gui_debug_tab 6 项 + debug_client 快照用例），`dart analyze bin test` 仅 2 条既有 warning；macOS example 实测启动→断点→热重载 2.2s→暂停 32 帧/2 变量→继续→按精确 PID 停止（3 个子进程一并回收、live 清单归零、无残留）。
- 2026-10-28 P21 补（断点落盘与自动恢复：VM 在客户端断开时删掉该客户端建的断点，GUI 重启 / 断开重接后断点表必然为空，每轮都要重敲）。新增 `bin/src/debug/breakpoint_store.dart`（`SavedBreakpoint` + `BreakpointStore`）：按「项目根 → 清单」落 `$XB_UME_HOME/debug/breakpoints.json`，项目内文件存相对路径（整个项目搬走仍可用）、项目外存绝对路径，写盘临时文件 + rename、坏文件当空表；`debug_hub` 在 add / remove / toggle 三处同步（`_syncSavedBreakpoint`，删除先取快照再删、启停用 `copyWith(enabled:)`），`_bind` 末尾 `_restoreBreakpoints()` 按 line + 路径后缀去重后重下，条件与停用状态一并带回，失败只计数不删记录，摘要拼进 `_message`（「已恢复 N 个」「M 个失败，代码可能已改」）；`op=saved` / `op=forgetSaved` 未连会话也可用（没 dir 时 saved 回空表、forgetSaved 明确报缺目录）。前端断点卡片加「已记住」清单（`文件:行` + 条件 + 「停用」标记）与「忘记」，`#dbg-dir` 变化、加/删/启停断点后自动刷新。踩坑：`BreakpointStore.absolutePathOf` 拼路径少了分隔符（`/proj` + `lib/main.dart` → `/projlib/main.dart`），单测发现后按「根已带分隔符就不补」修。验证：`flutter test -j 1` 359 项全过（新增 `debug_breakpoint_store_test.dart` 11 项 + debug_hub 2 项），`dart analyze` 仅 2 条既有 warning；macOS example 实测加断点→落盘（相对路径 + VM 解析后的 line 88 / column 7）→停用/启用双向同步（UI 出现「停用」标记）→断开（会话断点归 0、清单仍在）→接入「已恢复 1 个记住的断点」→条件断点 + 停用状态原样恢复→「忘记」清空文件且不影响会话内断点→按精确 PID 停止，无残留 flutter run。
- 2026-10-28 P21 补 2（一键下断点：异常栈帧 / 网络发起位置旁直接下断点）。后端新增 `op=rememberBreakpoint`（不建 VM 断点，只按项目根写落盘清单；路径绝对→相对）；前端新增 `dbgQuickBp(file, line, fromWs)`：已连同一会话→`addBreakpoint` 立即生效并提示，未连→写「已记住」清单、下次 start/attach 自动重下；wsUri 端口不一致（位置来自别的会话）→不默默下错会话，`dbgPrefillBp` 把 `文件:行` 填到调试页并切 Tab（目录空时用候选最长前缀回填）；异常 Tab 栈帧/相关 Widget、网络 Tab 发起位置三处行尾「跳转」旁加「断点」链接（按 id+idx 反查，免把路径拼进 HTML 转义）。验证：`flutter test -j 1` 全量通过（新增 gui_debug_tab 结构守卫 + debug_hub rememberBreakpoint 用例）；macOS example 实测：走 watch-eval（`lib=package:example/main.dart`）打开 ErrorTestPage → 点「2. 同步异常」产生真实 app 帧（error_test_page.dart:52）→ 点「断点」→ bps 多一条并落盘（toast「已下断点 error_test_page.dart:52」）→ 断开 + 忘记（cleared=2）→ 再点「断点」→ 只记住（saved 1、toast「已记住…」）→ 接入 → 「已恢复 1 个记住的断点」且 bp 在 line 52；最后忘掉测试断点、按精确 PID 停止、清理临时截图。踩坑：macOS 窗口被浏览器遮住时 `_flutter.screenshot` 会返回旧帧（截图字节完全相同），需先 `osascript set frontmost` 再截图；窗口隐藏时合成 swipe 也看不出效果。
- 2026-10-28 P21 补 3（列断点与日志断点：断点表只能看到当前会话的断点、命中就总是暂停，核对高频日志时反复「命中→继续」）。日志断点复用条件断点的客户端判定链路：`DebugBreakpoint` / `SavedBreakpoint` 加 `logMessage`，`addBreakpoint` 登记到 `_logMessages`（remove / resetIsolate / reapply / BreakpointRemoved / 热重启快照全链路同步），`PauseBreakpoint` 先判条件、false 发 `conditionMissed`；有日志表达式时收集本帧表达式、`_evalLogs` 拼 `[logpoint] 文件:行  expr => 值`，`resume()` 成功后发 `logpointHit`（不发 pause）；`_evalLogExpr` 先按 Dart 表达式求值、失败再包单引号字符串字面量重试（`page=$runtimeType` 这类裸模板，转义 `\\` / `'` / 换行）；求值失败只写原因仍继续。`savedAll` 新 op：`BreakpointStore.loadAll()` + 顶层 `savedAllDirs(dirs, current)`（当前项目有断点才置顶，没断点不占空分组），按项目根分组返回，前端「全部项目」按钮分组渲染（每组条数 + `✕`，`dbgForgetDirAt(i)` 按索引引用避免路径引号转义），`dbgLoadSaved` 先退出总览模式。踩坑：真实 VM 的编译错误是 `ErrorRef`（`type == '@Error'`），原来只认 `'Error'`，`describeInstanceRef` 丢 message、`evaluateInFrame` 也不报错，导致裸模板插值的二次重试永远不触发（实测输出 `page=$runtimeType => @Error`）；三处同改并补 `@Error` 单测。验证：`dart analyze bin test` 仅 2 条既有 warning，定向 77 项全过；macOS example 实测：日志断点 `error_test_page.dart:52` + `"sync error clicked"` → 点「2. 同步异常」输出 `[logpoint] error_test_page.dart:52  "sync error clicked" => sync error clicked`、`paused:false`；换裸模板 `page=$runtimeType` → 修 `@Error` 后输出 `page=ErrorTestPage`；GUI 重启 + 断开重接均「已恢复 1 个记住的断点」且带 `logMessage`（恢复后再点仍命中）；「全部项目」显示 `example（当前）1 个` + `log page=$runtimeType`，点 `✕` 后回「所有项目都还没有记住的断点」；最后移除断点、按精确 PID 停 app（80703 + 3 个子进程）。
- 2026-10-28 P21 补 4（断点就地编辑：改日志表达式要「删了重加」，而删除还会把落盘清单一起删掉）。`DebugClient.updateBreakpoint(id, {condition, logMessage})`：不动 VM 断点（不重下发，id / 启停状态不变），只同步 `_conditions` / `_logMessages` / `_breakpoints` / `_owned`，空白即清空；`debug_hub` 新增 `op=updateBreakpoint`（缺 id / 未连会话回可读错误），改完同位置覆盖落盘（`store.add` 天然按位置覆盖）。前端断点行加 `✎`：`dbgEditBp` 回填 `文件:行` + 条件 + 日志并把位置置 `readOnly`，「加断点」按钮变「保存修改」、旁边显示「取消」（`dbg-bp-add` / `dbg-bp-cancel`）；`dbgAddBp` 在 `dbgEditBpId` 非空时走 update 分支；`dbgRenderBps` 发现编辑中的 id 已不在清单（被删 / 换会话）自动 `dbgCancelBpEdit`。验证：`dart analyze bin test` 仅 2 条既有 warning，定向 67 项全过，GUI JS 抽取后 `node --check` 通过；macOS example 实测：加 `error_test_page.dart:52`（无条无日志）→ 点 `✎`（回填绝对路径、位置只读、按钮变「保存修改」）→ 填 `page=$runtimeType` 保存 → 断点 id 仍 `breakpoints/1`、表内出现 `log`、落盘同步；点击输出 `[logpoint] error_test_page.dart:52  page=$runtimeType => page=ErrorTestPage`；再编辑加 `false` 条件 → 点击只留「条件未命中，已自动继续：false」不打印；再清空条件与日志 → 表内徽标消失、仍同 id；最后删断点 / forgetSaved / 按精确 PID 停 app 9894（3 个子进程），落盘清空。踩坑：watch-eval 的 `uri` 必须是 `ws://`（传 `http://` 报 `Unsupported URL scheme 'http'`）；MCP 换了新 app 进程后要 `xbume_use_session` 重新选一次，否则 `find_widget` 一直回「未找到匹配」。
