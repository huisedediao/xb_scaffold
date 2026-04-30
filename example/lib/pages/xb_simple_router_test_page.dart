import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xb_simple_router/xb_simple_router.dart';

class XBSimpleRouterTestPage extends StatefulWidget {
  const XBSimpleRouterTestPage({super.key});

  @override
  State<XBSimpleRouterTestPage> createState() => _XBSimpleRouterTestPageState();
}

class _XBSimpleRouterTestPageState extends State<XBSimpleRouterTestPage> {
  final List<String> _logs = <String>[];
  StreamSubscription<XBStackChangedEvent>? _stackSub;
  int _seed = 1;

  @override
  void initState() {
    super.initState();
    _stackSub = xbSimpleRouteStackStream.listen((event) {
      final action = event.isPush ? 'push' : (event.isPop ? 'pop' : 'unknown');
      final current = event.route.settings.name ?? '${event.route.runtimeType}';
      final previous = event.previousRoute?.settings.name ??
          '${event.previousRoute?.runtimeType ?? "null"}';
      _addLog('stack event: $action, current=$current, previous=$previous');
    });
    _addLog('监听已开启，当前页面可测试 xb_simple_router 的核心能力。');
  }

  @override
  void dispose() {
    _stackSub?.cancel();
    super.dispose();
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[${DateTime.now().toIso8601String()}] $message');
      if (_logs.length > 60) {
        _logs.removeLast();
      }
    });
  }

  void _pushLeaf() {
    final level = _seed++;
    push(_RouterLeafPage(level: level), 1);
    _addLog('push _RouterLeafPage(level: $level)');
  }

  void _replaceLeaf() {
    final level = _seed++;
    replace(_RouterLeafPage(level: level), 1);
    _addLog('replace _RouterLeafPage(level: $level)');
  }

  void _popOne() {
    if (Navigator.of(context).canPop()) {
      pop();
      _addLog('pop()');
    } else {
      _addLog('当前不可 pop');
    }
  }

  void _checkRouteState() {
    _addLog(
      'topIsType(XBSimpleRouterTestPage)=${topIsType(XBSimpleRouterTestPage)}, '
      'topIsType(_RouterLeafPage)=${topIsType(_RouterLeafPage)}, '
      'stackContainType(_RouterLeafPage)=${stackContainType(_RouterLeafPage)}',
    );
  }

  Widget _btn(String title, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ElevatedButton(
        onPressed: onTap,
        child: Text(title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('xb_simple_router 测试页')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '建议测试顺序：push -> replace -> pop -> popToRoot -> 状态检查。',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          _btn('1. push 叶子页', _pushLeaf),
          _btn('2. replace 叶子页', _replaceLeaf),
          _btn('3. pop', _popOne),
          _btn('4. popToRoot', () {
            popToRoot();
            _addLog('popToRoot()');
          }),
          _btn('5. 检查 topIsType/stackContainType', _checkRouteState),
          _btn('6. 清空日志', () {
            setState(_logs.clear);
          }),
          const SizedBox(height: 14),
          const Text('执行日志（最新在上）',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_logs.isEmpty)
            const Text('暂无日志，点击上方按钮开始测试。')
          else
            ..._logs.map(
              (e) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(e),
              ),
            ),
        ],
      ),
    );
  }
}

class _RouterLeafPage extends StatelessWidget {
  final int level;

  const _RouterLeafPage({required this.level});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('RouterLeaf #$level')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => push(_RouterLeafPage(level: level + 1), 1),
          child: const Text('继续 push 下一层'),
        ),
      ),
    );
  }
}
