// 工具箱侧的能力：时间轴控制、网络重放、异常归因、自动化场景、AI 驱动。
//
// 这些功能的「状态」都长在工具箱进程里（时间轴订阅是 GUI 的定时器、网络重放
// 用 GUI 的 HttpClient 与凭据剥离规则、异常归因要 GUI 里配的模型、自动化与 AI
// 任务是 GUI 的执行状态机），所以在 MCP 里只做转发，不复制实现。
library;

import 'dart:convert';
import 'dart:io';

import '../paths.dart';
import 'gui_bridge.dart';
import 'protocol.dart';
import 'tools.dart';

List<McpTool> toolboxTools() => <McpTool>[
      _timelineControlTool(),
      _logHistoryTool(),
      _networkControlTool(),
      _exceptionsTool(),
      _automationTool(),
      _aiTool(),
    ];

Map<String, Object?> _schema(
  Map<String, Object?> properties, [
  List<String>? required,
]) =>
    toolSchema(properties, required);

McpTool _timelineControlTool() => McpTool(
      name: 'xbume_timeline_control',
      title: '时间轴开关与清空（GUI 侧订阅）',
      description: '工具箱「时间轴」页那套订阅：sub 开始订阅一个会话（路由 / 网络事件实时流入）、'
          'off 停止、clear 清空、list 看当前订阅与已收事件。和 xbume_timeline 的区别：'
          '那个是 app 侧缓冲的一次性快照，这个是工具箱持续累积的实时流，适合'
          '「先 sub，再做操作，再 list 看这期间发生了什么」。',
      group: ToolGroup.env,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['list', 'sub', 'off', 'clear'], defaultValue: 'list'),
        'sessionId': prop('string', '会话 id（省略用当前会话；sub 用）'),
        'uri': prop('string', 'VM service 地址（一般不用传，按会话自动取）'),
        'limit': prop('integer', 'list 最多返回多少条（默认 60）', defaultValue: 60),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'list').trim();
        if (action == 'off' || action == 'clear') {
          final j = await _gui(ctx, '/api/timeline/$action', method: 'POST');
          return McpToolResult.text(
            action == 'off' ? '已停止时间轴订阅' : '已清空时间轴事件',
            structured: j,
          );
        }
        if (action == 'sub') {
          final uri = await _uriOrSession(ctx, args);
          final j = await _gui(ctx, '/api/timeline/sub', method: 'POST',
              rawBody: jsonEncode(<String, Object?>{'uri': uri}));
          if (j['ok'] == false) {
            throw McpToolException('订阅失败：${j['error'] ?? '未知原因'}',
                hint: '确认会话还活着；release 包没有 VM service');
          }
          return McpToolResult.text(
            '已开始订阅 $uri（后续事件用 action=list 取）',
            structured: j,
          );
        }
        if (action != 'list') {
          throw McpToolException('未知 action：$action',
              hint: '可用：list / sub / off / clear');
        }
        final j = await _gui(ctx, '/api/timeline');
        final items = (j['items'] as List? ?? const <Object?>[]);
        final limit = (optionalInt(args, 'limit') ?? 60).clamp(1, 500);
        final tail = items.length > limit
            ? items.sublist(items.length - limit)
            : items;
        final lines = <String>[
          for (final e in tail)
            e is Map
                ? '${e['time'] ?? e['t'] ?? ''} ${e['kind'] ?? e['type'] ?? ''} '
                    '${e['name'] ?? e['url'] ?? e['message'] ?? ''}'
                : '$e',
        ];
        return McpToolResult.text(
          '订阅：${(j['uri'] ?? '').toString().isEmpty ? '未订阅' : j['uri']} · '
          '${items.length} 条\n${lines.join('\n')}',
          structured: <String, Object?>{
            'uri': j['uri'],
            'count': items.length,
            'items': tail,
          },
        );
      },
    );

