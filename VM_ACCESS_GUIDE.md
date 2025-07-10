# XBWidget VM访问指南

## 概述

现在你可以在XBWidget或其子类中随时随地直接使用vm来获取generateVM生成的XBVM子类实例。

## 实现原理

基于现有的Provider机制，XBWidget已经通过`ChangeNotifierProvider<T>.value`将vm实例注入到widget树中。我们通过以下方式提供便捷的vm访问：

1. **XBWidget便捷方法**：在XBWidget中添加`vmOf`和`vmWatchOf`方法
2. **BuildContext扩展**：为BuildContext添加扩展方法，支持在任何地方访问vm
3. **XBWidgetState便捷属性**：为State添加`vmInstance`和`vmWatch`属性

## 使用方式

### 1. 在XBWidget中使用vmOf方法

```dart
class MyWidget extends XBPage<MyWidgetVM> {
  @override
  Widget buildPage(MyWidgetVM vm, BuildContext context) {
    // 方式1：使用传入的vm参数（原有方式）
    return Column(
      children: [
        Text("计数器: ${vm.counter}"),
        
        // 方式2：使用XBWidget的vmOf方法
        _buildCustomWidget(context),
      ],
    );
  }
  
  Widget _buildCustomWidget(BuildContext context) {
    final vm = vmOf(context); // 获取vm实例
    return ElevatedButton(
      onPressed: vm.increment,
      child: Text("增加: ${vm.counter}"),
    );
  }
}
```

### 2. 使用BuildContext扩展方法

```dart
Widget _buildAnyWidget(BuildContext context) {
  // 使用context扩展方法获取vm
  final vm = context.vmOf<MyWidgetVM>();
  
  return Text("计数器: ${vm.counter}");
}
```

### 3. 在子Widget中使用

```dart
class ChildWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // 在任何子widget中都可以获取父级的vm
    final vm = context.vmOf<MyWidgetVM>();
    
    return ElevatedButton(
      onPressed: vm.decrement,
      child: Text("减少: ${vm.counter}"),
    );
  }
}
```

### 4. 在XBWidgetState中使用

```dart
class MyWidgetState extends XBWidgetState<MyWidgetVM> {
  void someMethod() {
    // 方式1：使用vmInstance属性（不监听变化）
    final vm1 = vmInstance;
    
    // 方式2：使用vmWatch属性（监听变化）
    final vm2 = vmWatch;
    
    // 方式3：直接使用vm字段（原有方式）
    final vm3 = vm;
  }
}
```

## 可用方法

### XBWidget类中的方法

- `vmOf(BuildContext context)` - 获取vm实例（不监听变化）
- `vmWatchOf(BuildContext context)` - 获取vm实例（监听变化，会触发rebuild）

### BuildContext扩展方法

- `context.vmOf<T>()` - 获取指定类型的vm实例（不监听变化）
- `context.vmWatch<T>()` - 获取指定类型的vm实例（监听变化）
- `context.vmOfOrNull<T>()` - 安全获取vm实例，不存在时返回null
- `context.vmWatchOrNull<T>()` - 安全获取vm实例（监听变化），不存在时返回null

### XBWidgetState中的方法

- `vmInstance` - 获取当前vm实例（不监听变化）
- `vmWatch` - 获取当前vm实例（监听变化）

## 注意事项

1. **监听vs不监听**：
   - 使用`vmOf`或`vmInstance`不会监听vm变化，性能更好
   - 使用`vmWatch`会监听vm变化，当vm调用notify()时会触发widget重建

2. **类型安全**：
   - 使用context扩展方法时需要指定泛型类型：`context.vmOf<MyWidgetVM>()`
   - XBWidget的方法会自动推断类型

3. **生命周期**：
   - 确保在正确的生命周期内调用这些方法
   - 避免在dispose后访问vm

4. **安全访问**：
   - 使用`vmOfOrNull`和`vmWatchOrNull`可以安全地访问可能不存在的vm
   - 这在某些复杂的widget树结构中很有用

## 完整示例

```dart
class CounterPage extends XBPage<CounterPageVM> {
  const CounterPage({super.key});

  @override
  CounterPageVM generateVM(BuildContext context) {
    return CounterPageVM(context: context);
  }

  @override
  Widget buildPage(CounterPageVM vm, BuildContext context) {
    return Column(
      children: [
        // 原有方式：使用传入的vm参数
        Text("计数器: ${vm.counter}"),
        
        // 新方式1：使用XBWidget的vmOf方法
        _buildIncrementButton(context),
        
        // 新方式2：使用子widget
        CounterDisplay(),
        
        // 新方式3：使用子widget操作
        CounterControls(),
      ],
    );
  }
  
  Widget _buildIncrementButton(BuildContext context) {
    final vm = vmOf(context);
    return ElevatedButton(
      onPressed: vm.increment,
      child: Text("增加"),
    );
  }
}

class CounterDisplay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final vm = context.vmWatch<CounterPageVM>(); // 监听变化
    return Text("当前计数: ${vm.counter}");
  }
}

class CounterControls extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final vm = context.vmOf<CounterPageVM>(); // 不监听变化
    return Row(
      children: [
        ElevatedButton(
          onPressed: vm.increment,
          child: Text("+"),
        ),
        ElevatedButton(
          onPressed: vm.decrement,
          child: Text("-"),
        ),
      ],
    );
  }
}

class CounterPageVM extends XBPageVM<CounterPage> {
  CounterPageVM({required super.context});
  
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
}
```

## 总结

通过这个实现，你现在可以：

1. 在XBWidget的任何方法中通过`vmOf(context)`获取vm实例
2. 在任何子widget中通过`context.vmOf<T>()`获取父级的vm实例
3. 在XBWidgetState中通过`vmInstance`或`vmWatch`获取vm实例
4. 根据是否需要监听变化选择合适的方法
5. 使用安全访问方法避免异常

这个方案完全基于现有的Provider架构，保持了向后兼容性，同时提供了极大的便利性。
