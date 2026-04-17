import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBRouteTestPage extends StatefulWidget {
  const XBRouteTestPage({super.key});

  @override
  State<XBRouteTestPage> createState() => _XBRouteTestPageState();
}

class _XBRouteTestPageState extends State<XBRouteTestPage> {
  final List<String> _logs = <String>[];

  void _addLog(String msg) {
    setState(() {
      _logs.insert(0, msg);
      if (_logs.length > 40) {
        _logs.removeLast();
      }
    });
  }

  Future<void> _buildPopUntilStack() async {
    if (!mounted) return;
    push(const RouteUntilAPage(), 1);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (!mounted) return;
    push(const RouteUntilBPage(), 1);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (!mounted) return;
    push(const RouteUntilCPage(), 1);
    _addLog('已构建栈：RouteUntilAPage -> RouteUntilBPage -> RouteUntilCPage');
  }

  void _checkStackInfo() {
    final String msg =
        'topIsType(RouteUntilAPage)=${topIsType(RouteUntilAPage)}, '
        'topIsType(RouteUntilCPage)=${topIsType(RouteUntilCPage)}, '
        'stackContainType(RouteUntilAPage)=${stackContainType(RouteUntilAPage)}, '
        'stackContainType(RouteUntilBPage)=${stackContainType(RouteUntilBPage)}, '
        'stackContainType(RouteUntilCPage)=${stackContainType(RouteUntilCPage)}'
        'topIsType(XBRouteTestPage)=${topIsType(XBRouteTestPage)}, ';
    _addLog(msg);
  }

  void _checkRouteMapping() {
    const page = RouteUntilAPage();
    final route = MaterialPageRoute<void>(
      settings: RouteSettings(
        name: '${page.runtimeType}',
        arguments: {
          xbCategoryNameKey: xbCategoryName,
          xbHashCodeKey: page.hashCode,
        },
      ),
      builder: (context) => page,
    );
    _addLog(
      'isXBRoute=${isXBRoute(route)}, '
      'routeIsMapWidget=${routeIsMapWidget(route: route, widget: page)}',
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
      appBar: AppBar(title: const Text('XBRoute 功能测试')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '说明：本页面用于手工验证 xb_route.dart 的全部 API。',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          _btn('1. push(RoutePushPage)', () {
            push(const RoutePushPage(), 1);
          }),
          _btn('2. replace(RouteReplacePage)', () {
            replace(const RouteReplacePage(), 1);
          }),
          _btn('3. pop()', () {
            if (xbNavigatorState.canPop()) {
              pop();
            } else {
              _addLog('当前不可 pop');
            }
          }),
          _btn('4. pushAndClearStack(RouteClearStackPage)', () {
            pushAndClearStack(const RouteClearStackPage(), 1);
          }),
          _btn('5. popToRoot()', () {
            popToRoot();
          }),
          _btn('6. 构建 popUntilType 测试栈', () {
            _buildPopUntilStack();
          }),
          _btn('7. popUntilType(RouteUntilAPage)', () {
            popUntilType(RouteUntilAPage);
          }),
          _btn('8. 检查 topIsType/stackContainType', () {
            _checkStackInfo();
          }),
          _btn('9. 检查 isXBRoute/routeIsMapWidget', () {
            _checkRouteMapping();
          }),
          const SizedBox(height: 14),
          const Text(
            '执行日志（最新在上）',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
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

class RoutePushPage extends StatelessWidget {
  const RoutePushPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _RouteSimplePage(title: 'RoutePushPage');
  }
}

class RouteReplacePage extends StatelessWidget {
  const RouteReplacePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _RouteSimplePage(title: 'RouteReplacePage');
  }
}

class RouteClearStackPage extends StatelessWidget {
  const RouteClearStackPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _RouteSimplePage(title: 'RouteClearStackPage');
  }
}

class RouteUntilAPage extends StatelessWidget {
  const RouteUntilAPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _RouteSimplePage(title: 'RouteUntilAPage');
  }
}

class RouteUntilBPage extends StatelessWidget {
  const RouteUntilBPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _RouteSimplePage(title: 'RouteUntilBPage');
  }
}

class RouteUntilCPage extends StatelessWidget {
  const RouteUntilCPage({super.key});

  @override
  Widget build(BuildContext context) {
    return XBButton(
        onTap: () {
          popUntilType(XBRouteTestPage);
        },
        child: Text("test"));
    return const _RouteSimplePage(title: 'RouteUntilCPage');
  }
}

class _RouteSimplePage extends StatelessWidget {
  final String title;
  const _RouteSimplePage({required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(child: Text(title)),
    );
  }
}