McpTool _logHistoryTool() => McpTool(
      name: 'xbume_log_history',
      title: 'GUI 日志历史（设备日志 + flutter 输出）',
      description: '读工具箱一直在采集的日志历史：设备 logcat / hilog / iOS log 与所有调试会话的 '
          'stdout/stderr 混在同一份缓冲里（每来源 1000 条、总量 5000 条）。支持 source / keyword / '
          '时间窗过滤与两个游标：nextOffset 翻页读完、nextSinceMs 增量跟（传回 sinceMs，不重不漏）。'
          '和 xbume_device_logs 的区别：那个是「现在抓一次设备快照」，这个是 GUI 累积的历史，'
          '含 iOS 真机拿不到的历史日志；需要工具箱在跑。',
      group: ToolGroup.env,
      inputSchema: _schema(<String, Object?>{
        'keyword': prop('string', '消息或 tag 包含该关键字（忽略大小写）'),
        'source': prop('string',
            '来源精确匹配：flutter / logcat / hilog / ios …（返回里的 sources 就是候选）'),
        'sinceMs': prop('integer', '只看收到时间 >= 该毫秒时间戳的行（传上一轮的 nextSinceMs）'),
        'offset': prop('integer', '逻辑起始下标（配 tail=false 翻页，默认 0）',
            defaultValue: 0),
        'limit': prop('integer', '本次最多多少条（默认 200，上限 1000）',
            defaultValue: 200),
        'tail': prop('boolean',
            'offset<=0 时取末尾 limit 条（默认 true）；false 则从 offset 往后',
            defaultValue: true),
        'maxChars': prop('integer', '单条消息最多多少字符（默认 400）',
            defaultValue: 400),
      }),
      handler: (ctx, args) async {
        final q = <String, Object?>{};
        final keyword = optionalString(args, 'keyword');
        if (keyword != null && keyword.trim().isNotEmpty) {
          q['keyword'] = keyword.trim();
        }
        final source = optionalString(args, 'source');
        if (source != null && source.trim().isNotEmpty) {
          q['source'] = source.trim();
        }
        final sinceMs = optionalInt(args, 'sinceMs');
        if (sinceMs != null) q['sinceMs'] = sinceMs;
        q['offset'] = (optionalInt(args, 'offset') ?? 0).clamp(0, 1000000);
        q['limit'] = (optionalInt(args, 'limit') ?? 200).clamp(1, 1000);
        q['tail'] = optionalBool(args, 'tail', fallback: true) ? '1' : '0';
        q['maxChars'] = (optionalInt(args, 'maxChars') ?? 400).clamp(40, 4000);

        final j = await _gui(ctx, '/api/logs', q: q);
        final items = (j['items'] as List?) ?? const <Object?>[];
        final total = j['total'] ?? 0;
        final nextOffset = j['nextOffset'] ?? 0;
        final hasMore = j['hasMore'] == true;
        final sources = ((j['sources'] as List?) ?? const <Object?>[])
            .map((e) => '$e')
            .join(' / ');
        final head = '日志历史 · 命中 $total 条 · 返回 ${items.length} 条 · '
            'nextOffset=$nextOffset · nextSinceMs=${j['nextSinceMs']}'
            '${hasMore ? ' · 还有更多（继续传 offset=$nextOffset）' : ''}'
            '${sources.isEmpty ? '' : '\n可用来源：$sources'}';
        if (items.isEmpty) {
          return McpToolResult.text('$head\n没有匹配的日志（工具箱没在跑或还没采到）。',
              structured: <String, Object?>{'ok': true, ...j});
        }
        final buf = StringBuffer(head);
        for (final raw in items) {
          final e = raw is Map ? raw : const <String, Object?>{};
          buf.write('\n${e['ts'] ?? ''} [${e['source'] ?? ''}] '
              '${e['level'] ?? ''}/${e['tag'] ?? ''}: ${e['msg'] ?? ''}');
        }
        return McpToolResult.text(buf.toString(),
            structured: <String, Object?>{'ok': true, ...j});
      },
    );

