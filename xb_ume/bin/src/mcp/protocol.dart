// MCP（Model Context Protocol）JSON-RPC 2.0 协议层。
//
// 零第三方依赖：只做消息编解码与错误码定义，传输（stdio / Streamable
// HTTP）由 bin/src/mcp/server.dart 负责。协议版本声明 2025-06-18，同时
// 兼容回显 2024-11-05 / 2025-03-26（客户端请求什么就回什么）。
library;

import 'dart:convert';

/// 服务端支持的最高协议版本。
const String kMcpLatestVersion = '2025-06-18';

/// 兼容回显的协议版本集合（客户端请求命中即原样回显）。
const Set<String> kMcpSupportedVersions = <String>{
  '2024-11-05',
  '2025-03-26',
  '2025-06-18',
};

/// 服务名（initialize.serverInfo.name）。
const String kMcpServerName = 'xb_ume';

// JSON-RPC 标准错误码。
const int kMcpParseError = -32700;
const int kMcpInvalidRequest = -32600;
const int kMcpMethodNotFound = -32601;
const int kMcpInvalidParams = -32602;
const int kMcpInternalError = -32603;

/// 构造工具参数的 JSON Schema（与 prop() 配套）。
Map<String, Object?> toolSchema(
  Map<String, Object?> properties, [
  List<String>? required,
]) =>
    <String, Object?>{
      'type': 'object',
      'properties': properties,
      if (required != null && required.isNotEmpty) 'required': required,
    };

/// MCP 工具执行错误（tools/call 的 isError 内容，不是 JSON-RPC 错误）。
const int kMcpToolError = -32000;

/// 工具执行失败：handler 内抛出，由 server 转成 isError=true 的文本结果。
///
/// 与「参数非法」区分：参数校验失败也用它，但 message 前缀统一为
/// 「invalid_params:」，便于客户端/AI 自纠。
class McpToolException implements Exception {
  McpToolException(this.message, {this.hint});

  final String message;

  /// 可选的自纠提示（如「先 tap 输入框」「用 xbume_sessions 选择会话」）。
  final String? hint;

  String get text => hint == null ? message : '$message\n提示：$hint';

  @override
  String toString() => text;
}

/// 单个 JSON-RPC 请求（只保留 MCP 用得到的字段）。
class McpRequest {
  McpRequest({
    required this.id,
    required this.method,
    required this.params,
  });

  /// id 为 null 表示 notification（不返回响应）。
  final Object? id;
  final String method;
  final Map<String, Object?> params;

  bool get isNotification => id == null;

  /// 宽松解析：字段缺失/类型不符都抛 McpToolException（-32600）。
  static McpRequest parse(Object? raw) {
    if (raw is! Map) {
      throw McpToolException('请求不是 JSON 对象');
    }
    final jsonrpc = raw['jsonrpc'];
    if (jsonrpc != null && jsonrpc != '2.0') {
      throw McpToolException('jsonrpc 必须为 2.0');
    }
    final method = raw['method']?.toString() ?? '';
    if (method.isEmpty) {
      throw McpToolException('缺少 method');
    }
    final rawParams = raw['params'];
    final params = rawParams is Map
        ? Map<String, Object?>.from(rawParams)
        : <String, Object?>{};
    return McpRequest(id: raw['id'], method: method, params: params);
  }
}

/// 构造 JSON-RPC 成功响应。
Map<String, Object?> mcpResult(Object? id, Object? result) =>
    <String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result};

/// 构造 JSON-RPC 错误响应。
Map<String, Object?> mcpError(
  Object? id,
  int code,
  String message, [
  Object? data,
]) =>
    <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    };

/// 构造 notification 消息。
Map<String, Object?> mcpNotification(String method, [Object? params]) =>
    <String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    };

/// initialize 响应（协议版本按客户端请求协商）。
Map<String, Object?> mcpInitializeResult({
  required String requestedVersion,
  required String serverVersion,
}) {
  final version =
      kMcpSupportedVersions.contains(requestedVersion) ? requestedVersion : kMcpLatestVersion;
  return <String, Object?>{
    'protocolVersion': version,
    'capabilities': <String, Object?>{
      'tools': <String, Object?>{'listChanged': false},
    },
    'serverInfo': <String, Object?>{
      'name': kMcpServerName,
      'version': serverVersion,
    },
  };
}

/// 校验参数必填字符串；空串抛错。
String requireString(Map<String, Object?> args, String key,
    {String? hint}) {
  final v = args[key];
  if (v is String && v.trim().isNotEmpty) return v;
  if (v is num || v is bool) return '$v';
  throw McpToolException('缺少参数 $key', hint: hint);
}

