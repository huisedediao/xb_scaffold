import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'xb_vm.dart';

// abstract class XBWidget<T extends XBVM> extends StatelessWidget {
//   const XBWidget({super.key});

//   /// 生成vm
//   T generateVM(BuildContext context);

//   @override
//   Widget build(BuildContext context) {
//     return ChangeNotifierProvider(
//       create: (ctx) => generateVM(context),
//       builder: (context, child) {
//         return Consumer<T>(
//           builder: (context, vm, child) {
//             return buildWidget(vm, vm.context);
//           },
//         );
//       },
//     );
//   }

//   /// 构建主体
//   Widget buildWidget(T vm, BuildContext context);
// }

abstract class XBWidget<T extends XBVM> extends StatefulWidget {
  const XBWidget({required super.key});

  /// 生成vm
  T generateVM(BuildContext context);

  /// 构建主体
  Widget buildWidget(T vm, BuildContext context);

  @override
  XBWidgetState createState() => XBWidgetState<T>();
}

class XBWidgetState<T extends XBVM> extends State<XBWidget<T>> {
  /// 在外部使用时，不应该保存vm，避免生命周期问题
  late T vm;

  /// 刷新UI
  rebuild({bool regenerateVM = false}) {
    if (regenerateVM) {
      if (mounted) {
        setState(() {
          vm = widget.generateVM(context);
        });
      }
    } else {
      vm.notify();
    }
  }

  @override
  void initState() {
    super.initState();
    vm = widget.generateVM(context);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<T>.value(
      value: vm,
      child: Consumer<T>(
        builder: (context, vm, child) {
          return widget.buildWidget(vm, context);
        },
      ),
    );
  }
}

// class XBWidgetState<T extends XBVM> extends State<XBWidget<T>> {
//   BuildContext? vmContext;

//   /// 获取vm，必须在buildWidget调用之后使用
//   /// 在外部使用时，不应该保存vm，避免生命周期问题
//   T get vm {
//     assert(vmContext != null, "vmContext is null");
//     return Provider.of<T>(vmContext!, listen: false);
//   }

//   /// 刷新UI
//   rebuildUI() {
//     vm.notify();
//   }

//   @override
//   Widget build(BuildContext context) {
//     return ChangeNotifierProvider(
//       create: (ctx) => widget.generateVM(context),
//       child: Consumer<T>(
//         builder: (context, vm, child) {
//           vmContext = context;
//           return widget.buildWidget(vm, context);
//         },
//       ),
//     );
//   }
// }