McpTool _networkControlTool() => McpTool(
      name: 'xbume_network_control',
      title: '网络重放 / 清空',
      description: 'replay：按 xbume_network 里的 id 重放一次请求（可改 url / headers / body，'
          '跨 host 时自动剥离原请求的凭据头），返回状态码、响应头与响应体；'
          'clear：清空 app 内网络记录。适合「改个参数再打一次」或验证后端修复。',
      group: ToolGroup.env,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作', enumValues: <String>['replay', 'clear'],
            defaultValue: 'replay'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'uri': prop('string', 'VM service 地址（一般不用传，按会话自动取）'),
        'id': prop('string', 'replay：xbume_network 返回的记录 id'),
        'url': prop('string', 'replay：改成这个 URL（省略用原 URL）'),
        'headers': prop('object', 'replay：完整替换请求头（省略用原请求头）'),
        'body': prop('string', 'replay：改成这个请求体（省略用原请求体）'),
        'maxBody': prop('integer', 'replay：响应体最多显示多少字符（默认 4000）',
            defaultValue: 4000),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'replay').trim();
        final uri = await _uriOrSession(ctx, args);
        if (action == 'clear') {
          final j = await _gui(ctx, '/api/network/clear',
              method: 'POST', q: <String, Object?>{'uri': uri});
          return McpToolResult.text('已清空 app 内的网络记录', structured: j);
        }
        if (action != 'replay') {
          throw McpToolException('未知 action：$action', hint: '可用：replay / clear');
        }
        final id = requireString(args, 'id',
            hint: '先 xbume_network 找到目标请求的 id');
        final edit = <String, Object?>{
          if (optionalString(args, 'url') != null) 'url': optionalString(args, 'url'),
          if (args['headers'] is Map) 'headers': args['headers'],
          if (optionalString(args, 'body') != null) 'body': optionalString(args, 'body'),
        };
        final j = await _gui(
          ctx,
          '/api/network/replay',
          method: 'POST',
          q: <String, Object?>{'uri': uri, 'id': id},
          rawBody: edit.isEmpty ? null : jsonEncode(edit),
        );
        final body = '${j['body'] ?? ''}';
        final max = (optionalInt(args, 'maxBody') ?? 4000).clamp(200, 200000);
        final headers = j['headers'];
        return McpToolResult.text(
          '${j['statusCode'] ?? '?'} · ${j['url'] ?? ''}\n'
          '${headers is Map ? '${headers.entries.take(12).map((e) => '${e.key}: ${e.value}').join('\n')}\n' : ''}'
          '${body.length > max ? '${body.substring(0, max)}…' : body}',
          structured: j,
        );
      },
    );

