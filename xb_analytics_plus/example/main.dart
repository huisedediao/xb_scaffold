import 'package:flutter/material.dart';
import 'package:xb_analytics_plus/xb_analytics_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initXBTrack(
    XBTrackConfig(
      appVersion: '0.1.0+1',
      enableConsoleSink: true,
      enableMemorySink: true,
      enableLocalStoreSink: true,
      onShareRequested: (content) async {
        debugPrint('Share requested: ${content.length} chars');
      },
      commonParamsProvider: () => {
        'buildType': 'debug',
      },
    ),
  );

  // P1 验收：点击任意位置，console 应打出 auto_click 的语义指纹序列。
  runApp(
    const XBAutoTrackListener(
      config: XBAutoTrackConfig(
        // 过滤调试工具自身 UI 的点击污染（示例）。
        blacklist: <String>['XBUme'],
      ),
      child: MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XB Analytics Plus Demo',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> with WidgetsBindingObserver {
  int _count = 0;
  DateTime? _pageEnterAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageEnterAt = DateTime.now();
    xbTrackPageView('DemoPage');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final enterAt = _pageEnterAt;
    if (enterAt != null) {
      final duration = DateTime.now().difference(enterAt).inMilliseconds;
      xbTrackPageLeave('DemoPage', durationMs: duration);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      xbTrackAppForeground();
    } else if (state == AppLifecycleState.paused) {
      xbTrackAppBackground();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('XB Analytics Plus')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Count: $_count'),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _count += 1;
                });
                xbTrackTap('increment_btn', params: {'count': _count});
              },
              child: const Text('Track Increment'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                xbTrack('custom_event', params: {
                  'feature': 'demo',
                  'password': 'secret_should_be_masked',
                });
              },
              child: const Text('Track Custom Event'),
            ),
            const SizedBox(height: 12),
            // 自定义业务组件：验证类型链能穿透组合组件拿到业务类型名。
            _PathCard(
              title: 'Custom Card Demo',
              onTap: () {
                xbTrack('card_tap', params: {'source': 'auto_track_demo'});
              },
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const XBTrackDebugPage(),
                  ),
                );
              },
              child: const Text('Open Debug Page'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 模拟业务里的组合组件（无独立 RenderObject），
/// 用于验证自动采集的类型链能拿到业务类型名。
class _PathCard extends StatelessWidget {
  const _PathCard({required this.title, this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(title),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
