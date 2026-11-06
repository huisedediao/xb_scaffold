// 代理环境处理。
//
// dart:io 的 HttpClient 默认使用 `findProxyFromEnvironment`，会读取进程环境里
// 的 http_proxy / https_proxy / no_proxy（SDK http_impl.dart 里 `_findProxy`
// 的默认值就是它）。GUI / 守护进程 / MCP 连本机 VM Service、GUI API 都是回环
// 地址；如果这些进程继承了用户为发布等操作 export 的代理，回环连接也会被发给
// 代理并卡住——实测 flutter run 因此等不到 `A Dart VM Service`，GUI 的「启动」
// 一直停在「正在启动」直到超时。
//
// 这里做两层兜底：
//   1. 本进程：回环地址直连（DIRECT），其余地址仍按原环境变量走代理；
//   2. 子进程：在环境里补 no_proxy / NO_PROXY，让 flutter run 等也绕过。
//
// 只用 dart:io，保持 bin/ 无 package: 依赖（单文件部署前提）。

import 'dart:io';

/// 固定跳过的回环地址（写进子进程 no_proxy 的默认值）。
const String kLoopbackHosts = '127.0.0.1,localhost,::1';

/// 进程级：本机回环的 HTTP / WebSocket 连接直连，其余地址行为不变。
///
/// 必须在任何 WebSocket / HttpClient 第一次使用之前调用：`WebSocket.connect`
/// 内部的 HttpClient 是静态单例，首次创建后再改 [HttpOverrides] 不生效。
void bypassProxyForLoopback() {
  HttpOverrides.global = _LoopbackProxyOverrides();
}

/// 当前环境里的 HTTP 代理提示（没有返回 null），用于启动时告知用户。
String? proxyEnvHint() {
  final env = Platform.environment;
  for (final k in const <String>[
    'http_proxy',
    'HTTP_PROXY',
    'https_proxy',
    'HTTPS_PROXY',
  ]) {
    final v = (env[k] ?? '').trim();
    if (v.isNotEmpty) return '$k=$v';
  }
  return null;
}

/// 把回环地址补进 `no_proxy` / `NO_PROXY`：保留已有值、去重，两个键都写入
/// （dart:io 先读小写、再读大写，两个都写才能覆盖不同来源的配置）。
Map<String, String> withLoopbackNoProxy(Map<String, String> env) {
  final parts = <String>[];
  void add(String? raw) {
    if (raw == null) return;
    for (final p in raw.split(',')) {
      final s = p.trim();
      if (s.isEmpty) continue;
      if (!parts.any((x) => x.toLowerCase() == s.toLowerCase())) parts.add(s);
    }
  }

  add(env['no_proxy']);
  add(env['NO_PROXY']);
  add(kLoopbackHosts);
  final merged = parts.join(',');
  env['no_proxy'] = merged;
  env['NO_PROXY'] = merged;
  return env;
}

bool _isLoopback(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
}

class _LoopbackProxyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => _isLoopback(uri.host)
        ? 'DIRECT'
        : HttpClient.findProxyFromEnvironment(uri);
    return client;
  }
}