McpTool _exceptionsTool() => McpTool(
      name: 'xbume_exceptions_hub',
      title: '异常汇总（跨会话）/ AI 归因',
      description: 'list：工具箱汇总的异常（Extension 流结构化事件 + 输出流未捕获块，'
          '保留栈帧、相关 widget、触发时的路由/网络/日志）；clear：清空；'
          'analyze：把某条异常的栈帧源码与上下文发给工具箱里配置的模型，回根因与'
          '修复建议（需先在 GUI「AI 设置」里配好接口）。',
      group: ToolGroup.env,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['list', 'clear', 'analyze'], defaultValue: 'list'),
        'id': prop('integer', 'analyze：异常 id（list 返回的 id）'),
        'sessionId': prop('string', '会话 id（analyze 可选，用它的 ws 地址）'),
        'uri': prop('string', 'VM service 地址（analyze 可选）'),
        'limit': prop('integer', 'list 最多返回多少条（默认 10）', defaultValue: 10),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'list').trim();
        if (action == 'clear') {
          final j = await _gui(ctx, '/api/exceptions/clear', method: 'POST');
          return McpToolResult.text('已清空异常缓冲', structured: j);
        }
        if (action == 'analyze') {
          final id = optionalInt(args, 'id');
          if (id == null) {
            throw McpToolException('analyze 需要 id',
                hint: '先 action=list 看异常，再传它的 id');
          }
          String uri = optionalString(args, 'uri') ?? '';
          if (uri.isEmpty) {
            try {
              uri = await _uriOrSession(ctx, args);
            } catch (_) {
              // 允许只靠异常记录里带的 wsUri 归因。
            }
          }
          final j = await _gui(
            ctx,
            '/api/exc/analyze',
            method: 'POST',
            rawBody: jsonEncode(<String, Object?>{'id': id, 'uri': uri}),
          );
          if (j['ok'] == false) {
            throw McpToolException('AI 归因失败：${j['error'] ?? '未知原因'}',
                hint: '先在工具箱「AI 设置」里配置接口地址、密钥与模型');
          }
          return McpToolResult.text('${j['analysis'] ?? ''}',
              structured: j);
        }
        if (action != 'list') {
          throw McpToolException('未知 action：$action',
              hint: '可用：list / clear / analyze');
        }
        final j = await _gui(ctx, '/api/exceptions');
        final items = (j['items'] as List? ?? const <Object?>[]);
        final limit = (optionalInt(args, 'limit') ?? 10).clamp(1, 200);
        final tail = items.length > limit
            ? items.sublist(items.length - limit)
            : items;
        final lines = <String>[
          for (final e in tail)
            e is Map
                ? '#${e['id']} ${e['time'] ?? ''} ${e['kind'] ?? ''} '
                    '${e['type'] ?? e['summary'] ?? ''}'
                    '${e['count'] == null ? '' : ' ×${e['count']}'}'
                : '$e',
        ];
        return McpToolResult.text(
          '${items.length} 条异常\n${lines.join('\n')}',
          structured: <String, Object?>{
            'count': items.length,
            'items': tail,
          },
        );
      },
    );

