// 调试器工具组：把 GUI「调试」页那套能力交给 AI。
//
// 能力来自 DebugSessionPool → DebugHub（同一个实现，两处入口）：断点增删改查与
// 条件/日志断点、一键启停、已记住清单、暂停/继续/三种单步、调用栈、帧变量与
// 对象展开、帧内求值、运行输出、源码面板。MCP 不重写这些逻辑，避免 GUI 与 AI
// 对同一个 VM 给出两套行为。
library;

import 'dart:io';

import '../debug/debug_hub.dart';
import '../debug/source_view.dart';
import 'protocol.dart';
import 'tools.dart';

/// 断点动作：与 DebugHub 的 op 一一对应，少一层命名翻译。
const Map<String, String> _bpOps = <String, String>{
  'add': 'addBreakpoint',
  'remove': 'removeBreakpoint',
  'update': 'updateBreakpoint',
  'toggle': 'toggleBreakpoint',
  'toggleAll': 'toggleAllBreakpoints',
  'list': 'listBreakpoints',
  'saved': 'saved',
  'savedAll': 'savedAll',
  'remember': 'rememberBreakpoint',
  'forget': 'forgetBreakpoint',
  'forgetSaved': 'forgetSaved',
  'enableSaved': 'enableSavedBreakpoint',
};

List<McpTool> debugTools() => <McpTool>[
      _attachTool(),
      _stateTool(),
      _breakpointsTool(),
      _controlTool(),
      _inspectTool(),
      _outputTool(),
    ];

Map<String, Object?> _schema(
  Map<String, Object?> properties, [
  List<String>? required,
]) =>
    toolSchema(properties, required);

McpTool _attachTool() => McpTool(
      name: 'xbume_debug_attach',
      title: '接入调试会话（打断点 / 单步 / 看栈）',
      description: '把当前会话接到调试器上，之后可打断点、暂停/继续/单步、看调用栈与变量、'
          '读运行输出。接的是 VM service 地址，所以 IDE / GUI / MCP 起的会话都能接；'
          'MCP 自己的连接与工具箱里的调试页互不影响（断点各管各的）。'
          '重复调用不会重建连接（暂停现场不会丢）。',
      group: ToolGroup.debug,
      inputSchema: _schema(<String, Object?>{
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'projectRoot': prop('string',
            '项目根（断点落盘 / 相对路径按它解析；省略时从 flutter run 运行清单自动认领）'),
      }),
      handler: (ctx, args) async {
        final s = await resolveSession(ctx, args);
        final root = optionalString(args, 'projectRoot');
        final hub = await ctx.debugPool.attach(s, projectRoot: root);
        final st = await _op(hub, 'status');
        final bps = st['breakpoints'];
        final root2 = st['projectRoot'] ?? st['cwd'];
        return McpToolResult.text(
          '${_summary(st)}\n'
          '${bps is List && bps.isNotEmpty ? '断点：${_bpLines(bps)}' : '断点：无'}',
          structured: <String, Object?>{
            'ok': true,
            'sessionId': s.id,
            'projectRoot': root2,
            'paused': st['paused'],
            'breakpoints': bps,
          },
        );
      },
    );

McpTool _stateTool() => McpTool(
      name: 'xbume_debug_state',
      title: '看调试状态（停在哪 / 断点 / 输出）',
      description: '返回当前调试状态：是否暂停、暂停在哪个文件哪一行、命中原因、断点清单、'
          '最近运行输出（withOutput 时）。用来回答「现在停在哪」「断点生效了吗」。',
      group: ToolGroup.debug,
      inputSchema: _schema(<String, Object?>{
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'withOutput': prop('boolean', '是否带上最近运行输出（默认 false）',
            defaultValue: false),
        'outputLines': prop('integer', '带输出时最多几行（默认 40）',
            defaultValue: 40),
      }),
      handler: (ctx, args) async {
        final s = await resolveSession(ctx, args);
        final hub = await ctx.debugPool.attach(s);
        final st = await _op(hub, 'status');
        final withOutput = optionalBool(args, 'withOutput');
        final tail = withOutput
            ? _tailLines(st['output'], optionalInt(args, 'outputLines') ?? 40)
            : const <String>[];
        final pause = st['pause'];
        final top = pause is Map ? pause['topFrame'] : null;
        return McpToolResult.text(
          <String>[
            _summary(st),
            if (top is Map)
              '当前位置：${_frameLoc(top)}'
                  '${top['function'] == null ? '' : ' · ${top['function']}'}',
            ..._bpLines(st['breakpoints']),
            if (tail.isNotEmpty) ...[
              '— 运行输出（尾部 ${tail.length} 行）—',
              ...tail,
            ],
          ].join('\n'),
          structured: <String, Object?>{
            'ok': true,
            'sessionId': s.id,
            'paused': st['paused'] == true,
            'pause': pause,
            'breakpoints': st['breakpoints'],
            'projectRoot': st['projectRoot'] ?? st['cwd'],
            'output': tail,
          },
        );
      },
    );

