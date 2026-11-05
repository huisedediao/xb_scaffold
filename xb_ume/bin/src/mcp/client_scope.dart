// MCP 传输连接作用域。
//
// 同一台机器上可能有好几个 AI 会话连到**同一个** MCP 进程（最典型：同一个助手开两个
// 窗口，都连 HTTP 46140）。进程里只有一个 SessionRegistry，如果「当前会话」是进程级
// 单值，A 选完 B 又选，A 后面不带 sessionId 的调用就会静默打到 B 的会话上。
//
// 所以按「客户端连接」各记各的当前会话：
//   - HTTP：Mcp-Session-Id（initialize 时服务端下发，之后每次请求由客户端带回）
//   - stdio：一个进程一个连接，固定用 `stdio`
//   - 客户端不回传 Mcp-Session-Id 时用空串（退回旧的「共享当前会话」行为，不会更糟）
//
// 用 Zone 把这个标识带进工具 handler，工具代码不用改签名。
library;

import 'dart:async';

/// Zone 里存客户端连接标识的 key。
const Object kMcpClientKey = #xbume.mcpClient;

/// 当前请求属于哪个客户端连接；不在工具调用里时为空串。
String get currentMcpClient => '${Zone.current[kMcpClientKey] ?? ''}';

/// 连接标识的短形式：Mcp-Session-Id 是随机长串，落进租约文件只留末 6 位。
String shortMcpClient(String raw) =>
    raw.length <= 6 ? raw : raw.substring(raw.length - 6);

/// 在 [client] 这个连接的上下文里执行 [body]。
Future<T> runAsMcpClient<T>(String client, Future<T> Function() body) =>
    runZoned<Future<T>>(
      body,
      zoneValues: <Object?, Object?>{kMcpClientKey: client},
    );
