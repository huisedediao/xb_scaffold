// 会话传输层的统一语义接口（方案 A）。
//
// 背景：工具层/场景引擎里原来直接写 `s.client.evalStringOn(lib, 表达式字符串)`，
// 这只有 VM service 通道能执行——release 包里 AOT 没有 eval，直连会话拿不到数据。
//
// 这一层的职责：把「求值」换成**语义方法**（`networkRaw` / `findWidgetRaw` /
// `tapRef` …）。VM 实现内部还是那套表达式，Agent 实现走 app 内 HTTP 端点并把结果
// 整形回**与 VM 完全相同的原始串格式**，所以调用方的解析逻辑一行都不用改，
// 也不必在工具里写 `if (vm) ... else ...`。
//
// 不支持的能力（路由栈需要读 NavigatorState 私有 `_history`、帧统计等）在 Agent
// 实现里抛 [SessionApiUnsupported]，由工具层转成带能力键的报错。
library;

import '../scenario/expressions.dart';
import '../scenario/gestures.dart';
import '../scenario/inject.dart';
import '../scenario/vm_client.dart';
import 'agent_client.dart';
import 'agent_session_api.dart';

/// 当前通道做不到某个语义操作（能力键在 [cap] 里）。
class SessionApiUnsupported implements Exception {
  const SessionApiUnsupported(this.what, {this.cap = '', this.hint = ''});

  /// 用户可读的操作名（"路由栈" / "帧统计" …）。
  final String what;

  /// 相关能力键（`Cap` 常量，空 = 无对应能力）。
  final String cap;

  /// 替代方案提示。
  final String hint;

  @override
  String toString() =>
      '当前会话不支持$what${cap.isEmpty ? '' : '（需要 $cap 能力）'}'
      '${hint.isEmpty ? '' : '：$hint'}';
}

/// 会话语义接口：工具层与场景引擎只依赖它。
abstract class SessionApi {
  /// 会话 uri（ws:// 或 http://），报错与日志用。
  String get uri;

  /// 是否是 app 内直连通道。
  bool get isAgent;

  /// 原生 VM 客户端；直连会话为 null（调试协议面 / 实例计数等特例用）。
  VmClient? get vmClient;

  // -- 只读数据面 ---------------------------------------------------------

  /// 网络摘要：每行 `method\u0001url\u0001statusCode\u0001status\u0001durationMs\u0001time\u0001error`。
  Future<String> networkRaw({int? sinceMs, int limit = 50});

  /// 网络详情：每行 17 列（见 `networkDetailExpr` 注释）。
  Future<String> networkDetailRaw({
    String? id,
    String? urlContains,
    String? method,
    int maxChars = 2000,
    int limit = 1,
  });

  /// 应用日志：每行 `level\u0001tag\u0001message\u0001time`；`withPath` 时首行 `#path\u0001<文件>`。
  Future<String> consoleRaw({
    String? level,
    String? keyword,
    int? sinceMs,
    int limit = 50,
    int offset = 0,
    bool tail = true,
    int maxChars = 500,
    bool withPath = false,
  });

  /// 结构化异常：每行 13 列（见 `exceptionsExpr` 注释）。
  Future<String> exceptionsRaw({
    String? kind,
    String? typeContains,
    String? keyword,
    int? sinceMs,
    int limit = 20,
  });

  /// 时间轴：每行 `type\u0001ts\u0001iso\u0001...`（字段随类型不同）。
  Future<String> timelineRaw({int? sinceMs, int limit = 60});

  /// 路由栈（含 routeType / arguments 类型 / isPresent）。
  Future<String> routeStackRaw();

  /// 当前显示的命名路由（逗号拼接）；失败返回空列表。
  Future<List<String>> routeNames();

  /// 栈顶路由名（失败返回 null，不阻断主流程）。
  Future<String?> topRoute();

  /// 帧耗时统计：`count\u0001avgTotal\u0001avgBuild\u0001avgRaster\u0001jank`。
  Future<String> framesRaw();

