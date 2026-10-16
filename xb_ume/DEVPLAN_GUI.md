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
- 防失控：最多 20 轮、每轮 ≤5 步；失败截图反馈 AI 自适应；请求/解析失败即停
- 结束后「存为场景」拍平各轮已执行步骤 → P10 场景回放（无 AI 依赖）
- UI：自动化 Tab 底部「AI 驱动」区块（目标输入/执行/停止/设置/轮卡片报告）

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