McpTool _automationTool() => McpTool(
      name: 'xbume_automation',
      title: '自动化场景（存取 / 执行 / 进度 / 截图）',
      description: '工具箱「自动化」页那套场景（与 xbume_scenario_* 的保存目录不同）：'
          'list 列已保存场景、get 取步骤、save 存、delete 删、run 执行（传 name 或 '
          'steps）、status 看进度与结果、stop 停、artifact 取某步截图。'
          '录制由 GUI 截图页完成，MCP 侧直接用 steps 跑。',
      group: ToolGroup.env,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['list', 'get', 'save', 'delete', 'run', 'status',
              'stop', 'artifact'],
            defaultValue: 'list'),
        'sessionId': prop('string', '会话 id（run 省略用当前会话）'),
        'uri': prop('string', 'VM service 地址（run 省略时按会话取）'),
        'name': prop('string', '场景名（get/save/delete/run 用）'),
        'steps': prop('array', 'save / run：步骤数组'),
        'continueOnFail': prop('boolean', 'run：失败后继续（默认 false）',
            defaultValue: false),
        'file': prop('string', 'artifact：截图文件名（status 结果里的 shot）'),
        'saveTo': prop('string', 'artifact：保存到本机的路径（默认 \$XB_UME_HOME/downloads）'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'list').trim();
        if (action == 'list') {
          final j = await _gui(ctx, '/api/auto/list');
          final items = (j['items'] as List? ?? const <Object?>[]);
          final lines = <String>[
            for (final e in items)
              e is Map
                  ? '· ${e['name']}（${e['steps']} 步 · ${e['mtime'] ?? ''}）'
                  : '$e',
          ];
          return McpToolResult.text(
            '${items.length} 个场景\n${lines.join('\n')}',
            structured: j,
          );
        }
        if (action == 'status') {
          final j = await _gui(ctx, '/api/auto/status');
          return McpToolResult.text(_brief(j, 1800), structured: j);
        }
        if (action == 'stop') {
          final j = await _gui(ctx, '/api/auto/stop', method: 'POST');
          return McpToolResult.text('已请求停止自动化任务', structured: j);
        }
        if (action == 'get' || action == 'delete') {
          final name = requireString(args, 'name', hint: '先 action=list 看场景名');
          final j = await _gui(ctx, '/api/auto/$action',
              q: <String, Object?>{'name': name});
          if (j['ok'] == false) {
            throw McpToolException('${j['error'] ?? '操作失败'}');
          }
          if (action == 'delete') {
            return McpToolResult.text('已删除场景 $name', structured: j);
          }
          final steps = j['steps'];
          return McpToolResult.text(
            '$name：${steps is List ? steps.length : 0} 步\n${_brief(j, 2000)}',
            structured: j,
          );
        }
        if (action == 'save') {
          final name = requireString(args, 'name', hint: '场景名（不能带路径分隔符）');
          final steps = args['steps'];
          if (steps is! List || steps.isEmpty) {
            throw McpToolException('save 需要 steps 数组',
                hint: '步骤格式与 xbume_scenario_run 一致');
          }
          final j = await _gui(ctx, '/api/auto/save',
              method: 'POST',
              rawBody: jsonEncode(<String, Object?>{'name': name, 'steps': steps}));
          if (j['ok'] == false) {
            throw McpToolException('保存失败：${j['error'] ?? '未知原因'}');
          }
          return McpToolResult.text('已保存场景 $name（${steps.length} 步）',
              structured: j);
        }
        if (action == 'artifact') {
          final f = requireString(args, 'file', hint: 'status 结果里的 shot 文件名');
          final bytes = await _guiBytes(ctx, '/api/auto/artifact',
              q: <String, Object?>{'f': f});
          final save = optionalString(args, 'saveTo') ??
              '${xbUmeHome()}/downloads/${DateTime.now().millisecondsSinceEpoch}_$f';
          final out = File(save);
          out.parent.createSync(recursive: true);
          out.writeAsBytesSync(bytes);
          return McpToolResult.text(
            '已保存 ${bytes.length} 字节 → ${out.path}',
            structured: <String, Object?>{
              'ok': true,
              'path': out.path,
              'bytes': bytes.length,
            },
          );
        }
        if (action != 'run') {
          throw McpToolException('未知 action：$action',
              hint: '可用：list / get / save / delete / run / status / stop / artifact');
        }
        final uri = await _uriOrSession(ctx, args);
        final name = optionalString(args, 'name') ?? '';
        final steps = args['steps'];
        if ((name.isEmpty) && (steps is! List || steps.isEmpty)) {
          throw McpToolException('run 需要 name 或 steps',
              hint: '先用 action=list 看已保存场景');
        }
        final j = await _gui(
          ctx,
          '/api/auto/run',
          method: 'POST',
          q: <String, Object?>{
            'uri': uri,
            'name': name,
            'continue': optionalBool(args, 'continueOnFail') ? '1' : '0',
          },
          rawBody: steps is List && steps.isNotEmpty
              ? jsonEncode(<String, Object?>{'name': name, 'steps': steps})
              : null,
        );
        if (j['ok'] == false) {
          throw McpToolException('启动失败：${j['error'] ?? '未知原因'}',
              hint: '已有场景或对比在执行时会冲突，先看 action=status');
        }
        return McpToolResult.text(
          '已开始执行${name.isEmpty ? '' : ' $name'}（${j['total'] ?? '?'} 步），'
          '用 action=status 查进度',
          structured: j,
        );
      },
    );

