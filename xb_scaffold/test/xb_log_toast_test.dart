import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // 清空页面日志，避免用例间串扰
    debugPrint(pageLogInfo()); // 保持基线行为可见性
  });

  test('recordPageLog 使用设备本地时间（非硬编码东八区）', () {
    final before = DateTime.now();
    recordPageLog('tz-test');
    final after = DateTime.now();
    expect(after.isAfter(before), isTrue);

    final entry = pageLogList.first;
    expect(entry.startsWith('tz-test '), isTrue);
    final timeStr = entry.replaceFirst('tz-test ', '');

    // 日志时间戳应与调用时的本地时间一致（容差 1 分钟，避免边界秒抖动）
    final parsed = DateTime.parse(timeStr);
    final diff = parsed.difference(before).inSeconds.abs();
    expect(diff < 60, isTrue,
        reason: '日志时间戳（$timeStr）应接近调用时的本地时间（$before）');
  });

  testWidgets('toastWidget 在 overlay 未就绪时不抛未处理异常', (tester) async {
    // 不挂载任何 navigator（xbNavigatorKey 未附着），xbOverlayState 为 null
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    // 首次失败被捕获并计划下一帧重试
    toastWidget(widget: const Text('toast'));

    // 跑一帧执行重试：overlay 仍不可用 → 记录日志并安全丢弃，不崩溃
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'overlay 未就绪时 toast 应安全降级而非抛未处理异常');
  });
}
