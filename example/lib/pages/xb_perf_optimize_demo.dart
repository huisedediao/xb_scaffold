import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// demo 卡片底色（与框架内部 viewBG 同色值；该 getter 未对外导出）
const Color _demoCardBG = Color(0xFFF1EBEB);

/// 大页面性能优化 demo：XBSelect（字段级订阅）+ createNotifier（高频值绕开 notify）
///
/// 验证方式：在 main 中设置
/// `WidgetsBinding.instance.debugPrintRebuildDirtyWidgets = true;` 后操作页面，
/// 观察 rebuild 日志：
/// 1. 点「未读+1」：只有未读角标重建，列表区域、静态区不重建；
/// 2. 点「刷新列表」：只有列表区域重建，未读角标、静态区不重建；
/// 3. 点「开始倒计时」：每秒只有倒计时文字重建（走 ValueNotifier，
///    完全不触发页面 notify，buildWidget 不会重跑）；
/// 4. 「静态区」select 常量值，任何 notify 都不会让它重建；
/// 5. 「跨 VM 区」XBSelectMulti 同时订阅页面 VM 与子区域 VM，任一变化都重建。
class XBPerfOptimizeDemo extends XBPage<XBPerfOptimizeDemoVM> {
  const XBPerfOptimizeDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBPerfOptimizeDemoVM(context: context);
  }

  @override
  String setTitle(BuildContext context) => '性能优化 demo';

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);
    return ListView(
      padding: EdgeInsets.all(spaces.gapDef),
      children: [
        _sectionTitle('一、XBSelect：按字段订阅，值不变则整块跳过'),
        Row(
          children: [
            // 只依赖 unreadCount：其他字段 notify 时返回缓存的 child，整块跳过
            Expanded(
              child: XBSelect<XBPerfOptimizeDemoVM, int>(
                selector: (vm) => vm.unreadCount,
                builder: (context, count) => Chip(
                  avatar: const Icon(Icons.mark_email_unread, size: 18),
                  label: Text('未读 $count'),
                ),
              ),
            ),
            XBButton(
              onTap: vm.bumpUnread,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Text('未读+1'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(
              child: Text('列表版本：v（只有列表区域订阅它，见下方灰卡）'),
            ),
            XBButton(
              onTap: vm.refreshList,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Text('刷新列表'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        _sectionTitle('二、贵的区域也用 XBSelect 订阅自己的字段'),
        // 只依赖 listVersion：unreadCount 变化时这里不重建
        XBSelect<XBPerfOptimizeDemoVM, int>(
          selector: (vm) => vm.listVersion,
          builder: (context, version) {
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _demoCardBG,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('数据版本 v$version（v 变化时这块才重建）'),
                  const SizedBox(height: 8),
                  ...List.generate(
                    5,
                    (i) =>
                        Text(vm.items[i], style: const TextStyle(fontSize: 13)),
                  ),
                  Text('…… 共 ${vm.items.length} 条（示意，实际场景是长列表）'),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 10),

        _sectionTitle('三、静态区：select 常量，任何 notify 都不重建'),
        XBSelect<XBPerfOptimizeDemoVM, int>(
          selector: (_) => 0,
          builder: (context, _) {
            vm.staticBuildCount++;
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: _demoCardBG,
              child: Text('静态区累计 build 次数：${vm.staticBuildCount}'
                  '（上方按钮点多少次都不会变成 2，因为这块被缓存跳过了）'),
            );
          },
        ),
        const SizedBox(height: 10),

        _sectionTitle('四、createNotifier：高频值绕开 notify'),
        Row(
          children: [
            // 只有这一小块每秒重建，页面 buildWidget 不重跑
            ValueListenableBuilder<int>(
              valueListenable: vm.secondsLeft,
              builder: (context, seconds, _) => Text(
                '剩余 $seconds s',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const Spacer(),
            XBButton(
              onTap: vm.startCountdown,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Text('开始倒计时'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _sectionTitle('五、XBSelectMulti：跨 VM / 多值订阅'),
        // 子区域自带 VM，同时订阅页面 VM 的 unreadCount 和自身 VM 的 label：
        // 任一变化都重建，无关字段 notify 都不重建
        const _CrossVMArea(),
        const SizedBox(height: 10),

        const Text(
          '提示：高频值若走 notify()，每秒都会重跑整个 buildWidget；'
          '走 ValueNotifier 则只有上面那行文字重建。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
    );
  }
}

/// 跨 VM 订阅演示：子区域有自己的 VM，同时订阅页面 VM（XBSelectMulti）
class _CrossVMArea extends XBWidget<_CrossVMAreaVM> {
  const _CrossVMArea();

  @override
  _CrossVMAreaVM generateVM(BuildContext context) =>
      _CrossVMAreaVM(context: context);

  @override
  Widget buildWidget(BuildContext context) {
    final vm = vmOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _demoCardBG,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: XBSelectMulti<({int unread, String label})>(
              selector: (context) => (
                unread: context.select<XBPerfOptimizeDemoVM, int>(
                    (vm) => vm.unreadCount),
                label:
                    context.select<_CrossVMAreaVM, String>((vm) => vm.label),
              ),
              builder: (context, v) =>
                  Text('页面VM未读 ${v.unread} / 本区域 ${v.label}'),
            ),
          ),
          XBButton(
            onTap: () => context
                .vmOf<XBPerfOptimizeDemoVM>()
                .bumpUnread(),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Text('改页面VM'),
            ),
          ),
          XBButton(
            onTap: vm.toggle,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Text('改本区域'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CrossVMAreaVM extends XBVM<_CrossVMArea> {
  _CrossVMAreaVM({required super.context});

  String label = 'A';

  void toggle() {
    label = label == 'A' ? 'B' : 'A';
    notify();
  }
}

class XBPerfOptimizeDemoVM extends XBPageVM<XBPerfOptimizeDemo> {
  XBPerfOptimizeDemoVM({required super.context});

  /// 低频字段：由 XBSelect 按字段订阅
  int unreadCount = 0;
  int listVersion = 0;
  List<String> items = List.generate(5, (i) => '初始数据 $i');

  /// 静态区 build 计数（演示用，仅首帧 +1）
  int staticBuildCount = 0;

  /// 高频值：由 VM 托管生命周期，dispose 时自动销毁
  late final ValueNotifier<int> secondsLeft = createNotifier<int>(10);

  Timer? _timer;

  void bumpUnread() {
    unreadCount++;
    notify();
  }

  void refreshList() {
    listVersion++;
    items = List.generate(5, (i) => '新数据 v$listVersion-$i');
    notify();
  }

  void startCountdown() {
    _timer?.cancel();
    secondsLeft.value = 10;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      secondsLeft.value--;
      if (secondsLeft.value <= 0) {
        _timer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    // createNotifier 创建的 notifier 由 XBVM.dispose 自动销毁，无需手动处理
    super.dispose();
  }
}