McpTool _breakpointsTool() => McpTool(
      name: 'xbume_debug_breakpoints',
      title: '断点管理（加 / 删 / 改 / 停用 / 记住）',
      description: '一个工具覆盖断点全部操作：add（路径+行号，可带 condition / logMessage）、'
          'remove、update（改条件或日志表达式）、toggle（单条启停）、toggleAll（一键启停全部）、'
          'list、saved（当前项目记住的）、savedAll（所有项目）、remember / forget / enableSaved'
          '（落盘清单，没连会话也能改）、forgetSaved（清空当前项目）。'
          'logMessage 是日志断点：命中只打印不暂停。路径相对项目根或绝对路径均可。',
      group: ToolGroup.debug,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: _bpOps.keys.toList(), defaultValue: 'list'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'path': prop('string', '源码路径（相对项目根或绝对路径）'),
        'line': prop('integer', '行号'),
        'column': prop('integer', '列号（可空）'),
        'condition': prop('string', '条件表达式：为 false 时不停（可空，传空字符串=清空）'),
        'logMessage': prop('string', '日志表达式：命中只打印不暂停（可空，传空字符串=清空）'),
        'id': prop('string', '断点 id（remove / update / toggle 用）'),
        'enabled': prop('boolean', 'true 启用 / false 停用（toggle / toggleAll / enableSaved 用）'),
        'dir': prop('string', '项目根（saved / forgetSaved 用；省略用当前会话的项目根）'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'list').trim();
        final op = _bpOps[action];
        if (op == null) {
          throw McpToolException(
            '未知 action：$action',
            hint: '可用：${_bpOps.keys.join(' / ')}',
          );
        }
        final s = await resolveSession(ctx, args);
        final hub = await ctx.debugPool.attach(s);
        final st = await _op(hub, 'status');
        var root = optionalString(args, 'dir') ??
            (st['projectRoot'] ?? st['cwd'])?.toString();
        final a = <String, Object?>{};
        void put(String key, Object? v) {
          if (v != null) a[key] = v;
        }

        // AI 天然按「文件:行」想事：remove / update / toggle 不逼它先查 id。
        String idOf(String what) {
          final given = optionalString(args, 'id');
          if (given != null && given.isNotEmpty) return given;
          final path = optionalString(args, 'path');
          final line = optionalInt(args, 'line');
          if (path == null || path.isEmpty || line == null) {
            throw McpToolException('$what 需要 id，或 path + line',
                hint: '先 action=list 看断点清单与 id');
          }
          final found = _bpIdFor(st['breakpoints'], path: path, line: line);
          if (found == null) {
            throw McpToolException('没有命中 $path:$line 的断点',
                hint: '先 action=list 看当前断点（路径按项目根解析）');
          }
          return found;
        }

        switch (action) {
          case 'add':
            put('path', requireString(args, 'path', hint: '例如 lib/main.dart'));
            put('line', _requireLine(args));
            put('column', optionalInt(args, 'column'));
            put('condition', optionalString(args, 'condition'));
            put('logMessage', optionalString(args, 'logMessage'));
          case 'remove':
            a['id'] = idOf('remove');
          case 'update':
            a['id'] = idOf('update');
            // 空字符串表示清空，所以这里不能用 put（null 才会跳过）。
            a['condition'] = optionalString(args, 'condition') ?? '';
            a['logMessage'] = optionalString(args, 'logMessage') ?? '';
          case 'toggle':
            a['id'] = idOf('toggle');
            put('enabled', optionalBoolOrNull(args, 'enabled'));
          case 'toggleAll':
            final v = optionalBoolOrNull(args, 'enabled');
            if (v == null) {
              throw McpToolException('toggleAll 需要 enabled（true / false）');
            }
            a['enabled'] = v;
          case 'remember':
          case 'enableSaved':
            put('path', requireString(args, 'path', hint: '例如 lib/main.dart'));
            put('line', _requireLine(args));
            put('column', optionalInt(args, 'column'));
            put('condition', optionalString(args, 'condition'));
            put('logMessage', optionalString(args, 'logMessage'));
            if (action == 'enableSaved') {
              final v = optionalBoolOrNull(args, 'enabled');
              if (v == null) {
                throw McpToolException('enableSaved 需要 enabled（true / false）');
              }
              a['enabled'] = v;
            }
          case 'forget':
            put('path', requireString(args, 'path', hint: '例如 lib/main.dart'));
            put('line', _requireLine(args));
          case 'saved':
          case 'forgetSaved':
            if (root == null || root.isEmpty) {
              throw McpToolException('缺少项目根 dir',
                  hint: '先 xbume_debug_attach（会从运行清单认领），或显式传 dir');
            }
            a['dir'] = root;
          case 'savedAll':
          case 'list':
            break;
        }
        final r = await _op(hub, op, a);
        // 再读一次状态：list / add / remove 之后都要给最新断点表，而不是操作前的快照。
        final latest = await _op(hub, 'status');
        final saved = r['saved'];
        final projects = r['projects'];
        final bps = r['breakpoints'] ?? latest['breakpoints'];
        // 只读动作不带上一次操作的提示语（hub 的 message 是粘滞的，会误导）。
        final readOnly = action == 'list' ||
            action == 'saved' ||
            action == 'savedAll' ||
            action == 'forgetSaved';
        final msg = readOnly ? null : r['message']?.toString();
        final lines = <String>[
          if (msg != null && msg.isNotEmpty) msg,
          if (bps is List) ..._bpLines(bps),
          if (saved is List) ..._savedLines(saved),
          if (projects is List)
            for (final p in projects.whereType<Map>())
              '· ${p['dir']}：${(p['items'] as List? ?? const <Object?>[]).length} 个',
        ];
        return McpToolResult.text(
          lines.isEmpty ? '没有断点' : lines.join('\n'),
          structured: <String, Object?>{
            'ok': true,
            'action': action,
            'changed': r['changed'],
            'count': r['count'] ?? (bps is List ? bps.length : null),
            'breakpoints': bps,
            'saved': saved,
            'projects': projects,
          },
        );
      },
    );

