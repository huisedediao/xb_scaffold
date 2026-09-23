# 自动操作路径采集方案（debug 身份映射 + release 语义指纹）

> 状态：设计稿，待评审。归属 xb_analytics_plus（新 autotrack 模块），debug 期源码位置复用 xb_ume locator 的链快照能力；**不依赖 xb_scaffold / provider / getx 等任何具体生态库**，路由观测走 Flutter 标准 NavigatorObserver 扩展点 + 可选适配器。
> 目标：自动记录用户/测试人员的组件级点击路径，debug 期附带源码位置，release 测试包输出语义指纹路径，最终可导出可复现的操作步骤。

## 一、需求边界（先说清楚拿得到什么）

| 维度 | debug | release | 说明 |
|---|---|---|---|
| 页面路径 | ✅ | ✅ | RouteObserver 纯运行时 |
| 组件类型链 | ✅ | ✅ | Element 父子链 + runtimeType |
| 组件文本/标识 | ✅ | ✅ | Text.data、按钮 label |
| 源码位置 file:line:col | ✅ | ❌ | `--track-widget-creation` 编译期注入，release 剥离 |
| VM Service 通道 | ✅ | ❌ | release 无 VM service，postEvent no-op |

**设计原则**：不追求 release 精确反查源码行号（测试包与 debug 包构建版本一变就失效，且自动注入 key 有侵入风险）。定位为：

- debug：语义指纹 + 源码位置（locator 现成能力），可直接产出 IDE 跳转/bug 工单；
- release：语义指纹路径（页面 + 类型链 + 文本），足以回答"测试人员点过哪里、按什么顺序"。

## 二、总体架构

```
┌────────────────────────── App 内（不限定路由/状态管理方案）────────────┐
│                                                                        │
│  MaterialApp / CupertinoApp / GetMaterialApp / go_router               │
│      └─ navigatorObservers / observers ──► XBRouteObserver（自带）     │
│  XBRootWidget / 根包装 ── XBClickObserver（根 Listener + hitTest）      │
│        │                                        ▲                      │
│        ▼                              XBPageTracker（汇聚页面事件）    │
│  XBChainFingerprinter（类型链+文本+深度）                               │
│        │          (debug: + XBUmeWidgetLocatorResolver 源码)           │
│        ▼                                                               │
│  XBTrackManager（现有管道） ──► Sinks                                  │
│      ├── ConsoleSink（现有）                                           │
│      ├── LocalStoreSink（现有，release 批量上传数据源）                │
│      └── UmeDaemonSink（新增，debug 走 postEvent 实时到开发机）        │
└──────────────────────────────────────────────────────────────────────┘
          │ release                          │ debug
          ▼                                  ▼
   HTTP 批量上传 → 服务端           daemon → IDE 跳转 / Markdown 工单
```

### 生态兼容性说明（为什么 provider/getx 不是问题）

| 采集维度 | 与状态管理/路由方案的关系 |
|---|---|
| 点击拦截 | 无关：根 Listener + hitTest 走纯 Widget 树，任何 App 都成立 |
| 页面序列 | 走 Flutter 标准 `NavigatorObserver` 扩展点：裸 Navigator、GetMaterialApp（同样接收 navigatorObservers 列表）、go_router（构造参数 `observers`）、auto_route（AutoRouteObserver 适配）均可挂载；observer 列表可并存，与用户已挂的其他 observer 无冲突 |
| 状态管理（provider/getx/bloc） | 完全无关：方案不读任何状态容器，仅消费 Widget 树与路由回调 |

## 三、模块设计

### 3.1 点击拦截：XBClickObserver（新增）

- 形态：一个 `XBAutoTrackScope` Widget 包在应用根节点（或由 XBRootWidget 集成），内部是根层 `Listener`；
- 监听 `onPointerUp`：
  1. 记录 down→up 位移，超过阈值（如 12 逻辑像素）判定为滑动，丢弃；
  2. `RendererBinding.instance.hitTest(...)` 取命中 RenderObject（Flutter 3.29+ 用 `hitTestInView`，需按 SDK 版本适配）；
  3. 从 RenderObject 向上找最近 Element（`RenderObjectElement`）；
  4. 抛给指纹器（微任务异步执行，不阻塞手势热路径）；
- Listener 的 pointer 事件不参与手势竞技场，子组件消费手势不影响收到回调——拦截是完整且无侵入的。

### 3.2 组件指纹：XBChainFingerprinter（新增）

从点击 Element 向上遍历（限深 30，防超长链），产出指纹结构：