  /// 网络记录（场景断言用）：method / url / statusCode / status。
  Future<List<Map<String, String>>> networkRecords({
    DateTime? since,
    int limit = 100,
  });

  // -- 组件树 -------------------------------------------------------------

  /// 按条件查组件（与 `findWidgetExpr` 同格式）。
  Future<String> findWidgetRaw({
    required String by,
    required String value,
    bool exact = false,
    int limit = 20,
  });

  /// 第 [ref] 个组件的中心点：`x,y`。
  Future<String> elementCenterRaw(int ref);

  /// 树中是否有可见的某类型组件：FOUND / NOT_FOUND / NO_ROOT。
  Future<String> assertVisibleRaw(String type);

  /// 整棵 Element 树快照（GUI Widget 树页结构）。
  Future<Map<String, Object?>> widgetTreeJson();

  /// 当前页面可见文本（`\u0002` 分隔）。
  Future<String> pageTextRaw({int limit = 200});

  // -- 动作 ---------------------------------------------------------------

  /// 点击第 [ref] 个组件。
  Future<String> tapRef(int ref, {int pointer = 0});

  /// 按坐标点击；[phys] 表示入参是物理像素。
  Future<String> tapAt(double x, double y, {bool phys = false, int pointer = 0});

  /// 向焦点输入框整体替换文本。
  Future<String> inputText(String text);

  /// 路由操作：op = pop / push；push 时 [name] 是命名路由。
  Future<String> routeOp(String op, {String name = ''});

  /// 滑动（逻辑坐标；[phys] 表示物理像素）。
  Future<(String, String)> swipe({
    required double x1,
    required double y1,
    required double x2,
    required double y2,
    int durationMs = 300,
    bool phys = false,
  });

  /// 屏幕逻辑尺寸（宽, 高, dpr）；读不到返回 null。
  Future<(double, double, double)?> screenInfo();

  // -- 画面 ---------------------------------------------------------------

  /// 整屏 PNG（base64）。
  Future<String> screenshotBase64();

  // -- 调试协议面（仅 VM） --------------------------------------------------

  /// 任意表达式求值（断点/调试/自定义场景步骤用）。
  Future<String> evalRaw(String lib, String expr);

  Future<void> close();
}

/// 按 uri 建对应的传输实现：`http://` 走 app 内直连，`ws://` 走 VM service。
SessionApi connectSessionApi(String uri, {String agentToken = ''}) {
  if (isAgentBaseUrl(uri)) {
    return AgentSessionApi(
      AgentClient(uri, token: agentToken),
      uri: uri,
    );
  }
  return VmSessionApi(VmClient(uri), uri: uri);
}

/// 方向滑动（按屏幕逻辑尺寸取起点/终点，两侧各留 12% 边距）：与旧
/// [swipeByDirection] 同算法，只是走 [SessionApi]。
Future<(String, String)> swipeByDirectionApi(
  SessionApi api,
  String direction, {
  double? distance,
  int durationMs = 300,
}) async {
  final info = await api.screenInfo();
  if (info == null) return ('', '无法读取屏幕尺寸（会话可能已断开）');
  final (w, h, _) = info;
  final dir = direction.toLowerCase();
  final vertical = dir == 'up' || dir == 'down';
  final maxLen = (vertical ? h : w) * 0.76;
  final len = (distance ?? maxLen).clamp(40, maxLen);
  final cx = w / 2;
  final cy = h / 2;
  double x1, y1, x2, y2;
  switch (dir) {
    case 'up':
      x1 = cx;
      y1 = cy + len / 2;
      x2 = cx;
      y2 = cy - len / 2;
    case 'down':
      x1 = cx;
      y1 = cy - len / 2;
      x2 = cx;
      y2 = cy + len / 2;
    case 'left':
      x1 = cx + len / 2;
      y1 = cy;
      x2 = cx - len / 2;
      y2 = cy;
    case 'right':
      x1 = cx - len / 2;
      y1 = cy;
      x2 = cx + len / 2;
      y2 = cy;
    default:
      return ('', '不支持的方向 $direction（up/down/left/right）');
  }
  return api.swipe(
    x1: x1,
    y1: y1,
    x2: x2,
    y2: y2,
    durationMs: durationMs,
  );
}

