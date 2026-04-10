import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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

  static Future<String> _getRootPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
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
}