McpTool _controlTool() => McpTool(
      name: 'xbume_debug_control',
      title: '执行控制（暂停 / 继续 / 单步）',
      description: 'pause（请求暂停 app）、continue（继续）、stepOver（单步跳过）、'
          'stepInto（单步进入）、stepOut（单步跳出）、detach（只断开调试连接，app 继续跑）、'
          'hot（热重载，要求会话由本服务/GUI 拉起）、stop（按精确 PID 停掉 app）。'
          '单步要求当前处于暂停状态；继续之前建议先看 xbume_debug_state。',
      group: ToolGroup.debug,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>[
              'pause',
              'continue',
              'resume',
              'stepOver',
              'stepInto',
              'stepOut',
              'detach',
              'hot',
              'stop',
            ],
            defaultValue: 'continue'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'continue').trim();
        // resume 是 VM 里的叫法（也是 IDE 快捷键的叫法），归一成 continue。
        final step = action == 'resume' ? 'continue' : action;
        final s = await resolveSession(ctx, args);
        if (step == 'detach') {
          await ctx.debugPool.detach(s.id);
          return McpToolResult.text('已断开调试连接（app 继续跑）',
              structured: <String, Object?>{'ok': true, 'action': action});
        }
        final hub = await ctx.debugPool.attach(s);
        final op = switch (step) {
          'pause' => ('pause', const <String, Object?>{}),
          'continue' => ('resume', const <String, Object?>{}),
          'stepOver' => ('resume', const <String, Object?>{'step': 'over'}),
          'stepInto' => ('resume', const <String, Object?>{'step': 'into'}),
          'stepOut' => ('resume', const <String, Object?>{'step': 'out'}),
          'hot' => ('hot', const <String, Object?>{}),
          'stop' => ('stop', const <String, Object?>{}),
          _ => throw McpToolException(
              '未知 action：$action',
              hint: '可用：pause / continue / stepOver / stepInto / stepOut / '
                  'detach / hot / stop',
            ),
        };
        final r = await _op(hub, op.$1, op.$2);
        // 暂停/单步是异步事件：等到真的 paused 再回，否则模型紧接着看栈会看到空。
        var st = await _op(hub, 'status');
        final wantPause = step == 'pause' ||
            step == 'stepOver' ||
            step == 'stepInto' ||
            step == 'stepOut';
        if (wantPause) {
          for (var i = 0; i < 15 && st['paused'] != true; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            st = await _op(hub, 'status');
          }
        } else if (step != 'stop' && step != 'hot') {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          st = await _op(hub, 'status');
        }
        final pause = st['pause'];
        final top = pause is Map ? pause['topFrame'] : null;
        final what = switch (step) {
          'pause' => '已请求暂停',
          'continue' => '已继续',
          'stepOver' => '已单步跳过',
          'stepInto' => '已单步进入',
          'stepOut' => '已单步跳出',
          'hot' => '已触发${r['restarted'] == true ? '热重启' : '热重载'}',
          'stop' => '已停止 app',
          _ => '完成',
        };
        final lines = <String>[
          what,
          if (top is Map) '当前位置：${_frameLoc(top)}'
              '${top['function'] == null ? '' : ' · ${top['function']}'}',
          if (pause is Map && pause['reason'] != null) '暂停原因：${pause['reason']}',
          // hub 的 message 在很多操作里就是同一句话，重复一遍没有信息量。
          if (r['message'] != null &&
              '${r['message']}'.trim().isNotEmpty &&
              '${r['message']}'.trim() != what)
            '${r['message']}',
        ];
        return McpToolResult.text(lines.join('\n'),
            structured: <String, Object?>{
              'ok': true,
              'action': step,
              'paused': st['paused'] == true,
              'pause': pause,
            });
      },
    );

