import 'package:example/pages/xb_log_demo_vm.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XbLogDemo extends XBPage<XbLogDemoVM> {
  const XbLogDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XbLogDemoVM(context: context);
  }

  @override
  String setTitle(XbLogDemoVM vm) {
    return 'XBLogsUtil Demo';
  }

  @override
  Widget buildPage(XbLogDemoVM vm, BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(spaces.gapDef),
      children: [
        _buildIntroCard(vm),
        const SizedBox(height: 12),
        _buildActionCard(vm),
        const SizedBox(height: 12),
        _buildStatusCard(vm),
        const SizedBox(height: 12),
        _buildLogsCard(vm),
      ],
    );
  }

  Widget _buildIntroCard(XbLogDemoVM vm) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'xb_logs_util.dart 方法演示',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text('Demo 目录：${XbLogDemoVM.demoFolderName}'),
            const SizedBox(height: 4),
            Text('日期目录数：${vm.logsByDate.length}，日志总数：${vm.totalLogCount}'),
          ],
        ),
      ),
    );
  }

  Widget _buildActionCard(XbLogDemoVM vm) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildActionButton('writeLog', vm.demoWriteLog),
            _buildActionButton('writeText', vm.demoWriteText),
            _buildActionButton(
              'getAllLogsGroupedByDate',
              vm.demoGetAllLogsGroupedByDate,
            ),
            _buildActionButton('getLogsByDate', vm.demoGetLogsByDate),
            _buildActionButton('getLogsByMonth', vm.demoGetLogsByMonth),
            _buildActionButton('zipSelectedLogs', vm.demoZipSelectedLogs),
            _buildActionButton('shareZipFile', vm.demoShareZipFile),
            _buildActionButton(
              'zipAndShareSelectedLogs',
              vm.demoZipAndShareSelectedLogs,
            ),
            _buildActionButton('deleteLogByPath', vm.demoDeleteLogByPath),
            _buildActionButton('deleteLogsByDate', vm.demoDeleteLogsByDate),
            _buildActionButton(
              'refresh',
              () => vm.refreshLogs(showToastMessage: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(XbLogDemoVM vm) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '执行结果',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SelectableText(vm.statusText),
            if (vm.lastZipPath != null) ...[
              const SizedBox(height: 8),
              const Text('最近 zip 路径：'),
              SelectableText(vm.lastZipPath!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLogsCard(XbLogDemoVM vm) {
    if (vm.logsByDate.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('暂无日志，先点 writeLog / writeText 生成示例数据'),
        ),
      );
    }

    final children = <Widget>[];
    for (final entry in vm.logsByDate.entries) {
      children.add(_buildDateSection(vm, entry.key, entry.value));
      children.add(const SizedBox(height: 8));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('日志列表', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildDateSection(
    XbLogDemoVM vm,
    String date,
    List<XBLogFileInfo> logs,
  ) {
    final rows = <Widget>[];
    for (final file in logs) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '${file.name} | ${vm.formatFileSize(file.size)} | ${vm.formatTime(file.modifiedAt)}',
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.grey.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$date (${logs.length})',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }

  Widget _buildActionButton(String text, Future<void> Function() onTap) {
    return ElevatedButton(
      onPressed: () async {
        await onTap();
      },
      child: Text(text),
    );
  }
}