/// VM service 通道实现：就是原来那些表达式，只是收进一层。
class VmSessionApi implements SessionApi {
  VmSessionApi(this._vm, {String? uri}) : uri = uri ?? _vm.uri;

  final VmClient _vm;

  @override
  final String uri;

  @override
  bool get isAgent => false;

  @override
  VmClient get vmClient => _vm;

  @override
  Future<String> networkRaw({int? sinceMs, int limit = 50}) =>
      _vm.evalStringOn(kLibXbUme, networkExpr(sinceMs: sinceMs, limit: limit));

  @override
  Future<String> networkDetailRaw({
    String? id,
    String? urlContains,
    String? method,
    int maxChars = 2000,
    int limit = 1,
  }) =>
      _vm.evalStringOn(
        kLibXbUme,
        networkDetailExpr(
          id: id,
          urlContains: urlContains,
          method: method,
          maxChars: maxChars,
          limit: limit,
        ),
      );

  @override
  Future<String> consoleRaw({
    String? level,
    String? keyword,
    int? sinceMs,
    int limit = 50,
    int offset = 0,
    bool tail = true,
    int maxChars = 500,
    bool withPath = false,
  }) =>
      _vm.evalStringOn(
        kLibXbUme,
        consoleExpr(
          level: level,
          keyword: keyword,
          sinceMs: sinceMs,
          limit: limit,
          offset: offset,
          tail: tail,
          maxChars: maxChars,
          withPath: withPath,
        ),
      );

  @override
  Future<String> exceptionsRaw({
    String? kind,
    String? typeContains,
    String? keyword,
    int? sinceMs,
    int limit = 20,
  }) =>
      _vm.evalStringOn(
        kLibXbUme,
        exceptionsExpr(
          kind: kind,
          typeContains: typeContains,
          keyword: keyword,
          sinceMs: sinceMs,
          limit: limit,
        ),
      );

  @override
  Future<String> timelineRaw({int? sinceMs, int limit = 60}) =>
      _vm.evalStringOn(kLibXbUme, timelineExpr(sinceMs: sinceMs, limit: limit));

  @override
  Future<String> routeStackRaw() =>
      _vm.evalStringOn(kLibNavigator, routeStackExpr);

  @override
  Future<List<String>> routeNames() async {
    try {
      final s = await _vm.evalStringOn(kLibNavigator, routesExpr);
      if (s == 'NO_ROOT' || s == 'NO_NAV') return const <String>[];
      return s.split(',').where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return const <String>[];
    }
  }

  @override
  Future<String?> topRoute() async {
    final names = await routeNames();
    return names.isEmpty ? null : names.last;
  }

  @override
  Future<String> framesRaw() => _vm.evalStringOn(kLibXbUme, framesExpr);

  @override
  Future<List<Map<String, String>>> networkRecords({
    DateTime? since,
    int limit = 100,
  }) async {
    final raw = await networkRaw(
      sinceMs: since?.millisecondsSinceEpoch,
      limit: limit,
    );
    final out = <Map<String, String>>[];
    for (final row in raw.split('\u0003')) {
      if (row.isEmpty) continue;
      final f = row.split('\u0001');
      if (f.length < 5) continue;
      out.add(<String, String>{
        'method': f[0],
        'url': f[1],
        'statusCode': f[2],
        'status': f[3],
      });
    }
    return out;
  }

  @override
  Future<String> findWidgetRaw({
    required String by,
    required String value,
    bool exact = false,
    int limit = 20,
  }) =>
      _vm.evalStringOn(
        kLibBinding,
        findWidgetExpr(by: by, value: value, exact: exact, limit: limit),
      );

  @override
  Future<String> elementCenterRaw(int ref) =>
      _vm.evalStringOn(kLibBinding, elementCenterExpr(ref));