```dart
class XBAutoTrackFingerprint {
  final String routeName;        // 当前路由名（见 3.3）
  final List<String> typeChain;  // ['HomePage','ItemCard','XBButton'] 截断到路由容器
  final String? text;            // 链上首个有效 Text.data / 按钮 label
  final int elementHash;         // Element identityHashCode（仅会话内去重用）
  final int depth;               // 命中深度
  // debug-only（经 locator resolver 补全）：
  final String? file; final int? line; final int? column;
  final String? resolveStrategy; // 复用 locator 的策略标识
}
```

- 类型链截断到路由容器之下，避免每次都带 Material/Navigator 等框架噪声（复用 xb_ume 的框架/三方判定逻辑 `xb_ume_locator_source_matcher` 的归属思路，但不依赖源码位置——release 下仅按类型黑名单截断）；
- 过滤 xb_ume 自身覆盖层（气泡/面板/浮动提示）的点击：按 runtimeType 黑名单排除，避免"调试工具自身操作"污染路径；
- **脱敏**：文本可配置只记前 N 字符/正则过滤（手机号、卡号），配置在 XBTrackConfig。

### 3.3 页面序列：XBPageTracker（新增）

- 自带 `XBRouteObserver extends NavigatorObserver`（包内置，零外部依赖），监听 didPush/didPop/didReplace/didRemove；
- **接入方式（按路由方案）**：
  - 裸 Navigator / provider / bloc / getx（GetMaterialApp）：`navigatorObservers: [XBRouteTracker()]`，标准参数，全部支持；
  - go_router：`GoRouter(observers: [XBRouteTracker()])`；
  - auto_route：适配 `AutoRouteObserver`（P3 可选适配器）；
  - 自定义路由（不基于 Navigator）：提供 `XBPageTracker.reportEnter/reportExit` 手动上报接口兜底；
- 产出页面事件（route name + settings.arguments 摘要 + 时间戳），点击事件记录时携带当前 routeName；
- route name 不可得时（极简 App 未命名路由）降级为 route 类型 + 首个业务 Widget 类型，保证路径仍可读；
- 页面序列与点击序列同一时间轴，回放时按页面分组。

### 3.4 debug 身份映射：接 locator（关键增量）

- debug 模式下，指纹器拿到 Element 后调用 `XBUmeWidgetLocatorResolver.resolve()`（现成接口，返回 resolvedWidgetType/resolveStrategy/chain），从 resolved 节点取 file/line/column；
- componentId = `hash(file:line:column)`，随事件上报。同一构建版本内稳定，可作为聚合主键；
- release 下此步骤跳过（resolver 依赖 creation location，不可用），指纹退化为纯语义；
- **明确不做**：自动 key 注入（与业务 key 冲突、侵入组件树）。可选增强放 P4：xb_scaffold 自家组件（XBButton/XBCell 等）增加显式 `trackId` 参数，由开发者命名，release 也稳定——比自动注入可控。

### 3.5 管道与消费：复用 XBTrackManager

现有 `XBTrackManager` + `XBTrackSink.onEvents` 管道直接复用，新增/增强：

| 组件 | 状态 | 说明 |
|---|---|---|
| ConsoleSink | 已有 | 开发期肉眼验证 |
| LocalStoreSink | 已有 | release 落盘，上传数据源 |
| XBHttpExporter/Sink | 新增 | 批量上传（如每 20 条或 30s）、失败重试、可配仅 WiFi |
| UmeDaemonSink | 新增 | debug 下 `developer.postEvent('xb_ume:autoClick', ...)` 走现有 daemon 通道实时到开发机 |
| track_debug_page | 增强 | 现有调试页加"路径时间线"视图：按页面分组展示点击序列 |

导出能力：

- Markdown 复现步骤：`1. [首页] 点击 ItemCard('商品A') → 2. [详情页] 点击 购买按钮 ...`，debug 下每步附 `file:line:col`（可生成 IDE 跳转协议链接，直接复用 ide.dart 的 `--uri` 能力）；
- 与脑暴池 A6（一键 bug 工单）共用此导出。

## 四、数据模型与存储

- 事件类型：`page_enter / page_exit / click`，统一进 XBTrackEvent 流（新增 type 字段值）；
- 会话概念：App 冷启动为 sessionId，路径 = 会话内事件时间序列；
- LocalStoreSink 已有本地持久化，序列化格式沿用其现有 schema，新增字段向后兼容。

## 五、性能与开关

- **默认关闭**：`XBTrackConfig.autoTrackEnabled = false`，显式开启；
- 测试包分发：`--dart-define=XB_AUTO_TRACK=true` 构建期开关，线上用户包不开启（规避隐私合规问题；若未来要采集真实用户，需另行过隐私评审，不在本方案内）；
- 性能预算：点击处理全异步、链遍历限深 30、指纹构造 < 1ms 量级；上传批量合并，弱网可推迟；
- 采样：`autoTrackSampleRate` 配置（默认 1.0，量大可降）。

## 六、分阶段实施

