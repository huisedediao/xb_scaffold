// 注入类操作的统一入口。
//
// 背景（实测踩坑）：VM `evaluate` 会在安全点插入到应用当前调用栈中间执行。
// 若请求到达时应用正处于 build/layout/paint 阶段，注入指针或路由变更就会
// 从布局内部改写 widget 树，撞上 `Build scheduled during frame.`；框架的
// 错误上报又会因为栈里带 `Eval.<anonymous closure>` 帧而二次崩溃，异常逃出
// `Navigator._flushHistoryUpdates`，把路由事务卡在过渡态（之后 push 不生效、
// pop 报 LAST_ROUTE、页面停在动画起点）。
//
// 因此所有会改动界面的求值都走 [evalInject]：表达式开头带 `busyGuard`，
// 命中不安全帧相位时返回 BUSY，这里等到下一帧再重试。
library;

import 'vm_client.dart';

/// 注入求值：遇到 [busyGuard] 的 BUSY 自动重试，直到相位安全或次数耗尽。
///
/// 返回表达式的真实结果；耗尽重试仍为 BUSY 时原样返回 'BUSY'。
/// 单次重试间隔取 16ms（约一帧），20 次约为 320ms，覆盖常见过渡动画。
Future<String> evalInject(
  VmClient vm,
  String lib,
  String expr, {
  int tries = 20,
  Duration gap = const Duration(milliseconds: 16),
}) async {
  var last = 'BUSY';
  for (var i = 0; i < tries; i++) {
    last = await vm.evalStringOn(lib, expr);
    if (last != 'BUSY') return last;
    await Future<void>.delayed(gap);
  }
  return last;
}

/// BUSY 的用户可读说明（供工具层拼错误提示）。
const String busyHint = '应用正在绘制帧（build/layout/paint），注入被推迟后仍未成功，请重试';