McpTool _inspectTool() => McpTool(
      name: 'xbume_debug_inspect',
      title: '看栈 / 变量 / 帧内求值',
      description: 'stack：调用栈（每帧文件行号与函数名，可带变量）；vars：某一帧的变量，'
          '带 objectId 的可以再传 objectId 展开一层；eval：在暂停帧的上下文求值'
          '（能读局部变量与 this，比 xbume_eval 的库上下文更准）。'
          '要求会话处于暂停状态（断点命中或先 pause）。',
      group: ToolGroup.debug,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['stack', 'vars', 'eval'], defaultValue: 'stack'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'frameIndex': prop('integer', '帧序号（vars / eval 用，默认 0 = 当前帧）',
            defaultValue: 0),
        'limit': prop('integer', '栈最多返回几帧（默认 20）', defaultValue: 20),
        'withVars': prop('boolean', 'stack 时是否带上每帧变量（默认 false，量大）',
            defaultValue: false),
        'objectId': prop('string', 'vars 时展开某个对象（从上一层的 objectId 来）'),
        'keyword': prop('string', 'vars 时只留名字或值包含该关键字的变量'),
        'expression': prop('string', 'eval 的表达式（能访问当前帧局部变量）'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'stack').trim();
        final s = await resolveSession(ctx, args);
        if (action == 'eval' && !ctx.allowEval) {
          throw McpToolException('帧内求值未启用',
              hint: '启动 MCP 时加 --allow-eval（GUI 托管的服务在卡片上勾「允许 eval」）');
        }
        final hub = await ctx.debugPool.attach(s);
        if (action == 'eval') {
          final expr = requireString(args, 'expression',
              hint: '例如 items.length 或 widget.title');
          final idx = optionalInt(args, 'frameIndex') ?? 0;
          final r = await _op(hub, 'eval',
              <String, Object?>{'expression': expr, 'frameIndex': idx});
          return McpToolResult.text(
            '帧 #$idx `$expr` = ${r['value'] ?? '(空)'}',
            structured: <String, Object?>{
              'ok': true,
              'action': action,
              'frameIndex': idx,
              'expression': expr,
              'value': r['value'],
            },
          );
        }
        if (action == 'vars') {
          final idx = optionalInt(args, 'frameIndex') ?? 0;
          final objectId = optionalString(args, 'objectId');
          final keyword = optionalString(args, 'keyword')?.toLowerCase();
          final Map<String, Object?> r;
          if (objectId != null && objectId.isNotEmpty) {
            r = await _op(hub, 'getObject', <String, Object?>{'objectId': objectId});
          } else {
            final frames = await _op(hub, 'stack',
                <String, Object?>{'limit': (idx + 1).clamp(1, 200)});
            final list = (frames['frames'] as List? ?? const <Object?>[])
                .whereType<Map>()
                .toList();
            if (list.isEmpty) {
              throw McpToolException('当前没有调用栈：先让 app 暂停（断点命中或 pause）',
                  hint: '用 xbume_debug_control action=pause 主动暂停');
            }
            final frame = list[idx.clamp(0, list.length - 1)];
            r = <String, Object?>{
              'frameIndex': idx,
              'function': frame['function'],
              'path': frame['path'] ?? frame['scriptUri'],
              'line': frame['line'],
              'vars': frame['vars'],
            };
          }
          var vars = (r['vars'] as List? ?? const <Object?>[])
              .whereType<Map>()
              .toList();
          if (keyword != null && keyword.isNotEmpty) {
            vars = vars
                .where((v) =>
                    '${v['name']}'.toLowerCase().contains(keyword) ||
                    '${v['value']}'.toLowerCase().contains(keyword))
                .toList();
          }
          final lines = <String>[
            if (r['function'] != null)
              '帧 #${r['frameIndex'] ?? idx} ${r['function']}'
                  '${r['path'] != null ? ' @ ${_shortPath('${r['path']}')}:${r['line'] ?? ''}' : ''}',
            if (r['expression'] != null) '对象：${r['expression']}',
            for (final v in vars)
              '· ${v['name']} = ${v['value']}'
                  '${v['type'] == null ? '' : ' (${v['type']})'}'
                  '${v['objectId'] == null ? '' : '  [objectId=${v['objectId']}]'}',
          ];
          return McpToolResult.text(
            lines.isEmpty ? '这一帧没有可见变量' : lines.join('\n'),
            structured: <String, Object?>{
              'ok': true,
              'action': action,
              'frameIndex': r['frameIndex'] ?? idx,
              'objectId': objectId,
              'vars': vars,
            },
          );
        }
        if (action != 'stack') {
          throw McpToolException('未知 action：$action',
              hint: '可用：stack / vars / eval');
        }
        final limit = (optionalInt(args, 'limit') ?? 20).clamp(1, 200);
        final withVars = optionalBool(args, 'withVars');
        final st = await _op(hub, 'status');
        final paused = st['paused'] == true;
        final r = await _op(hub, 'stack', <String, Object?>{'limit': limit});
        final frames = (r['frames'] as List? ?? const <Object?>[])
            .whereType<Map>()
            .map((f) {
          final m = Map<String, Object?>.from(f);
          if (withVars) return m;
          final vars = m['vars'];
          m.remove('vars');
          if (vars is List) m['varCount'] = vars.length;
          return m;
        }).toList();
        final lines = <String>[
          for (final f in frames)
            '#${f['index']} ${f['function']} · ${_frameLoc(f)}'
                '${f['varCount'] == null ? '' : ' · ${f['varCount']} 个变量'}',
        ];
        return McpToolResult.text(
          frames.isEmpty
              ? (paused
                  ? '已暂停，但 VM 没有给出 Dart 调用栈（可能停在引擎/native 代码）；'
                      '设个断点让它命中，或在纯 Dart 代码里 pause 再试'
                  : 'app 没暂停：先用 xbume_debug_control action=pause，或让断点命中')
              : lines.join('\n'),
          structured: <String, Object?>{'ok': true, 'action': action, 'frames': frames},
        );
      },
    );

