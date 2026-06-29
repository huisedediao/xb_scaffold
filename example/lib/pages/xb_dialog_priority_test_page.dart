import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBDialogPriorityTestPage extends XBPage<XBDialogPriorityTestPageVM> {
  const XBDialogPriorityTestPage({super.key});

  @override
  generateVM(BuildContext context) {
    return XBDialogPriorityTestPageVM(context: context);
  }

  @override
  Color? backgroundColor(BuildContext context) {
    return Colors.white;
  }

  @override
  Widget buildPage(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(spaces.gapDef),
      children: [
        _sectionTitle("基础测试"),
        _buildBtn("单弹框（priority=0，默认）", () {
          dialog(
              title: "默认弹框",
              msg: "priority=0，关闭后下一个自动展示",
              btnTitles: ["确定"],
              onSelected: (_) {});
        }),
        _buildBtn("单弹框（priority=10）", () {
          dialog(
              title: "高优先级弹框",
              msg: "priority=10",
              btnTitles: ["确定"],
              onSelected: (_) {},
              priority: 10);
        }),
        _sectionTitle("替换测试：高优先级挤掉低优先级（被挤的回队列）"),
        _buildBtn("弹 priority=0，再弹 priority=5；关闭#5后应看到#0", () {
          dialog(
              title: "#1 低优先级",
              msg: "priority=0\n即将被 #2 挤回队列，关闭 #2 后会再次出现",
              btnTitles: ["关闭"],
              onSelected: (_) {});
          Future.delayed(const Duration(milliseconds: 100), () {
            dialog(
                title: "#2 高优先级",
                msg: "priority=5，当前展示中\n关闭后 #1 会重新出现",
                btnTitles: ["关闭"],
                onSelected: (_) {},
                priority: 5);
          });
        }),
        _buildBtn("priority=5 被 priority=10 挤掉，关闭后按序出现", () {
          dialog(
              title: "#1",
              msg: "priority=5\n会被 #2 挤回队列",
              btnTitles: ["关闭"],
              onSelected: (_) {},
              priority: 5);
          Future.delayed(const Duration(milliseconds: 100), () {
            dialog(
                title: "#2",
                msg: "priority=10，当前展示\n关闭后应看到 #1（priority=5）",
                btnTitles: ["关闭"],
                onSelected: (_) {},
                priority: 10);
          });
        }),
        _sectionTitle("同优先级 LIFO 测试"),
        _buildBtn("连续弹 3 个 priority=0（后到先展示）", () {
          dialog(
              title: "#1",
              msg: "最先加入 priority=0",
              btnTitles: ["关闭"],
              onSelected: (_) {});
          Future.delayed(const Duration(milliseconds: 100), () {
            dialog(
                title: "#2",
                msg: "第二个加入 priority=0",
                btnTitles: ["关闭"],
                onSelected: (_) {},
                priority: 0);
          });
          Future.delayed(const Duration(milliseconds: 200), () {
            dialog(
                title: "#3",
                msg: "最后加入 priority=0（应最先展示）",
                btnTitles: ["关闭"],
                onSelected: (_) {},
                priority: 0);
          });
        }),
        _sectionTitle("综合场景（被挤掉的回到队列，不会丢失）"),
        _buildBtn("按序弹 1→2→3→0→0→1→2→3（间隔 100ms）", () {
          final priorities = [1, 2, 3, 0, 0, 1, 2, 3];
          for (int i = 0; i < priorities.length; i++) {
            Future.delayed(Duration(milliseconds: i * 100), () {
              dialog(
                  title: "弹框 #${i + 1}",
                  msg: "priority=${priorities[i]}，加入顺序：第${i + 1}个",
                  btnTitles: ["关闭"],
                  onSelected: (_) {},
                  priority: priorities[i]);
            });
          }
          dialog(
              title: "提示",
              msg: "即将按序发送 8 个弹框，\n"
                  "优先级序列：1 2 3 0 0 1 2 3\n"
                  "被挤掉的会回到队列，不会丢失\n"
                  "期望展示顺序：3₂ → 3₁ → 2₂ → 2₁ → 1₂ → 1₁ → 0₂ → 0₁",
              btnTitles: ["开始"],
              onSelected: (_) {});
        }),
        _sectionTitle("队列测试"),
        _buildBtn("先弹 priority=0，后排队 priority=-1（不替换）", () {
          dialog(
              title: "当前展示",
              msg: "priority=0\n关闭后应该看到 priority=-1 的弹框",
              btnTitles: ["关闭"],
              onSelected: (_) {});
          Future.delayed(const Duration(milliseconds: 100), () {
            dialog(
                title: "队列中的弹框",
                msg: "priority=-1，排队等待中",
                btnTitles: ["关闭"],
                onSelected: (_) {},
                priority: -1);
          });
        }),
        const SizedBox(height: 50),
        Center(
          child: Text(
            "每次测试后请逐个关闭弹框观察顺序",
            style: TextStyle(
                fontSize: fontSizes.s12, color: const Color(0xFF999999)),
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: EdgeInsets.only(top: spaces.gapDef, bottom: spaces.gapLess),
      child: Text(title,
          style: TextStyle(
              fontSize: fontSizes.s16,
              fontWeight: fontWeights.bold,
              color: colors.primary)),
    );
  }

  Widget _buildBtn(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: XBButtonText(
        text: label,
        backgroundColor: colors.randColor,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        onTap: onTap,
      ),
    );
  }
}

class XBDialogPriorityTestPageVM extends XBPageVM<XBDialogPriorityTestPage> {
  XBDialogPriorityTestPageVM({required super.context});
}
