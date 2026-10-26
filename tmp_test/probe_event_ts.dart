// 探针：验证 VM Extension 事件是否带 timestamp 字段、DDS 重放是否保留原值。
// 用法: dart run tmp_test/probe_event_ts.dart <wsUrl>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

int _id = 0;
final Map<String, Completer<Map<String, Object?>>> _pending = {};
final List<Map<String, Object?>> _events = <Map<String, Object?>>[];

void _onMsg(dynamic m) {
  final j = jsonDecode(m as String);
  if (j is! Map) return;
  final id = j['id']?.toString();
  if (id != null && _pending.containsKey(id)) {
    if (j['error'] != null) {
      _pending.remove(id)!.completeError(j['error']);
    } else {
      _pending.remove(id)!.complete(Map<String, Object?>.from(j['result'] as Map));
    }
    return;
  }
  final params = j['params'];
  if (params is Map && params['streamId'] == 'Extension' && params['event'] is Map) {
    _events.add(Map<String, Object?>.from(params['event'] as Map));
  }
}

Future<Map<String, Object?>> _rpc(WebSocket ws, String method, Map<String, Object?> params) {
  final id = 'r${++_id}';
  final c = Completer<Map<String, Object?>>();
  _pending[id] = c;
  ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
  return c.future.timeout(const Duration(seconds: 8));
}

bool _isProbeEvent(Map<String, Object?> e) =>
    e['extensionKind'] == 'xb_ume:openSource' &&
    e['extensionData'] is Map &&
    (e['extensionData'] as Map)['file'].toString().contains('probe_ts');

void _dump(String tag, Map<String, Object?> e) {
  print('$tag 字段: ${e.keys.toList()}');
  final t = e['timestamp'];
  print('$tag timestamp = $t'
      ' (${t is int ? DateTime.fromMicrosecondsSinceEpoch(t) : "无"})');
  print('$tag 当前时间   = ${DateTime.now()}');
  print('$tag 完整事件: ${jsonEncode(e)}');
}

Future<void> main(List<String> args) async {
  final wsUrl = args.first;

  // ---- 阶段 1：连接、注入一条 postEvent（旧格式无 ts），观察事件原始字段 ----
  final ws1 = await WebSocket.connect(wsUrl);
  ws1.listen(_onMsg);
  ws1.add(jsonEncode({
    'jsonrpc': '2.0', 'id': 'sl', 'method': 'streamListen',
    'params': {'streamId': 'Extension'},
  }));
  await Future.delayed(const Duration(milliseconds: 800));
  final vm = await _rpc(ws1, 'getVM', {});
  final iso = (vm['isolates'] as List).cast<Map>().firstWhere(
      (i) => i['isSystemIsolate'] == false && i['name'] == 'main',
      orElse: () => (vm['isolates'] as List).cast<Map>().first,
    );
    final isoId = iso['id'] as String;
  final isor = await _rpc(ws1, 'getIsolate', {'isolateId': isoId});
  final lib = (isor['libraries'] as List).firstWhere(
    (l) => (l as Map)['uri'].toString().contains('xb_ume_ide_jump.dart'),
    orElse: () => throw StateError('xb_ume_ide_jump 库未找到'),
  ) as Map;
  print('== 注入 postEvent（旧格式无 ts）via ${lib['uri']} ==');
  await _rpc(ws1, 'evaluate', {
    'isolateId': isoId,
    'targetId': lib['id'] as String,
    'expression':
        "developer.postEvent('xb_ume:openSource', {'file':'file:///tmp/probe_ts.txt','line':42,'column':0})",
  });
  await Future.delayed(const Duration(milliseconds: 800));
  final ours = _events.where(_isProbeEvent).toList();
  if (ours.isEmpty) {
    print('未收到注入事件；本次收到的 extensionKind: ${_events.map((e) => e['extensionKind']).toSet()}');
  } else {
    _dump('原始接收', ours.first);
  }
  await ws1.close();
  _events.clear();

  // ---- 阶段 2：断开后重连，看重放事件的 timestamp 是否保留原值 ----
  await Future.delayed(const Duration(seconds: 1));
  final ws2 = await WebSocket.connect(wsUrl);
  ws2.listen(_onMsg);
  ws2.add(jsonEncode({
    'jsonrpc': '2.0', 'id': 'sl2', 'method': 'streamListen',
    'params': {'streamId': 'Extension'},
  }));
  await Future.delayed(const Duration(milliseconds: 1500));
  final replay = _events.where(_isProbeEvent).toList();
  if (replay.isEmpty) {
    print('== 重连后未重放 probe_ts 事件 ==');
  } else {
    print('== 重连后重放了 ${replay.length} 条 probe_ts 事件 ==');
    _dump('重放事件', replay.first);
  }
  await ws2.close();
  exit(0);
}