McpTool _outputTool() => McpTool(
      name: 'xbume_debug_output',
      title: '运行输出 / 源码面板',
      description: 'tail：读 flutter run 的运行输出（debugPrint / 异常 / 热重载日志，'
          '可关键字过滤）；source：读项目里的 Dart 源码（定位到的行前后）；'
          'files：列项目里的 Dart 文件（找断点位置用）。源码路径相对项目根，'
          '也可传绝对路径读 SDK / 依赖包里的文件（只读）。',
      group: ToolGroup.debug,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作', enumValues: <String>['tail', 'source', 'files'],
            defaultValue: 'tail'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'lines': prop('integer', 'tail 返回最后几行（默认 80）', defaultValue: 80),
        'keyword': prop('string', 'tail 只留包含该关键字的行'),
        'path': prop('string', 'source 的文件路径（相对项目根或绝对路径）'),
        'centerLine': prop('integer', 'source 的焦点行（给了就只回它前后 window 行）'),
        'window': prop('integer', 'source 焦点行前后各取几行（默认 30）', defaultValue: 30),
        'maxLines': prop('integer', 'source 最多返回多少行（默认 800）', defaultValue: 800),
        'max': prop('integer', 'files 最多列多少个（默认 300）', defaultValue: 300),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'tail').trim();
        final s = await resolveSession(ctx, args);
        final hub = await ctx.debugPool.attach(s);
        final st = await _op(hub, 'status');
        final root = (st['projectRoot'] ?? st['cwd'])?.toString();
        if (action == 'tail') {
          var lines = _tailLines(st['output'], 100000);
          final kw = optionalString(args, 'keyword')?.toLowerCase();
          if (kw != null && kw.isNotEmpty) {
            lines = lines.where((l) => l.toLowerCase().contains(kw)).toList();
          }
          final n = (optionalInt(args, 'lines') ?? 80).clamp(1, 2000);
          if (lines.length > n) lines = lines.sublist(lines.length - n);
          final logPath = st['logPath']?.toString() ?? '';
          return McpToolResult.text(
            lines.isEmpty
                ? (logPath.isEmpty
                    ? '没有运行输出可跟：这个会话不是本服务/GUI 拉起的 flutter run'
                        '（IDE 终端的日志在它自己的控制台，改从调试面板/终端看）'
                    : '还没有运行输出（app 刚启动或刚重连）')
                : lines.join('\n'),
            structured: <String, Object?>{
              'ok': true,
              'action': action,
              'count': lines.length,
              'lines': lines,
              'logPath': st['logPath'],
            },
          );
        }
        if (action == 'files') {
          if (root == null || root.isEmpty) {
            throw McpToolException('没有项目根',
                hint: '这个会话没带项目根（外部 IDE 起的）：'
                    'xbume_debug_attach 传 projectRoot，或 xbume_debug_output '
                    'action=source 直接给绝对路径');
          }
          final all = listDartFiles(root, max: 4000);
          final max = (optionalInt(args, 'max') ?? 300).clamp(1, 4000);
          final shown = all.take(max).toList();
          return McpToolResult.text(
            '${all.length} 个 Dart 文件${all.length > shown.length ? '（显示前 ${shown.length} 个）' : ''}\n'
            '${shown.join('\n')}',
            structured: <String, Object?>{
              'ok': true,
              'action': action,
              'total': all.length,
              'files': shown,
            },
          );
        }
        if (action != 'source') {
          throw McpToolException('未知 action：$action',
              hint: '可用：tail / source / files');
        }
        final raw = requireString(args, 'path',
            hint: '例如 lib/main.dart，或 /abs/path/file.dart');
        final isAbs = raw.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw);
        final maxLines = (optionalInt(args, 'maxLines') ?? 800).clamp(1, 4000);
        SourceFileView view;
        try {
          view = isAbs
              ? readSourceFileOutside(raw, maxLines: maxLines)
              : readSourceFile(root ?? '', raw,
                  maxLines: maxLines,
                  maxLineLen: 400);
        } on Exception catch (e) {
          throw McpToolException('读源码失败：${debugErrorText(e)}');
        }
        final center = optionalInt(args, 'centerLine');
        final window = (optionalInt(args, 'window') ?? 30).clamp(1, 500);
        var lines = view.lines;
        var start = 1;
        if (center != null && center > 0 && center <= view.total) {
          final from = (center - window).clamp(1, view.total);
          final to = (center + window).clamp(1, view.total);
          lines = view.lines.sublist(from - 1, to.clamp(from, view.lines.length));
          start = from;
        }
        final buf = StringBuffer()
          ..writeln('${view.rel}（共 ${view.total} 行'
              '${view.truncated ? '，已截断' : ''}${view.outside ? '，项目外只读' : ''}）');
        for (var i = 0; i < lines.length; i++) {
          final no = start + i;
          buf.writeln('${no == center ? '>' : ' '} ${no.toString().padLeft(4)}  ${lines[i]}');
        }
        return McpToolResult.text(buf.toString().trimRight(),
            structured: <String, Object?>{
              'ok': true,
              'action': action,
              'path': view.abs,
              'rel': view.rel,
              'total': view.total,
              'from': start,
              'lines': lines,
              'outside': view.outside,
            });
      },
    );