  @override
  Future<String> assertVisibleRaw(String type) =>
      _vm.evalStringOn(kLibBinding, assertVisibleExpr(type));

  @override
  Future<Map<String, Object?>> widgetTreeJson() async {
    final s = (await _vm.evalStringOn(kLibBinding, wtreeExpr)).trim();
    if (s == 'NO_ROOT') {
      return <String, Object?>{'ok': false, 'error': 'app 无渲染树（尚未运行首帧）'};
    }
    final parts = s.split('\u0003');
    // 末尾空段 + 元信息（dpr\u0001物理宽\u0001物理高）。
    final meta = parts.length >= 2 ? parts[parts.length - 1].split('\u0001') : <String>[];
    final rows = parts.length >= 2 ? parts.sublist(0, parts.length - 2) : const <String>[];
    final nodes = <Map<String, Object?>>[];
    for (final r in rows) {
      final f = r.split('\u0001');
      if (f.length < 4) continue;
      final depth = int.tryParse(f[0]);
      if (depth == null) continue;
      final bs = f[3].split(',');
      nodes.add(<String, Object?>{
        'd': depth,
        't': f[1],
        'k': f[2],
        'b': f[3].isEmpty
            ? null
            : <int>[
                int.tryParse(bs[0]) ?? 0,
                int.tryParse(bs[1]) ?? 0,
                int.tryParse(bs[2]) ?? 0,
                int.tryParse(bs[3]) ?? 0,
              ],
      });
    }
    return <String, Object?>{
      'ok': true,
      'nodes': nodes,
      'dpr': double.tryParse(meta.isNotEmpty ? meta[0] : '1') ?? 1,
      'physW': int.tryParse(meta.length > 1 ? meta[1] : '0') ?? 0,
      'physH': int.tryParse(meta.length > 2 ? meta[2] : '0') ?? 0,
    };
  }

  @override
  Future<String> pageTextRaw({int limit = 200}) =>
      _vm.evalStringOn(kLibBinding, pageTextExpr(limit: limit));

  @override
  Future<String> tapRef(int ref, {int pointer = 0}) =>
      evalInject(_vm, kLibBinding, tapElementExpr(ref, pointer: pointer));

  @override
  Future<String> tapAt(double x, double y, {bool phys = false, int pointer = 0}) =>
      evalInject(
        _vm,
        kLibBinding,
        tapExpr(x.toString(), y.toString(), phys: phys, pointer: pointer),
      );

  @override
  Future<String> inputText(String text) =>
      _vm.evalStringOn(kLibTextInput, inputExpr(text));

  @override
  Future<String> routeOp(String op, {String name = ''}) =>
      evalInject(_vm, kLibNavigator, routeOpExpr(op, name: name));

  @override
  Future<(String, String)> swipe({
    required double x1,
    required double y1,
    required double x2,
    required double y2,
    int durationMs = 300,
    bool phys = false,
  }) =>
      swipeSequence(_vm,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          durationMs: durationMs,
          phys: phys);

  @override
  Future<(double, double, double)?> screenInfo() => screenInfoOf(_vm);

  @override
  Future<String> screenshotBase64() => _vm.screenshotBase64();

  @override
  Future<String> evalRaw(String lib, String expr) => _vm.evalStringOn(lib, expr);

  @override
  Future<void> close() async {
    await _vm.close();
  }
}

/// 读取屏幕逻辑尺寸（VM 实现，保留给需要直接注入的旧代码路径）。
Future<(double, double, double)?> screenInfoOf(VmClient vm) async {
  try {
    final s = await vm.evalStringOn(kLibBinding, screenInfoExpr);
    final p = s.split('\u0001');
    if (p.length < 3) return null;
    final dpr = double.tryParse(p[0]) ?? 1;
    final w = double.tryParse(p[1]);
    final h = double.tryParse(p[2]);
    if (w == null || h == null) return null;
    return (w, h, dpr);
  } catch (_) {
    return null;
  }
}