McpTool _aiTool() => McpTool(
      name: 'xbume_ai',
      title: 'AI 驱动（自然语言目标 → 自动操作）',
      description: '工具箱「AI」页：status 看当前任务与进度；run 给一个自然语言目标，'
          '模型看截图决定下一步并执行（需要先在 GUI「AI 设置」配好接口）；'
          'stop 停；goals 看历史目标；report 导出上次运行报告；config 看配置。'
          '注意：它会真的操作 app，只在确认要做端到端验证时用。',
      group: ToolGroup.ai,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['status', 'run', 'stop', 'goals', 'report', 'config'],
            defaultValue: 'status'),
        'goal': prop('string', 'run：自然语言目标，例如「登录后进入设置页并截图」'),
        'sessionId': prop('string', 'run：会话 id（省略用当前会话）'),
        'uri': prop('string', 'run：VM service 地址（一般不用传）'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'status').trim();
        switch (action) {
          case 'status':
            final j = await _gui(ctx, '/api/ai/status');
            return McpToolResult.text(_brief(j, 1600), structured: j);
          case 'config':
            final j = await _gui(ctx, '/api/ai/config');
            return McpToolResult.text(_brief(j, 800), structured: j);
          case 'goals':
            final j = await _gui(ctx, '/api/ai/goals');
            final items = (j['items'] as List? ?? const <Object?>[]);
            return McpToolResult.text(
              '${items.length} 个历史目标\n${items.take(30).join('\n')}',
              structured: j,
            );
          case 'report':
            final text = await _guiText(ctx, '/api/ai/report');
            final save = '${xbUmeHome()}/downloads/'
                'ai_report_${DateTime.now().millisecondsSinceEpoch}.md';
            final out = File(save);
            out.parent.createSync(recursive: true);
            out.writeAsStringSync(text);
            return McpToolResult.text(
              '报告 ${text.length} 字符 → ${out.path}',
              structured: <String, Object?>{
                'ok': true,
                'path': out.path,
                'chars': text.length,
                'preview': text.length > 2000 ? text.substring(0, 2000) : text,
              },
            );
          case 'stop':
            final j = await _gui(ctx, '/api/ai/stop', method: 'POST');
            return McpToolResult.text('已请求停止 AI 任务', structured: j);
          case 'run':
            final goal = requireString(args, 'goal', hint: '例如「打开设置页并切换深色模式」');
            final uri = await _uriOrSession(ctx, args);
            final j = await _gui(ctx, '/api/ai/run',
                method: 'POST', q: <String, Object?>{'uri': uri, 'goal': goal});
            if (j['ok'] == false) {
              throw McpToolException('启动失败：${j['error'] ?? '未知原因'}',
                  hint: '先在工具箱「AI 设置」配置接口；已有任务在执行时也会冲突');
            }
            return McpToolResult.text(
              '已开始执行目标，用 action=status 看进度（完成后可 action=report 导出报告）',
              structured: j,
            );
          default:
            throw McpToolException('未知 action：$action',
                hint: '可用：status / run / stop / goals / report / config');
        }
      },
    );

// ── 公共辅助（与 bridge_tools.dart 同语义，避免跨文件互相引用私有函数） ──

Future<String> _uriOrSession(McpToolContext ctx, Map<String, Object?> args) async {
  final raw = optionalString(args, 'uri');
  if (raw != null && raw.trim().isNotEmpty) return raw.trim();
  final s = await resolveSession(ctx, args);
  return s.wsUrl;
}

Future<Map<String, Object?>> _gui(
  McpToolContext ctx,
  String path, {
  Map<String, Object?> q = const <String, Object?>{},
  String method = 'GET',
  String? rawBody,
}) async {
  try {
    return await ctx.guiBridge.json(
      path,
      params: q,
      method: method,
      rawBody: rawBody,
    );
  } on GuiBridgeError catch (e) {
    throw McpToolException(e.message, hint: e.hint);
  }
}

Future<String> _guiText(McpToolContext ctx, String path) async {
  try {
    return await ctx.guiBridge.text(path);
  } on GuiBridgeError catch (e) {
    throw McpToolException(e.message, hint: e.hint);
  }
}

Future<List<int>> _guiBytes(
  McpToolContext ctx,
  String path, {
  Map<String, Object?> q = const <String, Object?>{},
}) async {
  try {
    return await ctx.guiBridge.bytes(path, params: q);
  } on GuiBridgeError catch (e) {
    throw McpToolException(e.message, hint: e.hint);
  }
}

String _brief(Map<String, Object?> j, [int max = 600]) {
  final s = jsonEncode(j);
  return s.length <= max ? s : '${s.substring(0, max)}…';
}