// ── 公共辅助 ──

Future<Map<String, Object?>> _op(
  DebugHub hub,
  String op, [
  Map<String, Object?> args = const <String, Object?>{},
]) async {
  final r = await hub.handle(op, args);
  if (r['ok'] == false) {
    final err = r['error']?.toString() ?? '未知原因';
    final suggest = r['suggest'];
    throw McpToolException(
      '调试操作失败：$err',
      hint: suggest is List && suggest.isNotEmpty
          ? '可能是拼写问题，候选：${suggest.take(8).join(' / ')}'
          : null,
    );
  }
  return r;
}

int _requireLine(Map<String, Object?> args) {
  final v = optionalInt(args, 'line');
  if (v == null || v <= 0) {
    throw McpToolException('缺少 line（正整数行号）', hint: '例如 lib/main.dart 第 42 行');
  }
  return v;
}

/// 按「文件 + 行」在断点表里找 id（路径接受绝对路径、相对路径或脚本 URI 尾巴）。
String? _bpIdFor(Object? bps, {required String path, required int line}) {
  if (bps is! List) return null;
  final want = path.replaceAll('\\', '/');
  for (final b in bps.whereType<Map>()) {
    final n = b['line'];
    final l = n is int ? n : int.tryParse('$n');
    if (l != line) continue;
    final p = '${b['path'] ?? b['scriptUri'] ?? ''}'.replaceAll('\\', '/');
    if (p == want || p.endsWith('/$want') || p.endsWith(want)) return '${b['id']}';
  }
  return null;
}

