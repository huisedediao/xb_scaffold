import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// VM访问演示页面
class VMAccessDemo extends XBPage<VMAccessDemoVM> {
  const VMAccessDemo({super.key});

  @override
  VMAccessDemoVM generateVM(BuildContext context) {
    return VMAccessDemoVM(context: context);
  }

  @override
  String setTitle(VMAccessDemoVM vm) => "VM访问演示";

  @override
  Widget buildPage(VMAccessDemoVM vm, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 原有方式：使用传入的vm参数
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text("原有方式", style: Theme.of(context).textTheme.titleMedium),
                  Text("计数器: ${vm.counter}"),
                  ElevatedButton(
                    onPressed: vm.increment,
                    child: Text("增加"),
                  ),
                ],
              ),
            ),
          ),

          SizedBox(height: 16),

          // 新方式1：使用XBWidget的vmOf方法
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text("XBWidget.vmOf方式",
                      style: Theme.of(context).textTheme.titleMedium),
                  _buildVmOfExample(context),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 新方式2：使用BuildContext扩展
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text("BuildContext扩展方式",
                      style: Theme.of(context).textTheme.titleMedium),
                  const CounterDisplay(),
                  const SizedBox(height: 8),
                  const CounterControls(),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 新方式3：安全访问
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text("安全访问方式",
                      style: Theme.of(context).textTheme.titleMedium),
                  const SafeVMAccess(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVmOfExample(BuildContext context) {
    final vm = vmOf(context); // 使用XBWidget的vmOf方法
    return Column(
      children: [
        Text("计数器: ${vm.counter}"),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton(
              onPressed: vm.increment,
              child: Text("vmOf +"),
            ),
            ElevatedButton(
              onPressed: vm.decrement,
              child: Text("vmOf -"),
            ),
          ],
        ),
      ],
    );
  }
}

/// 使用BuildContext扩展显示计数器（监听变化）
class CounterDisplay extends StatelessWidget {
  const CounterDisplay({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.vmWatch<VMAccessDemoVM>(); // 监听变化
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color.fromRGBO(33, 150, 243, 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        "监听变化的计数器: ${vm.counter}",
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// 使用BuildContext扩展控制计数器（不监听变化）
class CounterControls extends StatelessWidget {
  const CounterControls({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.vmOf<VMAccessDemoVM>(); // 不监听变化
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        ElevatedButton(
          onPressed: vm.increment,
          child: Text("context.vmOf +"),
        ),
        ElevatedButton(
          onPressed: vm.decrement,
          child: Text("context.vmOf -"),
        ),
        ElevatedButton(
          onPressed: vm.reset,
          child: Text("重置"),
        ),
      ],
    );
  }
}

/// 演示安全访问VM
class SafeVMAccess extends StatelessWidget {
  const SafeVMAccess({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.vmOfOrNull<VMAccessDemoVM>();
    final nonExistentVM = context.vmOfOrNull<XBPageVM>();

    return Column(
      children: [
        Text("VM存在: ${vm != null ? '是' : '否'}"),
        Text("不存在的VM: ${nonExistentVM != null ? '是' : '否'}"),
        if (vm != null)
          ElevatedButton(
            onPressed: vm.increment,
            child: const Text("安全访问 +"),
          ),
      ],
    );
  }
}

/// VM访问演示的ViewModel
class VMAccessDemoVM extends XBPageVM<VMAccessDemo> {
  VMAccessDemoVM({required super.context});

  int _counter = 0;
  int get counter => _counter;

  void increment() {
    _counter++;
    notify();
  }

  void decrement() {
    _counter--;
    notify();
  }

  void reset() {
    _counter = 0;
    notify();
  }
}
