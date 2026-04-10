import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class XBLogFileInfo {
  final String name;
  final String path;
  final String date; // yyyy-MM-dd
  final int size;
  final DateTime modifiedAt;

  const XBLogFileInfo({
    required this.name,
    required this.path,
    required this.date,
    required this.size,
    required this.modifiedAt,
  });

  @override
  String toString() {
    return 'XBLogFileInfo(name: $name, path: $path, date: $date, size: $size, modifiedAt: $modifiedAt)';
  }
}

class XBLogsUtil {
  XBLogsUtil._();

  /// 写 Map 日志（对外用这个）
  static Future<void> writeLog(
    Map<String, dynamic> data, {
    String folderName = 'xbLogs',
  }) async {
    try {
      final content = const JsonEncoder.withIndent('  ').convert(data);
      await writeText(
        content,
        folderName: folderName,
      );
    } catch (e, s) {
      debugPrint('XBLogUtil writeLog error: $e');
      debugPrint('$s');
    }
  }

  /// 写字符串（底层核心方法）
  static Future<void> writeText(
    String text, {
    String folderName = 'xbLogs',
    String? fileName,
  }) async {
    try {
      final rootPath = await _getRootPath();
      final now = DateTime.now();

      final dateFolderName = _formatDate(now);
      final finalFileName = fileName ?? '${_formatDateTimeWithMs(now)}.txt';

      final dirPath = '$rootPath/$folderName/$dateFolderName';
      final dir = Directory(dirPath);

      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final filePath = '$dirPath/$finalFileName';
      final file = File(filePath);

      await file.writeAsString(text, flush: true);
    } catch (e, s) {
      debugPrint('XBLogUtil writeText error: $e');
      debugPrint('$s');
    }
  }

  /// 获取所有日志，并按日期分组
  static Future<Map<String, List<XBLogFileInfo>>> getAllLogsGroupedByDate({
    String folderName = 'xbLogs',
  }) async {
    try {
      final rootDir = await _getLogsRootDir(folderName: folderName);
      final result = <String, List<XBLogFileInfo>>{};

      if (!await rootDir.exists()) {
        return result;
      }

      final entities = rootDir.listSync(followLinks: false);

      for (final entity in entities) {
        if (entity is! Directory) continue;

        final date = p.basename(entity.path);
        if (!_isValidDateFolderName(date)) continue;

        final logs = await _readLogsFromDateDirectory(entity, date);
        if (logs.isNotEmpty) {
          logs.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
          result[date] = logs;
        }
      }

      return _sortMapByDateDesc(result);
    } catch (e, s) {
      debugPrint('XBLogUtil getAllLogsGroupedByDate error: $e');
      debugPrint('$s');
      return {};
    }
  }

  /// 根据日期查询日志列表
  ///
  /// [date] 格式：yyyy-MM-dd
  static Future<List<XBLogFileInfo>> getLogsByDate(
    String date, {
    String folderName = 'xbLogs',
  }) async {
    try {
      final rootPath = await _getRootPath();
      final dir = Directory('$rootPath/$folderName/$date');

      if (!await dir.exists()) {
        return [];
      }

      final logs = await _readLogsFromDateDirectory(dir, date);
      logs.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
      return logs;
    } catch (e, s) {
      debugPrint('XBLogUtil getLogsByDate error: $e');
      debugPrint('$s');
      return [];
    }
  }

  /// 按月查询日志
  ///
  /// [month] 格式：yyyy-MM
  ///
  /// 返回该月所有日志，并按日期分组
  static Future<Map<String, List<XBLogFileInfo>>> getLogsByMonth(
    String month, {
    String folderName = 'xbLogs',
  }) async {
    try {
      final all = await getAllLogsGroupedByDate(folderName: folderName);
      final result = <String, List<XBLogFileInfo>>{};

      for (final entry in all.entries) {
        if (entry.key.startsWith('$month-')) {
          result[entry.key] = entry.value;
        }
      }

      return _sortMapByDateDesc(result);
    } catch (e, s) {
      debugPrint('XBLogUtil getLogsByMonth error: $e');
      debugPrint('$s');
      return {};
    }
  }