bool? optionalBoolOrNull(Map<String, Object?> args, String key) {
  if (!args.containsKey(key)) return null;
  final v = args[key];
  if (v is bool) return v;
  final s = '$v'.toLowerCase().trim();
  if (s == 'true' || s == '1') return true;
  if (s == 'false' || s == '0') return false;
  return null;
}

String _summary(Map<String, Object?> st) {
  final attached = st['attached'] == true;
  final sb = StringBuffer(attached
      ? (st['paused'] == true ? '已暂停' : '运行中')
      : '未接入调试');
  final pause = st['pause'];
  if (pause is Map) {
    final top = pause['topFrame'];
    if (top is Map) sb.write(' · ${_frameLoc(top)}');
    if (pause['reason'] != null) sb.write(' · ${pause['reason']}');
    if (pause['fromException'] != null) {
      sb.write(' · 异常 ${pause['fromException']}');
    }
  }
  final bps = st['breakpoints'];
  if (bps is List) {
    final on = bps.whereType<Map>().where((b) => b['enabled'] != false).length;
    sb.write(' · 断点 ${bps.length} 个（启用 $on）');
  }
  final pid = st['pid'];
  if (pid != null) sb.write(' · pid $pid');
  final root = st['projectRoot'] ?? st['cwd'];
  if (root != null && '$root'.isNotEmpty) sb.write(' · $root');
  if (st['message'] != null) sb.write('\n${st['message']}');
  return sb.toString();
}

List<String> _bpLines(Object? bps) {
  if (bps is! List) return const <String>[];
  return <String>[
    for (final b in bps.whereType<Map>())
      '· ${b['id'] ?? ''} ${_shortPath('${b['path'] ?? b['scriptUri'] ?? ''}')}'
          ':${b['line'] ?? ''}'
          '${b['enabled'] == false ? '（已停用）' : ''}'
          '${b['condition'] == null ? '' : ' 条件=${b['condition']}'}'
          '${b['logMessage'] == null ? '' : ' 日志=${b['logMessage']}'}',
  ];
}

List<String> _savedLines(Object? saved) {
  if (saved is! List) return const <String>[];
  return <String>[
    for (final b in saved.whereType<Map>())
      '· 记住 ${_shortPath('${b['path'] ?? ''}')}:${b['line'] ?? ''}'
          '${b['enabled'] == false ? '（已停用）' : ''}',
  ];
}

List<String> _tailLines(Object? output, int n) {
  if (output is! List) return const <String>[];
  final all = output.map((e) => '$e').toList();
  if (n <= 0 || all.length <= n) return all;
  return all.sublist(all.length - n);
}

String _frameLoc(Map f) {
  final p = f['path'] ?? f['scriptUri'] ?? '';
  return '${_shortPath('$p')}:${f['line'] ?? ''}';
}

String _shortPath(String p) {
  if (p.isEmpty) return '(未知)';
  final parts = p.split(Platform.pathSeparator);
  if (parts.length <= 2) return p;
  return parts.sublist(parts.length - 2).join('/');
}
