import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/core/xb_process_stats_platform_io.dart';
import 'package:xb_ume/xb_ume.dart';

void main() {
  group('parseProcStatusThreads', () {
    test('读取 Threads 字段并容忍行首空格', () {
      const text = 'Name:\tflutter_test\n'
          'State:\tS (sleeping)\n'
          '  Threads:\t27\n'
          'VmRSS:\t  102400 kB\n';
      expect(parseProcStatusThreads(text), 27);
    });

    test('缺失或非法值返回 null', () {
      expect(parseProcStatusThreads('Name:\tfoo\n'), isNull);
      expect(parseProcStatusThreads('Threads:\tabc\n'), isNull);
      expect(parseProcStatusThreads('Threads:\t0\n'), isNull);
      expect(parseProcStatusThreads(''), isNull);
    });
  });

  group('parseMemTotalBytes', () {
    test('MemTotal 按 kB 换算成字节', () {
      const text = 'MemTotal:       16252928 kB\n'
          'MemFree:         1234567 kB\n';
      expect(parseMemTotalBytes(text), 16252928 * 1024);
    });

    test('缺失返回 null', () {
      expect(parseMemTotalBytes('MemFree: 1 kB\n'), isNull);
      expect(parseMemTotalBytes(''), isNull);
    });
  });

  test('插件 id / title / icon 固定，供 Tab 与配置开关使用', () {
    final plugin = XBUmeMemoryPlugin();
    expect(plugin.id, 'memory');
    expect(plugin.title, 'Memory');
    expect(plugin.icon, Icons.memory);
  });

  testWidgets('Memory 面板结构与悬浮徽标开关', (tester) async {
    final binding = XBUmeBinding.ensureInitialized(
      config: const XBUmeConfig(enable: true, persistenceEnabled: false),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => XBUmeMemoryPlugin().buildPanel(
              context,
              binding.controller,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('App Memory Monitor (1s refresh)'), findsOneWidget);
    expect(find.text('Floating memory badge'), findsOneWidget);
    // 主数字标签随平台口径变化，这里只断言前缀。
    expect(find.textContaining('Current Memory ('), findsOneWidget);
    expect(find.text('Current RSS'), findsOneWidget);
    expect(find.text('Sample Count'), findsOneWidget);
    expect(find.text('History (last 20 samples)'), findsOneWidget);
    // chips 行（CPU / FPS / Threads / Footprint / Total Mem）。
    expect(find.textContaining('CPU: '), findsOneWidget);
    expect(find.textContaining('Threads: '), findsOneWidget);

    // 开关打开后徽标挂到根 Overlay，面板关闭也不影响刷新。
    expect(XBUmeMemoryPlugin.floatingEnabled.value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(XBUmeMemoryPlugin.floatingEnabled.value, isTrue);
    expect(find.text('Sys Mem'), findsOneWidget);
    expect(find.text('RSS'), findsOneWidget);

    // 关掉后徽标从 Overlay 移除（徽标可能盖住开关，这里直接调关闭入口）。
    XBUmeMemoryPlugin.hideFloatingBadge();
    await tester.pump();
    expect(XBUmeMemoryPlugin.floatingEnabled.value, isFalse);
    expect(find.text('Sys Mem'), findsNothing);

    // 卸载面板，确保 1s 轮询定时器被取消（不留下 pending timer）。
    await tester.pumpWidget(const SizedBox());
    XBUmeMemoryPlugin.hideFloatingBadge();
    // binding 改过 debugPrint / FlutterError.onError，必须还原。
    binding.dispose();
  });
}
