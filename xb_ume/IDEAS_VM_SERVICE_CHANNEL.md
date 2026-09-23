# xb_ume 功能构想：基于 VM Service 事件通道的扩展功能池

> 背景：xb_ume IDE 跳转功能已验证「App → developer.postEvent → VM Service Extension 流 → 本机 daemon → IDE」这条零侵入通道的可行性。本文档记录基于同一通道可继续开发的功能构想，作为后续迭代的需求池。
> 结论先行：通道是**双向**的——daemon 除了订阅事件（App→主机），还能经同一 WebSocket 调用 App 注册的 service extension（`callServiceExtension('ext.xb_ume.*')`）甚至 `evaluate` 在 App 进程内执行表达式（主机→App）。

## 通道能力边界（设计前提）

- App→主机：`postEvent` 发结构化 JSON，fire-and-forget，载荷宜小（大文件需分块）；
- 主机→App：VM service JSON-RPC `callServiceExtension` / `evaluate`，App 端用 `registerServiceExtension` 注册 handler；
- 仅 debug/profile 模式可用（release 无 VM service，需静默降级）；
- VM 会缓冲无订阅者期间的事件，重连后补发，不丢；
- 多设备多会话并发已由 daemon 支持。

## A. 顺向：App → 开发机（复用现有 daemon，只加事件类型）

| # | 功能 | 说明 | 成本 |
|---|---|---|---|
| A1 | **跨设备剪贴板同步** | 真机上长按任意文本 → 事件带内容 → daemon 写入开发机剪贴板。手机复制、电脑粘贴 | 极低 |
| A2 | **真机文件拉取** | 沙盒内数据库/SharedPreferences/日志文件 → base64 分块经事件流传出 → daemon 落盘开发机。免数据线翻沙盒 | 低 |
| A3 | **崩溃/异常自动定位** | `FlutterError.onError` 的异常 stack（含文件:行:列）发事件 → daemon 唤起 IDE 定位 + 弹 macOS 系统通知，点通知跳转出错行 | 低 |
| A4 | **网络请求 → curl/抓包** | 点 App 内请求记录 → method/url/headers/body → daemon 生成 curl 进剪贴板或唤起 Charles/Proxyman | 低 |
| A5 | **性能事件联动** | 掉帧/卡顿/图片过大时发事件，daemon 聚合弹提示（如"3s 内 12 次 jank，最严重 HomePage build"），点击跳构建函数 | 中 |
| A6 | **一键 bug 工单**（团队向） | 测试同学点一下 → 生成 Markdown（文件:行:列+路由+截图+设备信息）→ 剪贴板/发群 | 中 |

## B. 反向：开发机 → App（需 App 端注册 service extension）

| # | 功能 | 说明 | 成本 |
|---|---|---|---|
| B1 | **远程导航 / 状态注入** | 开发机命令让 App 跳任意路由、切主题/语言、注入 mock 登录态、模拟弱网。测试深链与边界状态免多层点击 | 中 |
| B2 | **开发机键盘打字进 App** | 真机输长文本（手机号/验证码/长文案）→ 开发机输入框 → 反向通道填进焦点 TextField | 中 |
| B3 | **App 内"问 AI"** | 选中 UI 元素 → 位置发 daemon → daemon 调本地 AI 分析组件源码 → 结果经反向通道显示在 App 内提示条 | 中 |
| B4 | **远程热重载** | daemon 经 VM service `reloadSources` 触发热重载，脱离 flutter run 终端操作（真机无线调试场景） | 低 |
| B5 | **远程截屏** | daemon 经 `callServiceExtension` 或渲染层接口取当前帧 → 存开发机（配合 A6 工单） | 中 |

## C. 平台向

| # | 功能 | 说明 | 成本 |
|---|---|---|---|
| C1 | **事件流多播总线** | daemon 收到的事件同时转发给日志平台/CI/埋点校验器，daemon 升级为调试流集线器 | 中 |
| C2 | **多 daemon 协同 / 远程同事** | 事件经局域网转发给其他开发机（结对调试场景） | 高 |

## 推荐实施顺序

1. **A1 剪贴板同步 + A3 崩溃定位通知**：完全复用现有 daemon，各只需一个新事件类型（如 `xb_ume:clipboard`、`xb_ume:crash`），性价比最高；
2. **B4 远程热重载 + B1 远程导航/状态注入**：打通反向通道（App 端注册 `ext.xb_ume.*` handler），真机调试体验质变；
3. **A2 文件拉取 / A4 网络请求**：按实际调试痛点排期。

## 与专利的呼应

- 通道本身已写入《06_基于调试会话自动发现的界面源码跨进程定位方法及系统》及 06b 具体实施方式；"等效变形说明"节预留了扩展事件类型与实现语言的等同空间；
- 后续功能（尤其反向通道 B 类）可作为该专利的追加实施例或新申请素材，建议在实现稳定后回填 06b 文档。
