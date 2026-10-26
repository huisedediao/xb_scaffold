import 'dart:convert';
import 'dart:io';
void main() async {
  final ws = await WebSocket.connect('ws://127.0.0.1:58044/ws');
  ws.listen((m) async {
    if (m is! String) return;
    final d = jsonDecode(m) as Map;
    if (d['id'] == 'a') {
      final isol = d['result'] as Map;
      print('extensions=' + (isol['extensionRPCs'] as List? ?? []).join(','));
      await ws.close();
    }
  });
  ws.add(jsonEncode({'jsonrpc':'2.0','id':'a','method':'getVM'}));
  await Future.delayed(const Duration(seconds: 3));
}
