import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/services.dart'
    show Clipboard, ClipboardData;

/// 双击链条行后请求 IDE 打开源码。
///
/// 事件经 VM service 的 Extension 流发出（debug 模式可用），由本机
/// 常驻监听脚本 `dart run xb_ume:ide --daemon` 接收并唤起 IDE；
/// 同时复制 `path:line:column` 到剪贴板，作为脚本未运行时的兜底。
abstract final class XBUmeIdeJump {
  /// VM service Extension 事件名，与 bin/ide.dart 中约定一致。
  static const String eventId = 'xb_ume:openSource';

  /// 发送打开源码请求。
  ///
  /// 返回事件是否已发出（需要 file + line 才有效）；剪贴板复制
  /// 无论如何都尝试执行（best-effort，失败静默）。
  static Future<bool> requestOpen({
    required String? file,
    required int? line,
    required int? column,
  }) async {
    final locationText = buildLocationText(
      file: file,
      line: line,
      column: column,
    );
    if (locationText != null) {
      try {
        await Clipboard.setData(ClipboardData(text: locationText));
      } catch (_) {
        // 剪贴板不可用（如部分测试环境）时忽略，事件仍尝试发送。
      }
    }
    if (file == null || file.isEmpty || line == null) {
      return false;
    }
    try {
      developer.postEvent(eventId, <String, dynamic>{
        'file': file,
        'line': line,
        'column': column ?? 0,
      });
      return true;
    } catch (_) {
      // release 模式或 VM service 不可用时静默降级为纯剪贴板。
      return false;
    }
  }

  /// 组装 `path:line:column` 文本；file 为 URI 时转本地路径。
  /// 信息不足（无 file 或无 line）时返回 null。
  static String? buildLocationText({
    required String? file,
    required int? line,
    required int? column,
  }) {
    if (file == null || file.isEmpty || line == null) return null;
    final path = toFilePath(file);
    return column == null ? '$path:$line' : '$path:$line:$column';
  }

  /// file URI 转本地路径；非 file URI 原样返回。
  static String toFilePath(String uri) {
    try {
      final parsed = Uri.parse(uri);
      if (parsed.scheme == 'file') {
        return parsed.toFilePath();
      }
    } catch (_) {
      // 非 URI 格式，原样返回。
    }
    return uri;
  }
}
