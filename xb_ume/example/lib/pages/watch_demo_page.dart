import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xb_ume/xb_ume.dart';

/// Watch 监听的验收页：200ms 自增计数器 + 阶段文案。
///
/// GUI 实例 Tab →「注册表 Store」→ `watch-demo` → 字段 `count` 行点「监听」，
/// 时间轴即可看到持续变化的序列；配合条件（如 `count >= 12`）可验证
/// 「条件命中自动截图」。计数与阶段都通过 ChangeNotifier 通知刷新。
class WatchDemoPage extends StatefulWidget {
  const WatchDemoPage({super.key});

  @override
  State<WatchDemoPage> createState() => _WatchDemoPageState();
}

class _WatchDemoPageState extends State<WatchDemoPage> {
  late final WatchDemoVm _vm;

  @override
  void initState() {
    super.initState();
    _vm = WatchDemoVm();
    // 暴露给 GUI 实例 Tab（重复 id 覆盖，退出后保留最后一次注册的实例）。
    XBUme.registerStore('watch-demo', _vm);
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Watch Demo')),
      body: Center(
        child: AnimatedBuilder(
          animation: _vm,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('计数（200ms 自增）'),
                Text(
                  '${_vm.count}',
                  key: const ValueKey('watch-count'),
                  style: const TextStyle(
                    fontSize: 56,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  _vm.phase,
                  key: const ValueKey('watch-phase'),
                  style: TextStyle(
                    color: _vm.phase == '运行中' ? Colors.green : Colors.orange,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton(
                      onPressed: _vm.toggle,
                      child: Text(_vm.running ? '暂停计数' : '继续计数'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('返回首页'),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 持续变化的业务状态：count 每 200ms +1，phase 按 20 次一档切换。
class WatchDemoVm extends ChangeNotifier {
  WatchDemoVm() {
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) => _tick());
  }

  Timer? _timer;
  int count = 0;
  String phase = '运行中';
  bool running = true;

  void _tick() {
    if (!running) return;
    count++;
    phase = count % 20 < 10 ? '运行中' : '等待中';
    notifyListeners();
  }

  void toggle() {
    running = !running;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