/// 可选字符串（null/空 → null）。
String? optionalString(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

/// 可选数值（字符串数字也接受；null → null）。
double? optionalDouble(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}

/// 可选整数。
int? optionalInt(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse('$v');
}

/// 可选布尔。
bool optionalBool(Map<String, Object?> args, String key,
    {bool fallback = false}) {
  final v = args[key];
  if (v == null) return fallback;
  if (v is bool) return v;
  final s = '$v'.toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

/// 参数名到 JSON Schema 属性的便捷构造。
Map<String, Object?> prop(
  String type,
  String description, {
  List<String>? enumValues,
  Object? defaultValue,
}) =>
    <String, Object?>{
      'type': type,
      'description': description,
      if (enumValues != null) 'enum': enumValues,
      if (defaultValue != null) 'default': defaultValue,
    };

/// 数组类型属性的便捷构造。
Map<String, Object?> arrayProp(String description, String itemType) =>
    <String, Object?>{
      'type': 'array',
      'description': description,
      'items': <String, Object?>{'type': itemType},
    };

/// 对象类型属性的便捷构造。
Map<String, Object?> objectProp(
  String description, [
  Map<String, Object?>? properties,
]) =>
    <String, Object?>{
      'type': 'object',
      'description': description,
      if (properties != null) 'properties': properties,
    };

/// 把任意结果压成 MCP content 数组（text + 可选 structuredContent）。
///
/// text 是给模型读的：对象/数组直接 jsonEncode，字符串原样，数值转字符串。
Map<String, Object?> mcpContent(Object? value, {bool isError = false}) {
  final text = value is String ? value : _jsonText(value);
  return <String, Object?>{
    'content': <Object?>[
      <String, Object?>{'type': 'text', 'text': text},
    ],
    if (isError) 'isError': true,
  };
}

/// 结构化结果（2025-06-18 起客户端可读 structuredContent）。
Map<String, Object?> mcpStructured(
  Object? value, {
  bool isError = false,
}) {
  final base = mcpContent(value, isError: isError);
  if (value is Map<String, Object?>) {
    base['structuredContent'] = value;
  } else if (value is List) {
    base['structuredContent'] = <String, Object?>{'items': value};
  }
  return base;
}

/// 轻量 JSON 序列化：失败时回退 toString，绝不抛错。
String _jsonText(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return '$value';
  }
}

/// 工具执行的统一结果：content 数组 + 可选 structuredContent。
///
/// text 给模型读，structuredContent 给客户端做程序化处理（两者内容同源，
/// 但 text 可做长文本截断，不影响结构化字段）。
class McpToolResult {
  McpToolResult({
    required this.content,
    this.structured,
    this.isError = false,
  });

  /// 纯文本结果。
  factory McpToolResult.text(
    String text, {
    Map<String, Object?>? structured,
    bool isError = false,
  }) =>
      McpToolResult(
        content: <Map<String, Object?>>[
          <String, Object?>{'type': 'text', 'text': text},
        ],
        structured: structured,
        isError: isError,
      );

  /// 结构化结果：text 为紧凑 JSON，同时附 structuredContent。
  factory McpToolResult.json(
    Object? value, {
    String? text,
    bool isError = false,
  }) {
    final body = text ?? _jsonText(value);
    return McpToolResult(
      content: <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': body},
      ],
      structured:
          value is Map<String, Object?> ? value : <String, Object?>{'items': value},
      isError: isError,
    );
  }

  /// 截图：image content（模型直接看图）+ 可选文字说明。
  factory McpToolResult.image(
    String base64, {
    String mimeType = 'image/png',
    String? caption,
    Map<String, Object?>? structured,
  }) =>
      McpToolResult(
        content: <Map<String, Object?>>[
          if (caption != null && caption.isNotEmpty)
            <String, Object?>{'type': 'text', 'text': caption},
          <String, Object?>{'type': 'image', 'data': base64, 'mimeType': mimeType},
        ],
        structured: structured,
      );

  final List<Map<String, Object?>> content;
  final Map<String, Object?>? structured;
  final bool isError;

  Map<String, Object?> toJson() => <String, Object?>{
        'content': content,
        if (structured != null) 'structuredContent': structured,
        if (isError) 'isError': true,
      };
}

/// 长文本截断（用于 eval 输出等不可控长度结果）。
String truncateText(String s, {int max = 64 * 1024}) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}\n…（已截断，原始长度 ${s.length} 字符）';
}
