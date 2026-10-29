// MCP 侧的调试会话池：每个 MCP 会话（sessionId）各持一个 DebugHub。
//
// 直接复用 GUI 调试页那套 DebugHub —— 断点增删启停、条件/日志断点、单步、
// 栈与变量、帧内求值、运行输出跟随、断点落盘都在里面，MCP 只需要按需 attach。
// 不与 GUI 共享实例：同一个 VM service 允许多客户端，两边各管自己那份断点
// （VM 的断点归属到设它的客户端），互不干扰。
library;

import '../debug/debug_hub.dart';
import '../device/flutter_run.dart';
import 'protocol.dart';
import 'session_registry.dart';

class DebugSessionPool {
  DebugSessionPool({required this.launcher});

  final FlutterRunLauncher launcher;
  final Map<String, DebugHub> _hubs = <String, DebugHub>{};
  final Map<String, String> _ws = <String, String>{};

  /// 这个会话的 hub（还没 attach 也返回，调用方自己决定什么时候接）。
  DebugHub hub(McpSession s) => _hubs.putIfAbsent(
        s.id,
        () => DebugHub(push: (_) {}, launcher: launcher),
      );

  /// 确保已接入；已经接在同一个 ws 上时不会重建连接（避免把暂停现场丢掉）。
  Future<DebugHub> attach(McpSession s, {String? projectRoot}) async {
    final h = hub(s);
    if (_ws[s.id] == s.wsUrl) return h;
    final r = await h.handle('attach', <String, Object?>{
      'wsUri': s.wsUrl,
      if (projectRoot != null && projectRoot.trim().isNotEmpty)
        'projectRoot': projectRoot,
    });
    if (r['ok'] == false) {
      throw McpToolException(
        '接入调试会话失败：${r['error'] ?? '未知原因'}',
        hint: '先 xbume_sessions 确认会话还在；release 包没有 VM service，接不了',
      );
    }
    _ws[s.id] = s.wsUrl;
    return h;
  }

  bool isAttached(String id) => _ws.containsKey(id);

  Future<void> detach(String id) async {
    final h = _hubs.remove(id);
    _ws.remove(id);
    try {
      await h?.handle('detach', const <String, Object?>{});
    } catch (_) {}
    await h?.dispose();
  }

  Future<void> disposeAll() async {
    for (final h in _hubs.values) {
      try {
        await h.dispose();
      } catch (_) {}
    }
    _hubs.clear();
    _ws.clear();
  }
}
