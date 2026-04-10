import 'dart:io';

import 'package:example/pages/xb_log_demo.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XbLogDemoVM extends XBPageVM<XbLogDemo> {
  XbLogDemoVM({required super.context});

  static const String demoFolderName = 'xbLogsDemo';

  Map<String, List<XBLogFileInfo>> logsByDate = {};
  String statusText = '点击下方按钮，体验 XBLogsUtil 全部方法';
  String? lastZipPath;

  int get totalLogCount {
    int count = 0;
    for (final item in logsByDate.values) {
      count += item.length;
    }
    return count;
  }

  List<XBLogFileInfo> get allLogs {
    final result = <XBLogFileInfo>[];
    for (final item in logsByDate.values) {
      result.addAll(item);
    }
    result.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return result;
  }

  @override
  void didCreated() {
    super.didCreated();
    refreshLogs();
  }

  Future<void> refreshLogs({bool showToastMessage = false}) async {
    logsByDate = await XBLogsUtil.getAllLogsGroupedByDate(
      folderName: demoFolderName,
    );

    _setStatus(
      '刷新完成：日期目录 ${logsByDate.length} 个，日志文件 $totalLogCount 个',
      showToastMessage: showToastMessage,
    );
  }

  Future<void> demoWriteLog() async {
    final now = DateTime.now();
    await XBLogsUtil.writeLog(
      {
        'method': 'writeLog',
        'time': now.toIso8601String(),
        'message': '这是 writeLog(Map<String, dynamic>) 的示例',
        'extra': {
          'platform': Platform.operatingSystem,
          'version': Platform.operatingSystemVersion,
        },
      },
      folderName: demoFolderName,
    );

    await refreshLogs();
    _setStatus('writeLog 已写入一条 Map 日志', showToastMessage: true);
  }

  Future<void> demoWriteText() async {
    final now = DateTime.now();
    final fileName = 'text_demo_${_formatDateTimeForFile(now)}.txt';
    await XBLogsUtil.writeText(
      '这是 writeText(String) 的示例\n当前时间：${now.toIso8601String()}',
      folderName: demoFolderName,
      fileName: fileName,
    );

    await refreshLogs();
    _setStatus('writeText 已写入：$fileName', showToastMessage: true);
  }

  Future<void> demoGetAllLogsGroupedByDate() async {
    final grouped = await XBLogsUtil.getAllLogsGroupedByDate(
      folderName: demoFolderName,
    );
    logsByDate = grouped;
    _setStatus(
      'getAllLogsGroupedByDate 查询完成：${grouped.length} 个日期目录',
      showToastMessage: true,
    );
  }

  Future<void> demoGetLogsByDate() async {
    final date = _formatDate(DateTime.now());
    final logs = await XBLogsUtil.getLogsByDate(
      date,
      folderName: demoFolderName,
    );

    _setStatus(
      'getLogsByDate($date) 查询到 ${logs.length} 条日志',
      showToastMessage: true,
    );
  }

  Future<void> demoGetLogsByMonth() async {
    final month = _formatMonth(DateTime.now());
    final logs = await XBLogsUtil.getLogsByMonth(
      month,
      folderName: demoFolderName,
    );

    _setStatus(
      'getLogsByMonth($month) 查询到 ${logs.length} 个日期目录',
      showToastMessage: true,
    );
  }

  Future<void> demoZipSelectedLogs() async {
    await _ensureLogsForZip();
    final selected = _pickLogsForZip();

    if (selected.isEmpty) {
      _setStatus('zipSelectedLogs 失败：没有可打包的日志');
      return;
    }

    final zipPath = await XBLogsUtil.zipSelectedLogs(
      selected,
      folderName: demoFolderName,
      zipFileName: 'zip_selected_${_formatDateTimeForFile(DateTime.now())}.zip',
    );

    if (zipPath == null) {
      _setStatus('zipSelectedLogs 失败：zip 生成失败', showToastMessage: true);
      return;
    }

    lastZipPath = zipPath;
    _setStatus('zipSelectedLogs 成功：$zipPath', showToastMessage: true);
  }

  Future<void> demoShareZipFile() async {
    await _ensureLogsForZip();

    String? zipPath = lastZipPath;
    if (zipPath == null || !await File(zipPath).exists()) {
      final selected = _pickLogsForZip();
      if (selected.isEmpty) {
        _setStatus('shareZipFile 失败：没有可分享的日志');
        return;
      }

      zipPath = await XBLogsUtil.zipSelectedLogs(
        selected,
        folderName: demoFolderName,
        zipFileName:
            'share_target_${_formatDateTimeForFile(DateTime.now())}.zip',
      );
    }

    if (zipPath == null) {
      _setStatus('shareZipFile 失败：无法准备 zip 文件', showToastMessage: true);
      return;
    }

    lastZipPath = zipPath;
    final success = await XBLogsUtil.shareZipFile(
      zipPath,
      text: 'XBLogsUtil.shareZipFile demo',
      subject: '日志分享示例',
    );

    _setStatus(
      'shareZipFile(${_shortPath(zipPath)}) => $success',
      showToastMessage: true,
    );
  }

  Future<void> demoZipAndShareSelectedLogs() async {
    await _ensureLogsForZip();
    final selected = _pickLogsForZip();

    if (selected.isEmpty) {
      _setStatus('zipAndShareSelectedLogs 失败：没有可分享的日志');
      return;
    }

    final zipPath = await XBLogsUtil.zipAndShareSelectedLogs(
      selected,
      folderName: demoFolderName,
      zipFileName:
          'zip_and_share_${_formatDateTimeForFile(DateTime.now())}.zip',
      shareText: 'XBLogsUtil.zipAndShareSelectedLogs demo',
      shareSubject: '日志打包并分享示例',
    );

    if (zipPath == null) {
      _setStatus(
        'zipAndShareSelectedLogs 执行失败（可能是分享被取消）',
        showToastMessage: true,
      );
      return;
    }

    lastZipPath = zipPath;
    _setStatus('zipAndShareSelectedLogs 成功：$zipPath', showToastMessage: true);
  }

  Future<void> demoDeleteLogByPath() async {
    await refreshLogs();
    final target = allLogs.isNotEmpty ? allLogs.first : null;

    if (target == null) {
      _setStatus('deleteLogByPath 失败：没有日志可删', showToastMessage: true);
      return;
    }

    final success = await XBLogsUtil.deleteLogByPath(target.path);
    await refreshLogs();

    _setStatus(
      'deleteLogByPath(${target.name}) => $success',
      showToastMessage: true,
    );
  }

  Future<void> demoDeleteLogsByDate() async {
    await refreshLogs();
    final targetDate = logsByDate.keys.isNotEmpty
        ? logsByDate.keys.first
        : _formatDate(DateTime.now());

    final success = await XBLogsUtil.deleteLogsByDate(
      targetDate,
      folderName: demoFolderName,
    );

    await refreshLogs();
    _setStatus(
      'deleteLogsByDate($targetDate) => $success',
      showToastMessage: true,
    );
  }

  String formatFileSize(int size) {
    if (size < 1024) {
      return '$size B';
    }
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(2)} KB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String formatTime(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final min = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  List<String> _pickLogsForZip() {
    final logs = allLogs;
    if (logs.length <= 3) {
      return logs.map((e) => e.path).toList();
    }
    return logs.take(3).map((e) => e.path).toList();
  }

  Future<void> _ensureLogsForZip() async {
    await refreshLogs();
    if (allLogs.isNotEmpty) {
      return;
    }

    await demoWriteLog();
    await demoWriteText();
    await refreshLogs();
  }

  void _setStatus(String msg, {bool showToastMessage = false}) {
    statusText = '${formatTime(DateTime.now())}\n$msg';
    notify();
    if (showToastMessage) {
      toast(msg);
    }
  }

  String _shortPath(String path) {
    final parts = path.split('/');
    if (parts.length <= 3) {
      return path;
    }
    return '${parts[parts.length - 3]}/${parts[parts.length - 2]}/${parts.last}';
  }

  String _formatDate(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _formatMonth(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    return '$y-$m';
  }

  String _formatDateTimeForFile(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final min = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');

    return '$y$m${d}_$h$min${s}_$ms';
  }
}
