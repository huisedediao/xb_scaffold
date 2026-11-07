/// 直连会话（release / AOT，无 eval）下的字段树提供者。
///
/// VM 会话靠 VM service 的 `getObject` 展开任意对象；直连通道没有 eval，只能由
/// app 自己把「想被看到的字段」dump 成可序列化结构。实现本接口并
/// `XBUme.registerInspectable(...)` 之后：
///   - GUI「实例」Tab 的注册表里就能看到它，点「查看字段」展开字段树；
///   - MCP `xbume_instances`（action=stores / tree）在直连会话下也返回同样内容。
///
/// 值支持 `Map` / `List` / 标量（String / num / bool / null）：嵌套 Map/List 会
/// 展开成子节点，其余按字符串叶子展示。只读——直连通道不提供字段写回
/// （写状态属于 app 的业务决定，应走 `XBUmeStorageAdapter` 或 app 自己的入口）。
abstract class XBUmeInspectable {
  /// 注册表里显示的标识（建议用稳定、可读的名字，如 `AppState`）。
  String get inspectId;

  /// 类型名（显示用，省略时取 [inspectId]）。
  String get inspectType => 'Inspectable';

  /// 字段快照。键是字段名，值可以是任意 JSON 可编码值。
  Map<String, dynamic> inspect();
}

/// [XBUmeInspectable] 的 Map 实现：直接读一个 Map 的当前内容。
///
/// 适合「已经有一份 Map 状态、想顺手在面板里看」的场景；Map 是引用读取，
/// 外部改动下一次展开即可看到。
class XBUmeMapInspectable implements XBUmeInspectable {
  XBUmeMapInspectable({
    required this.inspectId,
    required Map<String, dynamic> data,
    this.inspectType = 'Map',
  }) : _data = data;

  @override
  final String inspectId;

  @override
  final String inspectType;

  final Map<String, dynamic> _data;

  @override
  Map<String, dynamic> inspect() => Map<String, dynamic>.from(_data);
}