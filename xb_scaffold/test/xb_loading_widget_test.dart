import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('overlay 不可用时 showLoadingGlobal 有限重试后丢弃，不再调度帧',
      (tester) async {
    // 不 pump MaterialApp：xbOverlayState 不可用，show 任务必然失败
    showLoadingGlobal();
    // 首次失败进入重试等待，应调度帧保证重试可达
    expect(tester.binding.hasScheduledFrame, isTrue,
        reason: '重试等待期应调度帧，否则静态画面下重试永远不执行');

    // 推进足够多的帧：重试 3 次后毒任务被丢弃
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: '超限丢弃后不应继续调度帧（否则每帧无限重试空转）');

    // 后续调用同样安全（每个任务的失败计数独立）
    showLoadingGlobal();
    hideLoadingGlobal();
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
