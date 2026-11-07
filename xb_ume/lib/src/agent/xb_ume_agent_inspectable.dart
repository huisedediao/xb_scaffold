// 直连会话的字段树（`/v1/inspect`）。
//
// VM 会话靠 `getObject` 一层层展开任意对象；AOT 没有 eval，只能读 app 自己
// 注册的 [XBUmeInspectable]。节点形状与 IDE「实例」面板一致（`kind` / `cls` /
// `value` / `length` / `children`），这样 GUI 与 MCP 两侧共用同一套渲染逻辑。
//
// 只读：节点一律不带 `id`，前端因此不会出现「展开（ref）」与「编辑」入口。
library;

import '../core/xb_ume_controller.dart';

/// 单次展开的节点数上限（防止一个超大 Map 把响应撑爆）。
const int _kMaxNodes = 4000;

/// 单个字符串值的最大长度。
const int _kMaxValueChars = 500;

/// 注册表列表：形状对齐 GUI `/api/instances/stores`（`id` 是展示名、
/// `instId` 是取树用的标识）。
Map<String, Object?> agentInspectStoresJson(XBUmeController controller) {
  final items = <Map<String, Object?>>[
    for (final it in controller.inspectables)
      <String, Object?>{
        'id': it.inspectId,
        'instId': it.inspectId,
        'cls': it.inspectType,
      },
  ];
  items.sort(
    (a, b) => (a['id'] as String).compareTo(b['id'] as String),
  );
  return <String, Object?>{'ok': true, 'items': items};
}

/// 字段树：形状对齐 GUI `/api/instances/tree`。
///
/// [depth] 是展开层数（1–4）：depth=1 给根对象的第一层字段，嵌套 Map/List
/// 到层数用尽只报条目数（前端点「刷新」可加深，直连没有 ref 二次展开）。
Map<String, Object?> agentInspectTreeJson(
  XBUmeController controller,
  String id, {
  int depth = 2,
}) {
  final target = controller.findInspectable(id);
  if (target == null) {
    final known = controller.inspectables.map((it) => it.inspectId).toList();
    return <String, Object?>{
      'ok': false,
      'error': known.isEmpty
          ? 'app 没有注册任何 XBUmeInspectable'
              '（app 侧用 XBUme.registerInspectable(XBUmeMapInspectable(...)) 注册）'
          : '未找到 inspectable「$id」，已注册：${known.join('、')}',
    };
  }
  Map<String, dynamic> fields;
  try {
    fields = target.inspect();
  } catch (e) {
    return <String, Object?>{
      'ok': false,
      'error': 'inspect() 抛错：$e',
      'id': id,
      'type': target.inspectType,
    };
  }
  final ctx = _NodeCtx(maxDepth: depth.clamp(1, 4));
  final node = _nodeOf(
    name: '',
    value: fields,
    level: 0,
    cls: target.inspectType,
    ctx: ctx,
  );
  // 根节点补上名字，前端标题栏用的是请求里的 name，这里保持一致。
  node['name'] = target.inspectId;
  return <String, Object?>{
    'ok': true,
    'id': id,
    'type': target.inspectType,
    if (ctx.truncated) 'truncated': true,
    'node': node,
  };
}

class _NodeCtx {
  _NodeCtx({required this.maxDepth});

  final int maxDepth;
  int count = 0;
  bool truncated = false;

  bool take() {
    if (count >= _kMaxNodes) {
      truncated = true;
      return false;
    }
    count += 1;
    return true;
  }
}

Map<String, Object?> _nodeOf({
  required String name,
  required Object? value,
  required int level,
  required _NodeCtx ctx,
  String? cls,
}) {
  if (!ctx.take()) {
    return <String, Object?>{'name': name, 'kind': 'opaque', 'cls': '（节点过多）'};
  }
  if (value is Map) {
    final children = <Map<String, Object?>>[];
    final expand = level < ctx.maxDepth;
    if (expand) {
      for (final e in value.entries) {
        children.add(_nodeOf(
          name: e.key.toString(),
          value: e.value,
          level: level + 1,
          ctx: ctx,
        ));
      }
    }
    return <String, Object?>{
      'name': name,
      'kind': 'map',
      'cls': cls ?? 'Map',
      'length': value.length,
      if (expand) 'children': children,
    };
  }
  if (value is List) {
    final children = <Map<String, Object?>>[];
    final expand = level < ctx.maxDepth;
    if (expand) {
      for (var i = 0; i < value.length; i++) {
        children.add(_nodeOf(
          name: '[$i]',
          value: value[i],
          level: level + 1,
          ctx: ctx,
        ));
      }
    }
    return <String, Object?>{
      'name': name,
      'kind': 'list',
      'cls': cls ?? 'List',
      'length': value.length,
      if (expand) 'children': children,
    };
  }
  final raw = _rawTextOf(value);
  return <String, Object?>{
    'name': name,
    'kind': 'value',
    'cls': cls ?? _typeNameOf(value),
    'value': _cut(raw),
    if (raw.length > _kMaxValueChars) 'truncated': true,
  };
}

String _rawTextOf(Object? v) {
  if (v == null) return 'null';
  if (v is String) return v;
  if (v is double) {
    return v == v.truncateToDouble() ? v.toStringAsFixed(1) : v.toString();
  }
  try {
    return v.toString();
  } catch (_) {
    return '（toString 抛错）';
  }
}

String _cut(String s) =>
    s.length <= _kMaxValueChars ? s : s.substring(0, _kMaxValueChars);

String _typeNameOf(Object? v) {
  if (v == null) return 'null';
  if (v is String) return 'String';
  if (v is bool) return 'bool';
  if (v is int) return 'int';
  if (v is double) return 'double';
  return v.runtimeType.toString();
}