| 阶段 | 内容 | 产出 |
|---|---|---|
| **P1（验证）✅ 已完成** | XBAutoTrackListener + XBChainFingerprinter（类型链+文本+routeName）+ 黑名单/噪声过滤 | 已交付：`lib/src/autotrack/`（5 文件）+ 5 个 widget 测试全绿；example 里点一遍，console 打出指纹序列 |
| **P2（核心）✅ 已完成** | XBRouteTracker（标准 NavigatorObserver + 手动兜底）+ 源码位置（官方诊断接口，零依赖）+ 时间线视图 + Markdown 导出 | 测试同学可用：跑完操作直接导出带源码定位的复现步骤 |
| P3（release） | LocalStoreSink 落盘验证 + XBHttpExporter 批量上传 + 脱敏 + dart-define 开关 | release 测试包可采集上传 |
| P4（增强，可选） | UmeDaemonSink 实时通道 + XBButton 等显式 trackId + 会话回放聚合 | 全形态 |

## 七、P1 实施中发现的关键事实（影响后续阶段）

1. **debugCreator 只在 widget update 时赋值**（framework.dart `_debugUpdateRenderObjectOwner`，包在 assert 块内）：
   - 首次 mount 的子树全部无 debugCreator，不能直接信任反查结果；
   - 实现采用「锚点 + 子树 DFS」二段定位：沿 RenderObject 父链找首个带 debugCreator 的锚点，再用 `element.renderObject` + `visitChildElements` 在锚点子树内精确匹配目标 RenderObject 的 owner（`RenderObjectElement`）；
   - release 下 debugCreator 恒为 null，反查整体失败返回 null——**release 降级链仍是 P3 课题**。
2. **框架噪声会耗尽链深**：Material/Semantics/GestureDetector 等壳层动辄 30+ 层，maxDepth=30 时业务类型（TextButton/自定义组件）根本进不了链。内置噪声类型集（布局壳/Material 内部/手势焦点语义壳/应用根层）跳过不收集，`extraNoiseTypes` 供业务追加。
3. **黑名单必须整条事件放弃**：最内层命中黑名单后不能回退到外层 hitTest entry 重建（外层在黑名单组件之外，会绕过过滤）。
4. **路由名**：P1 直接用 `ModalRoute.of(element).settings.name`（无需等 P2 的 NavigatorObserver）；MaterialApp 默认路由名为 `/`。
5. **事件管道是队列+批量**：Manager track() 先入 `_queue`，攒满 `flushBatchSize`（默认 20）或定时才分发 sink——实时性敏感场景（如 P4 UmeDaemonSink）需考虑直发或主动 flush。
6. **源码位置无需跨包依赖**：xb_ume locator 同款机制其实是 Flutter 官方诊断接口——`element.toDiagnosticsNode().toJsonMap(InspectorSerializationDelegate(...))` 读 `creationLocation`（`--track-widget-creation` 编译期注入）。xb_analytics_plus 直接内置同款实现（`_captureCreationLocation`），release 产物无该数据自动降级 null，保持零生态依赖。
7. **测试环境陷阱**：`XBTrackConfig.enableLocalStoreSink` 默认 true——若 Manager 被 close 后 track() 会以默认 config 自举，flush 时 XBLocalStoreSink 走 path_provider IO，在 widget test 中挂死。测试必须「先 close 再 initSinks」，且 close 后不得再让 track 发生在 pumpWidget 之前无 init 的状态。
8. **自定义 sinks 不参与 export**：`exportAsJson/Markdown` 只读内置 memorySink/store；需要导出能力的场景要开 `enableMemorySink`。

## 八、风险与对策

| 风险 | 对策 |
|---|---|
| hitTest API 跨 Flutter 版本差异（hitTestInView vs hitTest） | 采集器内按 `FlutterVersion`/条件导入封装，只暴露一个入口 |
| 动态列表 child index 漂移导致指纹不稳 | 指纹不依赖 child index，用"类型链+文本"，同一列表内用文本区分 |
| 用户路由方案非标准（自研路由、无 navigatorObservers 可挂） | XBPageTracker 提供手动 reportEnter/reportExit 兜底接口；点击指纹中的 routeName 缺失时降级为类型指纹 |
| go_router/auto_route 等声明式路由的页面语义差异（同一 URL 多分支） | P3 提供 per-router 适配器，先覆盖 go_router；适配不了的走手动上报兜底 |
| xb_ume 自身 UI 点击污染 | runtimeType 黑名单过滤 |
| 文本含敏感信息 | 脱敏配置（截断/正则），默认开启手机号/长数字过滤 |
| 事件量级大（高频点击） | 批量上传 + 采样率 + 会话聚合 |
| release 与 debug 版本错位导致 componentId 对不上 | componentId 仅在事件内携带，不承担跨版本反查职责；跨版本分析以语义指纹为准 |