  /// 将选中的日志打包成 zip，并返回 zip 本地路径
  static Future<String?> zipSelectedLogs(
    List<String> logPaths, {
    String folderName = 'xbLogs',
    String? zipFileName,
  }) async {
    try {
      if (logPaths.isEmpty) return null;

      final rootPath = await _getRootPath();
      final exportDir = Directory('$rootPath/$folderName/zip');

      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }

      final now = DateTime.now();
      final finalZipFileName =
          zipFileName ?? 'logs_${_formatDateTimeForFile(now)}.zip';
      final zipPath = '${exportDir.path}/$finalZipFileName';

      final encoder = ZipFileEncoder();
      encoder.create(zipPath);

      for (final logPath in logPaths) {
        final file = File(logPath);
        if (!await file.exists()) continue;

        final parentDirName = p.basename(p.dirname(logPath));
        final fileName = p.basename(logPath);
        final archiveName = '$parentDirName/$fileName';

        encoder.addFile(file, archiveName);
      }

      encoder.close();
      return zipPath;
    } catch (e, s) {
      debugPrint('XBLogUtil zipSelectedLogs error: $e');
      debugPrint('$s');
      return null;
    }
  }

  /// 删除某天日志
  ///
  /// [date] 格式：yyyy-MM-dd
  ///
  /// 返回 true 表示删除成功或目录本来就不存在
  static Future<bool> deleteLogsByDate(
    String date, {
    String folderName = 'xbLogs',
  }) async {
    try {
      final rootPath = await _getRootPath();
      final dir = Directory('$rootPath/$folderName/$date');

      if (!await dir.exists()) {
        return true;
      }

      await dir.delete(recursive: true);
      return true;
    } catch (e, s) {
      debugPrint('XBLogUtil deleteLogsByDate error: $e');
      debugPrint('$s');
      return false;
    }
  }

  /// 删除单个日志文件
  static Future<bool> deleteLogByPath(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return true;
      }

      await file.delete();
      return true;
    } catch (e, s) {
      debugPrint('XBLogUtil deleteLogByPath error: $e');
      debugPrint('$s');
      return false;
    }
  }

  /// 分享 zip 文件
  ///
  /// [zipPath] zip 文件完整路径
  /// [text] 分享面板中的附带文案
  /// [subject] 分享主题
  ///
  /// 返回 true 表示已触发系统分享
  static Future<bool> shareZipFile(
    String zipPath, {
    String? text,
    String? subject,
  }) async {
    try {
      final file = File(zipPath);
      if (!await file.exists()) {
        debugPrint('XBLogUtil shareZipFile error: zip not found -> $zipPath');
        return false;
      }

      final xFile = XFile(
        zipPath,
        mimeType: 'application/zip',
        name: p.basename(zipPath),
      );

      await SharePlus.instance.share(
        ShareParams(
          files: [xFile],
          text: text,
          subject: subject,
        ),
      );

      return true;
    } catch (e, s) {
      debugPrint('XBLogUtil shareZipFile error: $e');
      debugPrint('$s');
      return false;
    }
  }

  /// 先打包，再直接分享
  ///
  /// 返回 zip 本地路径；失败返回 null
  static Future<String?> zipAndShareSelectedLogs(
    List<String> logPaths, {
    String folderName = 'xbLogs',
    String? zipFileName,
    String? shareText,
    String? shareSubject,
  }) async {
    try {
      final zipPath = await zipSelectedLogs(
        logPaths,
        folderName: folderName,
        zipFileName: zipFileName,
      );

      if (zipPath == null) return null;

      final success = await shareZipFile(
        zipPath,
        text: shareText,
        subject: shareSubject,
      );

      if (!success) return null;

      return zipPath;
    } catch (e, s) {
      debugPrint('XBLogUtil zipAndShareSelectedLogs error: $e');
      debugPrint('$s');
      return null;
    }
  }

  static Future<Directory> _getLogsRootDir({
    String folderName = 'xbLogs',
  }) async {
    final rootPath = await _getRootPath();
    return Directory('$rootPath/$folderName');
  }

  static Future<List<XBLogFileInfo>> _readLogsFromDateDirectory(
    Directory dir,
    String date,
  ) async {
    final result = <XBLogFileInfo>[];
    final entities = dir.listSync(followLinks: false);

    for (final entity in entities) {
      if (entity is! File) continue;

      final stat = await entity.stat();
      result.add(
        XBLogFileInfo(
          name: p.basename(entity.path),
          path: entity.path,
          date: date,
          size: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }

    return result;
  }

  static Future<String> _getRootPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  static Map<String, List<XBLogFileInfo>> _sortMapByDateDesc(
    Map<String, List<XBLogFileInfo>> map,
  ) {
    final sortedKeys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    final sortedMap = <String, List<XBLogFileInfo>>{};
    for (final key in sortedKeys) {
      sortedMap[key] = map[key]!;
    }
    return sortedMap;
  }

  static bool _isValidDateFolderName(String value) {
    final reg = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    return reg.hasMatch(value);
  }

  static String _formatDate(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _formatDateTimeWithMs(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final min = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');

    return '$y-$m-$d $h:$min:$s-$ms';
  }

  static String _formatDateTimeForFile(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final min = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');

    return '${y}${m}${d}_${h}${min}${s}_$ms';
  }
}
