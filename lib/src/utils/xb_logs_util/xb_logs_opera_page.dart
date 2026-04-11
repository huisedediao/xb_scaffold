import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBLogsOperaPage extends XBPage<XBLogsOperaPageVM> {
  const XBLogsOperaPage({super.key});

  @override
  generateVM(BuildContext context) {
    return XBLogsOperaPageVM(context: context);
  }

  @override
  String setTitle(XBLogsOperaPageVM vm) {
    return "日志";
  }

  @override
  List<Widget>? actions(XBLogsOperaPageVM vm) {
    return [
      XBButton(
          onTap: () async {
            final logPaths = vm.logPaths;
            if (logPaths.isEmpty) {
              toast("请先选中要分享的日志");
              return;
            }
            final zipPath = await XBLogsUtil.zipAndShareSelectedLogs(logPaths);
            if (zipPath == null) {
              toast("分享失败，请稍后重试");
            }
          },
          coverTransparentWhileOpacity: true,
          child: Padding(
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 8, bottom: 8),
            child: const Text("分享选中日志"),
          ))
    ];
  }

  @override
  Widget buildPage(XBLogsOperaPageVM vm, BuildContext context) {
    return Column(
      children: [
        Container(
          height: 55,
          padding: EdgeInsets.symmetric(horizontal: spaces.gapDef),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text("按天"),
                selected: !vm.byMonth,
                onSelected: (selected) {
                  if (selected) {
                    vm.switchFilterMode(false);
                  }
                },
              ),
              SizedBox(width: spaces.gapDef),
              ChoiceChip(
                label: const Text("按月"),
                selected: vm.byMonth,
                onSelected: (selected) {
                  if (selected) {
                    vm.switchFilterMode(true);
                  }
                },
              ),
              SizedBox(width: spaces.gapDef),
              Expanded(
                child: XBButton(
                  onTap: () {
                    vm.pickDate();
                  },
                  child: Row(
                    children: [
                      Text(vm.filterLabel),
                      Text(
                        vm.filterValue,
                        style: const TextStyle(color: Colors.blue),
                      )
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
            child: vm.logs.isEmpty
                ? Container(
                    alignment: Alignment.center,
                    child: const Text("暂无数据"),
                  )
                : ListView.separated(
                    itemCount: vm.logs.length,
                    itemBuilder: (context, index) {
                      XBLogFileInfo logFileInfo = vm.logs[index];
                      return Padding(
                        padding: EdgeInsets.only(
                            bottom: index == vm.logs.length - 1
                                ? (spaces.gapLess + safeAreaBottom)
                                : 0,
                            top: index == 0 ? spaces.gapLess : 0),
                        child: GestureDetector(
                          onLongPress: () {
                            vm.open(index);
                          },
                          child: XBCellTitleSelect(
                            padding: EdgeInsets.only(
                                left: spaces.gapDef, right: spaces.gapDef),
                            contentHeight: 50,
                            title: logFileInfo.name,
                            isSelected: vm.isSelected(index),
                            onTap: () {
                              vm.onTapIndex(index);
                            },
                          ),
                        ),
                      );
                    },
                    separatorBuilder: (context, index) {
                      return xbLine();
                    }))
      ],
    );
  }
}

class XBLogsOperaPageVM extends XBPageVM<XBLogsOperaPage> {
  XBLogsOperaPageVM({required super.context}) {
    _query();
  }

  bool byMonth = false;
  List<XBLogFileInfo> logs = [];

  _query() async {
    selectedIndex.clear();
    if (byMonth) {
      final groupedLogs = await XBLogsUtil.getLogsByMonth(monthStr);
      logs = groupedLogs.values.expand((element) => element).toList()
        ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    } else {
      logs = await XBLogsUtil.getLogsByDate(dateTimeStr);
    }
    notify();
  }

  String get dateTimeStr =>
      XBTimeUtil.dateTime2Str(dateTime: dateTime, format: XBTimeUtil.formatYMD);
  String get monthStr =>
      XBTimeUtil.dateTime2Str(dateTime: dateTime, format: XBTimeUtil.formatYM);
  String get filterLabel => byMonth ? "月份：" : "日期：";
  String get filterValue => byMonth ? monthStr : dateTimeStr;

  DateTime dateTime = DateTime.now();

  Future<void> pickDate() async {
    final pageContext = context;
    final DateTime? picked = byMonth
        ? await _pickMonthByBottomSheet()
        : await showDatePicker(
            // ignore: use_build_context_synchronously
            context: pageContext,
            initialDate: dateTime,
            firstDate: DateTime(2000), // 最早时间
            lastDate: DateTime(2100), // 最晚时间
          );

    if (picked != null) {
      if (byMonth) {
        dateTime = DateTime(picked.year, picked.month, 1);
      } else {
        dateTime = picked;
      }
      notify();
      _query();
    }
  }

  Future<DateTime?> _pickMonthByBottomSheet() async {
    int selectedYear = dateTime.year;
    int selectedMonth = dateTime.month;
    const int minYear = 2000;
    const int maxYear = 2100;
    const List<String> monthLabels = [
      '1月',
      '2月',
      '3月',
      '4月',
      '5月',
      '6月',
      '7月',
      '8月',
      '9月',
      '10月',
      '11月',
      '12月',
    ];

    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setState) {
              return Padding(
                padding: EdgeInsets.fromLTRB(
                    spaces.gapDef, spaces.gapDef, spaces.gapDef, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          "选择月份",
                          style: TextStyle(
                            fontSize: fontSizes.s18,
                            fontWeight: fontWeights.semiBold,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: selectedYear <= minYear
                              ? null
                              : () {
                                  setState(() {
                                    selectedYear--;
                                  });
                                },
                          icon: const Icon(Icons.keyboard_arrow_left),
                        ),
                        Text(
                          "$selectedYear",
                          style: TextStyle(
                            fontSize: fontSizes.s16,
                            fontWeight: fontWeights.medium,
                          ),
                        ),
                        IconButton(
                          onPressed: selectedYear >= maxYear
                              ? null
                              : () {
                                  setState(() {
                                    selectedYear++;
                                  });
                                },
                          icon: const Icon(Icons.keyboard_arrow_right),
                        ),
                      ],
                    ),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: 12,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 2.2,
                      ),
                      itemBuilder: (context, index) {
                        final month = index + 1;
                        final selected = selectedMonth == month;
                        return XBButton(
                          onTap: () {
                            setState(() {
                              selectedMonth = month;
                            });
                          },
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: selected
                                  ? Theme.of(ctx).colorScheme.primary
                                  : Colors.transparent,
                              border: Border.all(
                                color: selected
                                    ? Theme.of(ctx).colorScheme.primary
                                    // ignore: deprecated_member_use
                                    : Colors.grey.withOpacity(0.5),
                              ),
                            ),
                            child: Text(
                              monthLabels[index],
                              style: TextStyle(
                                color: selected
                                    ? Colors.white
                                    : Theme.of(ctx).colorScheme.onSurface,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    SizedBox(height: spaces.gapDef),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              Navigator.of(sheetContext).pop();
                            },
                            child: const Text("取消"),
                          ),
                        ),
                        SizedBox(width: spaces.gapDef),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () {
                              Navigator.of(sheetContext).pop(
                                  DateTime(selectedYear, selectedMonth, 1));
                            },
                            child: const Text("确定"),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  void switchFilterMode(bool monthMode) {
    if (byMonth == monthMode) return;
    final wasMonthMode = byMonth;
    byMonth = monthMode;
    if (wasMonthMode && !monthMode) {
      dateTime = DateTime.now();
    } else if (!wasMonthMode && monthMode) {
      final now = DateTime.now();
      dateTime = DateTime(now.year, now.month, 1);
    }
    _query();
  }

  List<int> selectedIndex = [];

  List<String> get logPaths {
    List<String> ret = [];
    for (var element in selectedIndex) {
      ret.add(logs[element].path);
    }
    return ret;
  }

  bool isSelected(int index) {
    return selectedIndex.contains(index);
  }

  onTapIndex(int index) {
    if (selectedIndex.contains(index)) {
      selectedIndex.remove(index);
    } else {
      selectedIndex.add(index);
    }
    notify();
  }

  open(int index) {
    dialogWidget(ViewLogDialog(path: logs[index].path));
    // push(ViewLogPage(path: logs[index].path));
  }
}

class ViewLogDialog extends XBWidget<ViewLogDialogVM> {
  final String path;
  const ViewLogDialog({required this.path, super.key});

  @override
  generateVM(BuildContext context) {
    return ViewLogDialogVM(context: context);
  }

  @override
  Widget buildWidget(ViewLogDialogVM vm, BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.75;
    return Padding(
      padding: EdgeInsets.only(left: spaces.gapDef, right: spaces.gapDef),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: Colors.white,
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(width: 64),
                    Text(
                      "详情",
                      style: TextStyle(
                        fontSize: fontSizes.s20,
                        fontWeight: fontWeights.semiBold,
                      ),
                    ),
                    Row(
                      children: [
                        XBButton(
                          onTap: () async {
                            await Clipboard.setData(
                              ClipboardData(text: vm.content),
                            );
                            toast("已复制");
                          },
                          child: SizedBox(
                            width: 64,
                            height: naviBarH,
                            child: const Center(child: Text("复制")),
                          ),
                        ),
                        XBButton(
                          onTap: () {
                            pop();
                          },
                          child: SizedBox(
                            width: 64,
                            height: naviBarH,
                            child: const Center(child: Text("关闭")),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(vm.content),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ViewLogDialogVM extends XBVM<ViewLogDialog> {
  ViewLogDialogVM({required super.context}) {
    load();
  }

  String content = '';

  Future<void> load() async {
    content = await readTxt(widget.path);
    notify();
  }

  Future<String> readTxt(String path) async {
    final file = File(path);
    return await file.readAsString();
  }
}
