import 'dart:io';

import 'package:flutter/material.dart';
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
          onTap: () {
            final logPaths = vm.logPaths;
            if (logPaths.isEmpty) {
              toast("请先选中要分享的日志");
              return;
            }
            XBLogsUtil.zipAndShareSelectedLogs(logPaths);
          },
          coverTransparentWhileOpacity: true,
          child: Padding(
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 8, bottom: 8),
            child: Text("分享选中日志"),
          ))
    ];
  }

  @override
  Widget buildPage(XBLogsOperaPageVM vm, BuildContext context) {
    return Column(
      children: [
        // Container(
        //   height: 55,
        //   child: XBButton(
        //       onTap: () {
        //         XBLogsUtil.writeLog({
        //           "name":
        //               "test${XBTimeUtil.dateTime2Str(dateTime: DateTime.now())}"
        //         });
        //         vm._query();
        //       },
        //       child: Text("写日志")),
        // ),
        Container(
          height: 55,
          child: XBButton(
            onTap: () {
              vm.pickDate();
            },
            child: Row(
              children: [
                Text("日期："),
                Text(
                  vm.dateTimeStr,
                  style: TextStyle(color: Colors.blue),
                )
              ],
            ),
          ),
        ),
        Expanded(
            child: vm.logs.isEmpty
                ? Container(
                    alignment: Alignment.center,
                    child: Text("暂无数据"),
                  )
                : ListView.separated(
                    itemCount: vm.logs.length,
                    itemBuilder: (context, index) {
                      XBLogFileInfo logFileInfo = vm.logs[index];
                      return GestureDetector(
                        onLongPress: () {
                          vm.open(index);
                        },
                        child: XBCellTitleSelect(
                          padding: EdgeInsets.only(
                              left: spaces.gapDef, right: spaces.gapDef),
                          contentHeight: 40,
                          title: logFileInfo.name,
                          isSelected: vm.isSelected(index),
                          onTap: () {
                            vm.onTapIndex(index);
                          },
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

  List<XBLogFileInfo> logs = [];

  _query() async {
    selectedIndex.clear();
    logs = await XBLogsUtil.getLogsByDate(dateTimeStr);
    notify();
  }

  String get dateTimeStr =>
      XBTimeUtil.dateTime2Str(dateTime: dateTime, format: XBTimeUtil.formatYMD);

  DateTime dateTime = DateTime.now();

  Future<void> pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(), // 默认选中今天
      firstDate: DateTime(2000), // 最早时间
      lastDate: DateTime(2100), // 最晚时间
    );

    if (picked != null) {
      dateTime = picked;
      notify();
      _query();
    }
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
    return Padding(
      padding: EdgeInsets.only(left: spaces.gapDef, right: spaces.gapDef),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: Colors.white,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      width: 64,
                    ),
                    Text(
                      "logs",
                      style: TextStyle(
                          fontSize: fontSizes.s20,
                          fontWeight: fontWeights.semiBold),
                    ),
                    XBButton(
                      onTap: () {
                        pop();
                      },
                      child: Container(
                        width: 64,
                        height: naviBarH,
                        alignment: Alignment.center,
                        child: Text("关闭"),
                      ),
                    ),
                  ],
                ),
                SelectableText(vm.content),
              ],
            ),
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
