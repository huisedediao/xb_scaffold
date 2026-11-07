// 桥接工具组：把工具箱里那些「本机能力」交给 AI。
//
// 这些功能不适合在 MCP 里再实现一遍：SQLite 要调本机 sqlite3、沙盒下载要落
// 缓存、文件监听靠工具箱的轮询定时器、性能采样与场景对比是工具箱的状态机、
// IDE 唤起与守护进程管理用的是工具箱的配置。所以统一走 GuiBridge 转发，行为
// 与 GUI 完全一致；工具箱没开时工具会明确提示怎么开。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../debug/debug_client.dart' show projectRootFromScriptUri;
import '../debug/debug_hub.dart' show readPubspecName;
import '../paths.dart';
import '../perf/perf_metrics.dart';
import '../scenario/vm_client.dart';
import 'gui_bridge.dart';
import 'protocol.dart';
import 'tools.dart';

List<McpTool> bridgeTools() => <McpTool>[
      _storageTool(),
      _dbTool(),
      _sandboxTool(),
      _watchTool(),
      _instancesTool(),
      _widgetTreeTool(),
      _perfTool(),
      _compareTool(),
      _ideTool(),
      _daemonTool(),
      _routeLocateTool(),
    ];

Map<String, Object?> _schema(
  Map<String, Object?> properties, [
  List<String>? required,
]) =>
    toolSchema(properties, required);

McpTool _storageTool() => McpTool(
      name: 'xbume_storage',
      title: 'shared_preferences 读写',
      description: '直接读写 app 的 shared_prefs（Android/鸿蒙 XML、iOS plist）：'
          'list 列文件、read 读 XML、write 写入（先落文件，再经 app 内 '
          'SharedPreferences API 把改动项写回，立即生效）、reload 让 app 重读文件。'
          '用来回答「这个开关存在哪」「把值改回去」这类问题。',
      group: ToolGroup.data,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['list', 'read', 'write', 'reload'],
            defaultValue: 'list'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'uri': prop('string', 'VM service 地址（一般不用传，按会话自动取）'),
        'file': prop('string', 'prefs 文件绝对路径（省略用第一个）'),
        'xml': prop('string', 'write 时的完整 XML 内容'),
        'dirty': prop(
            'array', 'write 时要经 app 内 API 写回的改动项：[{key,type,value}]'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'list').trim();
        final uri = await _uriOf(ctx, args);
        switch (action) {
          case 'list':
            final j = await _gui(ctx, '/api/storage/list', q: <String, Object?>{'uri': uri});
            final files = (j['files'] as List? ?? const <Object?>[]);
            return McpToolResult.text(
              '包 ${j['pkg'] ?? '?'} · ${j['os'] ?? '?'} · '
              '${files.length} 个文件\n${files.join('\n')}',
              structured: j,
            );
          case 'read':
            final j = await _gui(ctx, '/api/storage/read', q: <String, Object?>{
              'uri': uri,
              if (optionalString(args, 'file') != null)
                'file': optionalString(args, 'file'),
            });
            final xml = '${j['xml'] ?? ''}';
            final lines = xml.split('\n');
            return McpToolResult.text(
              '${j['file'] ?? '?'}（${lines.length} 行）\n'
              '${lines.take(120).join('\n')}'
              '${lines.length > 120 ? '\n…（已截断，完整内容在 structured.xml）' : ''}',
              structured: j,
            );
          case 'write':
            final file = requireString(args, 'file', hint: '先 action=list 拿路径');
            final xml = requireString(args, 'xml', hint: '完整 XML 内容');
            final dirty = args['dirty'];
            final j = await _gui(
              ctx,
              '/api/storage/write',
              q: <String, Object?>{'uri': uri, 'file': file},
              method: 'POST',
              rawBody: jsonEncode(<String, Object?>{
                'xml': xml,
                if (dirty is List) 'dirty': dirty,
              }),
            );
            return McpToolResult.text(
              '已写回 ${j['file'] ?? file}'
              '${j['applied'] == true ? '（app 内已生效）' : '（只写了文件，重启 app 生效）'}',
              structured: j,
            );
          case 'reload':
            final j = await _gui(ctx, '/api/storage/reload',
                q: <String, Object?>{'uri': uri}, method: 'POST');
            return McpToolResult.text('已让 app 重读 prefs 文件', structured: j);
          default:
            throw McpToolException('未知 action：$action',
                hint: '可用：list / read / write / reload');
        }
      },
    );

McpTool _dbTool() => McpTool(
      name: 'xbume_db',
      title: 'SQLite 查询（app 沙盒里的库）',
      description: '把 app 沙盒里的 SQLite 文件拉到本机缓存，用本机 sqlite3 只读查询：'
          'open（传沙盒绝对路径，回 dbId）→ schema（看表结构）/ query（SQL，返回列与行）'
          '/ csv（导出 CSV 文本）→ close（删本机缓存）。app 端零改动，不写库。',
      group: ToolGroup.data,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['open', 'schema', 'query', 'csv', 'close'],
            defaultValue: 'query'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'uri': prop('string', 'VM service 地址（一般不用传）'),
        'path': prop('string', 'open 用：数据库在 app 沙盒里的绝对路径'),
        'dbId': prop('string', 'open 返回的 id（schema / query / csv / close 必填）'),
        'table': prop('string', 'schema 用：表名（省略则列出全部表）'),
        'sql': prop('string', 'query / csv 用的 SELECT 语句'),
        'force': prop('boolean', 'open 时强制重新拉取（默认 false）'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'query').trim();
        final uri = await _uriOf(ctx, args);
        if (action == 'open') {
          final path = requireString(args, 'path',
              hint: '例如 /data/user/0/<pkg>/databases/app.db');
          final j = await _gui(ctx, '/api/db/open', method: 'POST', q: <String, Object?>{
            'uri': uri,
            'path': path,
            'force': optionalBool(args, 'force'),
          });
          return McpToolResult.text(
            '已打开，dbId=${j['dbId'] ?? '?'}'
            '${j['tables'] == null ? '' : ' · 表 ${(j['tables'] as List).length} 个'}',
            structured: j,
          );
        }
        final dbId = requireString(args, 'dbId', hint: '先 action=open 拿 dbId');
        if (action == 'schema') {
          final table = optionalString(args, 'table')?.trim() ?? '';
          // 不传表名时先列全部表：AI 普遍先问「库里有什么表」。
          if (table.isEmpty) {
            final j = await _gui(ctx, '/api/db/query', method: 'POST', q: <String, Object?>{
              'dbId': dbId,
              'sql': "SELECT name FROM sqlite_master WHERE type='table' "
                  'ORDER BY name',
            });
            final rows = (j['rows'] as List? ?? const <Object?>[]);
            final lines = <String>[
              for (final r in rows)
                r is List && r.isNotEmpty ? '${r.first}' : '$r',
            ];
            return McpToolResult.text(
              '${rows.length} 张表：\n${lines.join('\n')}\n（传 table 看列与索引）',
              structured: j,
            );
          }
          final j = await _gui(ctx, '/api/db/schema',
              method: 'POST',
              q: <String, Object?>{'dbId': dbId, 'table': table});
          return McpToolResult.text('表 $table：${_brief(j, 900)}', structured: j);
        }
        if (action == 'close') {
          final j = await _gui(ctx, '/api/db/close',
              method: 'POST', q: <String, Object?>{'dbId': dbId});
          return McpToolResult.text('已关闭并删除本机缓存（不影响 app 内数据库）',
              structured: j);
        }
        final sql = requireString(args, 'sql', hint: '只能 SELECT / PRAGMA / EXPLAIN');
        if (action == 'csv') {
          final text = await _guiText(ctx, '/api/db/csv', method: 'POST', q: <String, Object?>{
            'dbId': dbId,
            'sql': sql,
          });
          final lines = text.split('\n');
          return McpToolResult.text(
            'CSV ${lines.length} 行\n${lines.take(30).join('\n')}'
            '${lines.length > 30 ? '\n…（完整 CSV 在 structured.csv）' : ''}',
            structured: <String, Object?>{'csv': text},
          );
        }
        if (action != 'query') {
          throw McpToolException('未知 action：$action',
              hint: '可用：open / schema / query / csv / close');
        }
        final j = await _gui(ctx, '/api/db/query',
            method: 'POST', q: <String, Object?>{'dbId': dbId, 'sql': sql});
        final cols = (j['columns'] as List? ?? const <Object?>[]);
        final rows = (j['rows'] as List? ?? const <Object?>[]);
        final buf = StringBuffer()
          ..writeln(cols.join(' | '))
          ..writeln('${rows.length} 行 · ${j['ms'] ?? '?'}ms'
              '${j['truncated'] == true ? ' · 已截断' : ''}');
        for (final r in rows.take(20)) {
          buf.writeln(r is List ? r.join(' | ') : '$r');
        }
        if (rows.length > 20) buf.writeln('…');
        return McpToolResult.text(buf.toString().trimRight(), structured: j);
      },
    );

McpTool _sandboxTool() => McpTool(
      name: 'xbume_sandbox',
      title: '应用沙盒文件（浏览 / 读 / 下载 / 上传 / 删）',
      description: '读 app 进程可见的文件系统：list 列目录、read 读文本（分页 offset/max）、'
          'download 下载文件到本机（回本地路径）、downloadDir 把目录递归打包成 tar 下载、'
          'upload 把文本内容写成文件、delete 删文件。路径是 app 视角的绝对路径；只用于 debug 包。',
      group: ToolGroup.data,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['list', 'read', 'download', 'downloadDir', 'upload',
              'delete'],
            defaultValue: 'list'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'uri': prop('string', 'VM service 地址（一般不用传）'),
        'path': prop('string', 'app 沙盒里的绝对路径（upload 时也可传目录＋name）'),
        'offset': prop('integer', 'read 起始字节（默认 0）', defaultValue: 0),
        'max': prop('integer', 'read 最多读多少字节（默认 65536）', defaultValue: 65536),
        'content': prop('string', 'upload 的文本内容'),
        'contentBase64': prop('string', 'upload 的二进制内容（base64，和 content 二选一）'),
        'name': prop('string', 'upload：path 是目录时的文件名'),
        'saveTo': prop('string', 'download 保存到本机的路径（默认 \$XB_UME_HOME/downloads）'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'list').trim();
        final uri = await _uriOf(ctx, args);
        final path = optionalString(args, 'path');
        if (action == 'list') {
          final j = await _gui(ctx, '/api/sandbox/list', q: <String, Object?>{
            'uri': uri,
            if (path != null) 'path': path,
          });
          final items = (j['items'] ?? j['entries'] ?? const <Object?>[]);
          final lines = <String>[
            for (final e in (items is List ? items : const <Object?>[]).take(200))
              e is Map
                  ? '${e['dir'] == true ? '[目录]' : '      '} ${e['name'] ?? ''}'
                      '${e['size'] == null ? '' : '  ${e['size']}B'}'
                  : '$e',
          ];
          return McpToolResult.text(
            '${j['path'] ?? path ?? '?'}（${(items is List) ? items.length : 0} 项）\n'
            '${lines.join('\n')}',
            structured: j,
          );
        }
        if (action == 'read') {
          final j = await _gui(ctx, '/api/sandbox/read', q: <String, Object?>{
            'uri': uri,
            'path': requireString(args, 'path', hint: '例如 /data/user/0/<pkg>/files/a.txt'),
            'offset': optionalInt(args, 'offset') ?? 0,
            'max': (optionalInt(args, 'max') ?? 65536).clamp(1, 4 * 1024 * 1024),
          });
          final text = '${j['text'] ?? j['content'] ?? ''}';
          return McpToolResult.text(
            '${j['path'] ?? path ?? ''}（total=${j['total'] ?? j['size'] ?? '?'}）\n'
            '${text.length > 8000 ? '${text.substring(0, 8000)}…' : text}',
            structured: j,
          );
        }
        if (action == 'delete') {
          final j = await _gui(ctx, '/api/sandbox/delete', method: 'POST', q: <String, Object?>{
            'uri': uri,
            'path': requireString(args, 'path', hint: '要删的文件绝对路径'),
          });
          return McpToolResult.text('已删除', structured: j);
        }
        if (action == 'upload') {
          final p = requireString(args, 'path', hint: '写到哪个文件（或目录 + name）');
          final b64 = optionalString(args, 'contentBase64');
          final text = optionalString(args, 'content');
          if (b64 == null && text == null) {
            throw McpToolException('upload 需要 content 或 contentBase64');
          }
          // GUI 的 upload 把 path 当目录、另收 name：这里把完整文件路径拆开，
          // 让模型像写文件一样传 path 就行。
          final trimmed = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
          final explicitName = optionalString(args, 'name')?.trim() ?? '';
          final String dir;
          final String name;
          if (explicitName.isNotEmpty) {
            dir = trimmed;
            name = explicitName;
          } else {
            final i = trimmed.lastIndexOf('/');
            if (i <= 0 || i == trimmed.length - 1) {
              throw McpToolException('upload 需要绝对文件路径，或 path=目录 + name=文件名');
            }
            dir = trimmed.substring(0, i);
            name = trimmed.substring(i + 1);
          }
          final j = await _gui(ctx, '/api/sandbox/upload', method: 'POST', q: <String, Object?>{
            'uri': uri,
            'path': dir,
          }, rawBody: jsonEncode(<String, Object?>{
            'name': name,
            'b64': b64 ?? base64Encode(utf8.encode(text!)),
          }));
          return McpToolResult.text('已写入 $dir/$name', structured: j);
        }
        if (action != 'download' && action != 'downloadDir') {
          throw McpToolException('未知 action：$action',
              hint: '可用：list / read / download / downloadDir / upload / delete');
        }
        final p = requireString(args, 'path', hint: '要下载的文件绝对路径');
        final dir = action == 'downloadDir';
        final bytes = await _guiBytes(
            ctx,
            dir ? '/api/sandbox/downloadDir' : '/api/sandbox/download',
            q: <String, Object?>{
              'uri': uri,
              'path': p,
            });
        final base = p.split('/').where((e) => e.isNotEmpty).last;
        final save = optionalString(args, 'saveTo') ??
            '${xbUmeHome()}/downloads/${DateTime.now().millisecondsSinceEpoch}_'
                '$base${dir ? '.tar' : ''}';
        final f = File(save);
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(bytes);
        return McpToolResult.text(
          '已${dir ? '打包' : '下载'} ${bytes.length} 字节 → ${f.path}',
          structured: <String, Object?>{
            'ok': true,
            'path': f.path,
            'bytes': bytes.length,
          },
        );
      },
    );

McpTool _watchTool() => McpTool(
      name: 'xbume_watch',
      title: '监听字段 / 表达式变化',
      description: '给实例字段或 eval 表达式加监听：值变化时写时间轴，可带条件命中截图。'
          'add（kind=expr|field；field 要 targetId）、list、events（取增量）、'
          'pause（恢复/暂停）、remove、clear。适合等一个状态变化再断言。'
          '直连会话（release）没有 eval：kind=inspect（轮询 XBUme.registerInspectable '
          '的字段树，targetId=inspectable id，expr=字段路径可空）或 kind=file'
          '（expr=文件路径，监听 size/mtime）；条件只能写 value > 10、value == done。',
      group: ToolGroup.data,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['add', 'list', 'events', 'pause', 'remove', 'clear'],
            defaultValue: 'list'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'uri': prop('string', 'VM service 地址（一般不用传）'),
        'kind': prop('string', 'add：expr / field；直连会话可用 inspect / file',
            defaultValue: 'expr'),
        'expr': prop('string',
            'add：表达式（field 是字段名；inspect 是字段路径，可空=整棵树；file 是文件路径）'),
        'targetId': prop('string',
            'add kind=field：实例 id；kind=inspect：inspectable id'),
        'lib': prop('string', 'add：求值库（可空）'),
        'condition': prop('string',
            'add：命中条件（可空；直连只支持 value <op> 字面量）'),
        'intervalMs': prop('integer', 'add：轮询间隔 200–10000ms，缺省 500'),
        'id': prop('string', 'pause / remove 用：监听项 id'),
        'on': prop('boolean', 'pause：true 恢复 / false 暂停', defaultValue: false),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'list').trim();
        final uri = await _uriOf(ctx, args);
        if (action == 'add') {
          final kind = optionalString(args, 'kind') ?? 'expr';
          final expr = optionalString(args, 'expr') ?? '';
          // inspect 允许空 expr（监听整棵树），其余类型必须给值。
          if (expr.isEmpty && kind != 'inspect') {
            requireString(args, 'expr', hint: '例如 state.count');
          }
          final j = await _gui(ctx, '/api/watch/add', method: 'POST', rawBody: jsonEncode(<String, Object?>{
            'uri': uri,
            'kind': kind,
            'expr': expr,
            if (optionalString(args, 'targetId') != null)
              'targetId': optionalString(args, 'targetId'),
            if (optionalString(args, 'lib') != null) 'lib': optionalString(args, 'lib'),
            if (optionalString(args, 'condition') != null)
              'condition': optionalString(args, 'condition'),
            if (args['intervalMs'] != null) 'intervalMs': args['intervalMs'],
          }));
          if (j['ok'] == false) {
            throw McpToolException('加监听失败：${j['error'] ?? '未知原因'}');
          }
          final item = j['item'];
          final id = item is Map ? item['id'] : j['id'];
          final what = expr.isEmpty ? '$kind（整棵树）' : expr;
          return McpToolResult.text('已监听 $what（id=${id ?? '?'}）', structured: j);
        }
        if (action == 'remove' || action == 'pause') {
          final id = requireString(args, 'id', hint: '先 action=list 看 id');
          final path = action == 'remove' ? '/api/watch/remove' : '/api/watch/pause';
          final j = await _gui(ctx, path, method: 'POST', q: <String, Object?>{
            'id': id,
            if (action == 'pause') 'on': optionalBool(args, 'on'),
          });
          return McpToolResult.text(
              j['ok'] == true ? '完成' : '没找到该监听项',
              structured: j);
        }
        if (action == 'clear') {
          final j = await _gui(ctx, '/api/watch/clear', method: 'POST', rawBody: jsonEncode(<String, Object?>{'uri': uri}));
          return McpToolResult.text('已清空这个会话的监听', structured: j);
        }
        final path = action == 'events' ? '/api/watch/events' : '/api/watch/list';
        final j = await _gui(ctx, path, q: <String, Object?>{'uri': uri});
        final items = (j['items'] ?? j['events'] ?? j['watches'] ?? const <Object?>[]);
        final list = items is List ? items.whereType<Map>().toList() : const <Map>[];
        final lines = <String>[];
        if (action == 'events') {
          for (final e in list) {
            final ms = (e['ms'] as num?)?.toInt() ?? 0;
            final t = ms == 0 ? '' : DateTime.fromMillisecondsSinceEpoch(ms)
                .toIso8601String().substring(11, 23);
            lines.add('$t ${e['label'] ?? e['expr'] ?? ''}: '
                '${e['old'] ?? '?'} → ${e['new'] ?? '?'}'
                '${e['condMet'] == true ? '（条件命中）' : ''}'
                '${e['shot'] == null ? '' : ' 截图 ${e['shot']}'}'
                '${e['error'] == null ? '' : ' 错误 ${e['error']}'}');
          }
        } else {
          for (final w in list) {
            lines.add('· ${w['id'] ?? '?'} ${w['label'] ?? w['expr'] ?? ''}'
                '${w['paused'] == true ? '（已暂停）' : ''}'
                ' · 变化 ${w['changes'] ?? 0} 次 / 轮询 ${w['polls'] ?? 0} 次'
                '${(w['lastError'] ?? '').toString().isEmpty ? '' : ' · 错误 ${w['lastError']}'}');
          }
        }
        return McpToolResult.text(
          '${list.length} ${action == 'events' ? '条变化' : '项监听'}'
          '${lines.isEmpty ? '' : '\n${lines.take(60).join('\n')}'}',
          structured: j,
        );
      },
    );

McpTool _instancesTool() => McpTool(
      name: 'xbume_instances',
      title: '运行时实例（查找 / 字段 / 改值）',
      description: '在 app 进程里找 State / ChangeNotifier 实例：stores 列 XBUme.registerStore '
          '注册的实例、find 按类名查（先遍历 Element 树再堆扫描）、tree 看某个实例的字段、'
          'set 改一个字段的值。配合 xbume_eval 做「读私有状态 / 改状态」很直接用。',
      group: ToolGroup.inspect,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['stores', 'find', 'tree', 'set'], defaultValue: 'find'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'uri': prop('string', 'VM service 地址（一般不用传）'),
        'class': prop('string', 'find：类名（如 HomePageState）'),
        'limit': prop('integer', 'find：最多返回几个（默认 20）', defaultValue: 20),
        'id': prop('string', 'tree / set：实例 id'),
        'name': prop('string', 'tree：实例名（可空）'),
        'depth': prop('integer', 'tree：展开层数（默认 1）', defaultValue: 1),
        'field': prop('string', 'set：字段名'),
        'value': prop('string', 'set：新值（按 vtype 解析）'),
        'vtype': prop('string', 'set：值类型 string / int / double / bool / null',
            defaultValue: 'string'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'find').trim();
        final uri = await _uriOf(ctx, args);
        switch (action) {
          case 'stores':
            final j = await _gui(ctx, '/api/instances/stores',
                q: <String, Object?>{'uri': uri});
            return McpToolResult.text(_brief(j, 2000), structured: j);
          case 'find':
            final cls = requireString(args, 'class', hint: '例如 HomePageState');
            final j = await _gui(ctx, '/api/instances/find', q: <String, Object?>{
              'uri': uri,
              'class': cls,
              'limit': optionalInt(args, 'limit') ?? 20,
            });
            return McpToolResult.text(
                '找到 ${_count(j)} 个 $cls\n${_brief(j, 1600)}',
                structured: j);
          case 'tree':
            final j = await _gui(ctx, '/api/instances/tree', q: <String, Object?>{
              'uri': uri,
              'id': requireString(args, 'id', hint: '从 find 的结果里拿 id'),
              if (optionalString(args, 'name') != null)
                'name': optionalString(args, 'name'),
              'depth': optionalInt(args, 'depth') ?? 1,
            });
            return McpToolResult.text(_brief(j, 2500), structured: j);
          case 'set':
            final j = await _gui(ctx, '/api/instances/set', method: 'POST', q: <String, Object?>{
              'uri': uri,
              'id': requireString(args, 'id', hint: '从 find 的结果里拿 id'),
              'field': requireString(args, 'field', hint: '字段名'),
              'value': optionalString(args, 'value') ?? '',
              'vtype': optionalString(args, 'vtype') ?? 'string',
            });
            return McpToolResult.text(
                j['ok'] == false ? '修改失败：${j['error']}' : '已修改 ${args['field']}',
                structured: j);
          default:
            throw McpToolException('未知 action：$action',
                hint: '可用：stores / find / tree / set');
        }
      },
    );

McpTool _widgetTreeTool() => McpTool(
      name: 'xbume_widget_tree',
      title: 'Widget 树 / 点截图选组件',
      description: 'tree：整棵 Widget 树（含业务组件标识）；pick：按截图逻辑坐标选中组件，'
          '回组件类型、源码位置、宽高与四向间距（与工具箱「截图」页点选一致）。'
          '想按类型/文本找组件用 xbume_find_widget，想点它用 xbume_tap。',
      group: ToolGroup.inspect,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作', enumValues: <String>['tree', 'pick'],
            defaultValue: 'tree'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'uri': prop('string', 'VM service 地址（一般不用传）'),
        'x': prop('number', 'pick：截图上的 x（逻辑像素）'),
        'y': prop('number', 'pick：截图上的 y（逻辑像素）'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'tree').trim();
        final uri = await _uriOf(ctx, args);
        if (action == 'tree') {
          final j = await _gui(ctx, '/api/wtree', q: <String, Object?>{'uri': uri});
          // GUI 回的是压缩字段：d=深度、t=组件类型、k=key 描述、b=[x,y,w,h]。
          final nodes = (j['nodes'] as List? ?? const <Object?>[]);
          final lines = <String>[
            for (final n in nodes.take(200))
              if (n is Map)
                '${'  ' * ((n['d'] as num?)?.toInt() ?? 0)}${n['t'] ?? ''}'
                    '${(n['k'] ?? '').toString().isEmpty ? '' : ' ${n['k']}'}'
                    '${n['b'] is List ? ' · ${(n['b'] as List).join(',')}' : ''}',
          ];
          final meta = nodes.length > 200
              ? '${nodes.length} 个节点（只列前 200）'
              : '${nodes.length} 个节点';
          return McpToolResult.text(
            '$meta · 画面 ${j['physW'] ?? '?'}x${j['physH'] ?? '?'}'
            '@${j['dpr'] ?? 1}x\n${lines.join('\n')}',
            structured: j,
          );
        }
        if (action != 'pick') {
          throw McpToolException('未知 action：$action', hint: '可用：tree / pick');
        }
        final x = args['x'];
        final y = args['y'];
        if (x == null || y == null) {
          throw McpToolException('pick 需要 x / y（逻辑像素）',
              hint: '先用 xbume_screenshot 看截图，再传坐标');
        }
        final j = await _gui(ctx, '/api/wtree/pick', method: 'POST', q: <String, Object?>{
          'uri': uri,
          'x': x,
          'y': y,
        });
        final hit = j['item'] ?? j['hit'] ?? j;
        return McpToolResult.text(_brief(
            hit is Map ? hit.cast<String, Object?>() : j, 1200), structured: j);
      },
    );

McpTool _perfTool() => McpTool(
      name: 'xbume_perf',
      title: '性能 / 内存 / 泄漏检测',
      description: 'snapshot：帧率、Dart 堆、进程内存（RSS/CPU）、isolate CPU 采样（windowMs '
          '窗口）；leak：GC 后对浏览过的页面 State 做树上/堆上双计数，不在路由栈但堆上仍有实例'
          '即疑似泄漏；gc：主动触发一次全量 GC 后再采样；reassemble：触发 UI 重建（改完主题/'
          '局部状态后强行刷新）。',
      group: ToolGroup.inspect,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['snapshot', 'leak', 'gc', 'reassemble'],
            defaultValue: 'snapshot'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'uri': prop('string', 'VM service 地址（一般不用传）'),
        'windowMs': prop('integer', 'snapshot 采样窗口（默认 2000ms）', defaultValue: 2000),
        'classes': prop('string', 'leak：要检测的 State 类名（逗号分隔，省略则自动从路由栈收集）'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'snapshot').trim();
        final uri = await _uriOf(ctx, args);
        if (action == 'gc' || action == 'reassemble') {
          Map<String, Object?> j = const <String, Object?>{};
          var timedOut = false;
          try {
            j = await _gui(ctx, '/api/runtime/op', method: 'POST', q: <String, Object?>{
              'uri': uri,
              'op': action,
            });
          } on TimeoutException {
            // reassemble 可能重建时命中断点，app 停住后 HTTP 响应就回不来了。
            timedOut = true;
          }
          return McpToolResult.text(
            action == 'gc'
                ? '已触发全量 GC'
                : (timedOut
                    ? '已触发 UI 重建（reassemble），但响应超时：app 可能停在断点上，'
                        '用 xbume_debug_state 确认'
                    : '已触发 UI 重建（reassemble）'),
            structured: <String, Object?>{
              'ok': true,
              'timeout': timedOut,
              ...j,
            },
          );
        }
        if (action == 'leak') {
          var classes = optionalString(args, 'classes')?.trim() ?? '';
          if (classes.isEmpty) {
            // GUI 的 leakcheck 没类名直接 400：先自动收集项目内 State 类名。
            classes = (await _autoLeakClasses(ctx, uri)).join(',');
            if (classes.isEmpty) {
              throw McpToolException('leak 需要 State 类名，自动收集为空',
                  hint: '项目里没找到 State 子类（或 VM 未返回类列表）；'
                      '显式传 classes=HomePageState,DetailPageState 再试');
            }
          }
          final j = await _gui(ctx, '/api/leakcheck', method: 'POST', q: <String, Object?>{
            'uri': uri,
            'classes': classes,
          });
          final items = (j['items'] as List? ?? const <Object?>[]);
          final lines = <String>[];
          var leaks = 0;
          for (final it in items.whereType<Map>()) {
            final tree = (it['tree'] as num?)?.toInt() ?? 0;
            final heap = (it['heap'] as num?)?.toInt() ?? 0;
            final bad = tree == 0 && heap != 0;
            if (bad) leaks++;
            lines.add('${bad ? '⚠' : '✓'} ${it['cls']} · 树上 $tree / 堆上 $heap'
                '${bad ? '（疑似泄漏）' : ''}');
          }
          return McpToolResult.text(
            '检测 ${items.length} 个 State 类，疑似泄漏 $leaks 个\n'
            '${lines.join('\n')}',
            structured: j,
          );
        }
        if (action != 'snapshot') {
          throw McpToolException('未知 action：$action',
              hint: '可用：snapshot / leak / gc / reassemble');
        }
        // 直接采 VM：GUI 的 /api/perf 会顺带调 ext.xbume.processStats，而部分
        // 会话（macOS 桌面实测）对 ext 请求不应答，会把接口拖到超时。
        final j = await _perfSnapshotFromVm(
            uri, (optionalInt(args, 'windowMs') ?? 2000).clamp(500, 5000));
        final vm = j['vm'];
        final heap = j['heap'];
        final cpu = j['cpu'];
        final proc = j['process'];
        return McpToolResult.text(
          <String>[
            if (vm is Map)
              '${vm['os']} ${vm['version']} · ${vm['isolates']} isolate',
            if (heap is Map)
              'Dart 堆 ${_mb(heap['used'])} / ${_mb(heap['capacity'])}'
                  '（堆外 ${_mb(heap['external'])}）',
            if (proc is Map) '进程 RSS ${_mb(proc['rss'])}',
            if (cpu is Map)
              'isolate CPU ${cpu['percent']}%（样本 ${cpu['samples']}，GC ${cpu['gc']}）'
            else if (j['cpuError'] != null)
              'isolate CPU 不可用：${j['cpuError']}',
            if (j['gcCmdHint'] != null) '${j['gcCmdHint']}',
          ].join('\n'),
          structured: j,
        );
      },
    );

McpTool _compareTool() => McpTool(
      name: 'xbume_compare',
      title: '双会话并行跑同一场景并对比',
      description: '在两个调试会话上并行执行同一场景，对比结果（与工具箱「对比」页一致）。'
          'run 传 sessionA/sessionB 或 uriA/uriB，steps（步骤数组）或 name（已保存的场景名）；'
          'status 查进度，stop 停。适合验证「改前 / 改后」或两台设备的差异。',
      group: ToolGroup.inspect,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['run', 'status', 'stop'], defaultValue: 'status'),
        'sessionA': prop('string', 'run：会话 A 的 id'),
        'sessionB': prop('string', 'run：会话 B 的 id'),
        'uriA': prop('string', 'run：会话 A 的 ws 地址（与 sessionA 二选一）'),
        'uriB': prop('string', 'run：会话 B 的 ws 地址'),
        'labelA': prop('string', 'run：A 的显示名'),
        'labelB': prop('string', 'run：B 的显示名'),
        'name': prop('string', 'run：已保存的场景名'),
        'steps': prop('array', 'run：步骤数组（与 name 二选一）'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'status').trim();
        if (action == 'status') {
          final j = await _gui(ctx, '/api/compare/status');
          return McpToolResult.text(_brief(j, 1600), structured: j);
        }
        if (action == 'stop') {
          final j = await _gui(ctx, '/api/compare/stop', method: 'POST');
          return McpToolResult.text('已请求停止对比任务', structured: j);
        }
        if (action != 'run') {
          throw McpToolException('未知 action：$action',
              hint: '可用：run / status / stop');
        }
        final a = await _uriOr(ctx, args, 'sessionA', 'uriA');
        final b = await _uriOr(ctx, args, 'sessionB', 'uriB');
        final steps = args['steps'];
        final j = await _gui(ctx, '/api/compare/run',
            method: 'POST',
            rawBody: jsonEncode(<String, Object?>{
              'uriA': a,
              'uriB': b,
              if (optionalString(args, 'labelA') != null)
                'labelA': optionalString(args, 'labelA'),
              if (optionalString(args, 'labelB') != null)
                'labelB': optionalString(args, 'labelB'),
              if (optionalString(args, 'name') != null)
                'name': optionalString(args, 'name'),
              if (steps is List) 'steps': steps,
            }));
        return McpToolResult.text(
          '已启动对比${j['runId'] == null ? '' : '（${j['runId']}）'}，用 action=status 查进度',
          structured: j,
        );
      },
    );

McpTool _ideTool() => McpTool(
      name: 'xbume_ide',
      title: '在 IDE 打开源码 / IDE 顺序',
      description: 'open：在本机 IDE 打开文件并定位到行（走工具箱的 IDE 唤起链：VS Code → '
          'Android Studio → 系统默认）；order 看当前 IDE 顺序，setOrder 改（["vscode", ...]）。'
          '想在分析里给人一个可点的位置时用 open。',
      group: ToolGroup.env,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['open', 'order', 'setOrder'], defaultValue: 'open'),
        'file': prop('string', 'open：文件绝对路径'),
        'line': prop('integer', 'open：行号（默认 1）', defaultValue: 1),
        'ideOrder': prop('array', 'setOrder：IDE 顺序数组'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'open').trim();
        if (action == 'order') {
          final j = await _gui(ctx, '/api/ideorder');
          return McpToolResult.text(_brief(j, 600), structured: j);
        }
        if (action == 'setOrder') {
          final order = args['ideOrder'];
          if (order is! List || order.isEmpty) {
            throw McpToolException('setOrder 需要 ideOrder 数组',
                hint: '例如 ["vscode", "android-studio"]');
          }
          final j = await _gui(ctx, '/api/ideorder',
              method: 'POST',
              rawBody: jsonEncode(<String, Object?>{'ideOrder': order}));
          if (j['ok'] == false) {
            throw McpToolException('修改 IDE 顺序失败：${j['message'] ?? j['error']}');
          }
          return McpToolResult.text('已保存：${j['ideOrder'] ?? order}', structured: j);
        }
        if (action != 'open') {
          throw McpToolException('未知 action：$action',
              hint: '可用：open / order / setOrder');
        }
        final j = await _gui(ctx, '/api/openide', q: <String, Object?>{
          'file': requireString(args, 'file', hint: '源码文件绝对路径'),
          'line': optionalInt(args, 'line') ?? 1,
        });
        return McpToolResult.text(
          j['ok'] == true ? '已在 IDE 打开' : '没能唤起 IDE：${j['message'] ?? '未知原因'}',
          structured: j,
        );
      },
    );

McpTool _daemonTool() => McpTool(
      name: 'xbume_daemon',
      title: '守护进程 / 服务状态与日志',
      description: 'status：daemon 发现的会话与配置；restart：重启 daemon（重新发现设备）；'
          'svc：GUI/daemon 服务状态；svcLog：安装/启动日志（offset 增量）；'
          'clientLog：写一条前端排障日志。设备连不上、会话莫名消失时先看 status。',
      group: ToolGroup.env,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['status', 'restart', 'svc', 'svcLog', 'clientLog'],
            defaultValue: 'status'),
        'offset': prop('integer', 'svcLog：从第几字节开始（默认 0）', defaultValue: 0),
        'tag': prop('string', 'clientLog：标签'),
        'msg': prop('string', 'clientLog：内容'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'status').trim();
        switch (action) {
          case 'status':
            final j = await _gui(ctx, '/api/daemon');
            final sessions = (j['sessions'] as List? ?? const <Object?>[]);
            return McpToolResult.text(
              'daemon ${j['running'] == true ? '运行中' : '未运行'} · '
              '${sessions.length} 个会话\n${_brief(j, 2000)}',
              structured: j,
            );
          case 'restart':
            final j = await _gui(ctx, '/api/daemon/restart', method: 'POST');
            return McpToolResult.text(_brief(j, 800), structured: j);
          case 'svc':
            final j = await _gui(ctx, '/api/svc/status');
            return McpToolResult.text(_brief(j, 1600), structured: j);
          case 'svcLog':
            final j = await _gui(ctx, '/api/svc/log',
                q: <String, Object?>{'offset': optionalInt(args, 'offset') ?? 0});
            final text = '${j['text'] ?? j['log'] ?? ''}';
            return McpToolResult.text(
              text.isEmpty
                  ? _brief(j, 2500)
                  : (text.length > 4000 ? '${text.substring(0, 4000)}…' : text),
              structured: j,
            );
          case 'clientLog':
            final j = await _gui(ctx, '/api/clientlog', method: 'POST', rawBody: jsonEncode(<String, Object?>{
              'tag': optionalString(args, 'tag') ?? 'mcp',
              'msg': optionalString(args, 'msg') ?? '',
            }));
            return McpToolResult.text('已记录', structured: j);
          default:
            throw McpToolException('未知 action：$action',
                hint: '可用：status / restart / svc / svcLog / clientLog');
        }
      },
    );

McpTool _routeLocateTool() => McpTool(
      name: 'xbume_route_locate',
      title: '路由栈 / 源码定位 / 路由操作',
      description: '工具箱路由栈那套（走 VM 直读 Navigator，不依赖 app 封装）：'
          'stack 列全部 Navigator 与各自路由；info 静态解析某个 Widget 类对应的 State / '
          'ChangeNotifier 与声明位置；locate 把指定路由定位到第一个业务组件类名与源码行'
          '（open=true 时直接唤起 IDE）；op 直接改栈：pop（仅栈顶）、remove（指定下标）、'
          'push（按路由名）。注意 op 不经 app 自己的路由封装。',
      group: ToolGroup.env,
      inputSchema: _schema(<String, Object?>{
        'action': prop('string', '操作',
            enumValues: <String>['locate', 'stack', 'info', 'op'],
            defaultValue: 'locate'),
        'sessionId': prop('string', '会话 id（省略用当前会话）'),
        'uri': prop('string', 'VM service 地址（一般不用传）'),
        'idx': prop('integer', 'locate / op：路由下标（0=栈底，-1=栈顶）',
            defaultValue: -1),
        'nav': prop('integer', 'Navigator 下标（默认 0；locate 默认 -1=主 Navigator）'),
        'open': prop('boolean', 'locate：是否顺手在 IDE 打开（默认 false）',
            defaultValue: false),
        'file': prop('string', 'info：Widget 所在源文件绝对路径'),
        'class': prop('string',
            'info：Widget 类名；locate：直连会话可选，指定要定位的页面类名'),
        'root': prop('string', 'locate：直连会话的项目根（启发式搜索源码用）'),
        'op': prop('string', 'op：pop / remove / push'),
        'name': prop('string', 'op=push：路由名'),
      }),
      handler: (ctx, args) async {
        final action = (optionalString(args, 'action') ?? 'locate').trim();
        final uri = await _uriOf(ctx, args);
        if (action == 'stack') {
          final j = await _gui(ctx, '/api/routestack', q: <String, Object?>{'uri': uri});
          final navs = (j['navigators'] as List? ?? const <Object?>[]);
          final lines = <String>[];
          for (final n in navs.whereType<Map>()) {
            lines.add('Navigator ${n['index']}：');
            for (final r in (n['routes'] as List? ?? const <Object?>[])) {
              if (r is! Map) continue;
              lines.add('  ${r['current'] == true ? '▶' : ' '} #${(n['routes'] as List).indexOf(r)} '
                  '${r['name'] ?? '(未命名)'} · ${r['type'] ?? ''}'
                  '${(r['args'] ?? '').toString().isEmpty ? '' : ' args=${r['args']}'}');
            }
          }
          if (j['approx'] == true) {
            lines.add('（直连会话：按路由事件重放的近似栈，顺序可能与真实栈不同）');
          }
          return McpToolResult.text(
            lines.isEmpty ? '没有路由' : lines.join('\n'),
            structured: j,
          );
        }
        if (action == 'info') {
          final rawFile = requireString(args, 'file',
              hint: 'Widget 所在源文件（绝对路径，或相对项目根，如 lib/pages/home_page.dart）');
          final cls = requireString(args, 'class', hint: '例如 HomePage');
          // GUI 只认存在的绝对路径：相对路径按 debug 项目根补全。
          final file = await _absSourcePath(uri, rawFile);
          if (file == null) {
            throw McpToolException('源文件不存在：$rawFile',
                hint: '传绝对路径；或传相对项目根的路径（如 lib/pages/home_page.dart）');
          }
          final j = await _gui(ctx, '/api/routeinfo',
              q: <String, Object?>{'file': file, 'class': cls});
          final loc = j['loc'];
          return McpToolResult.text(
            '$cls → State ${j['state'] ?? '-'} · VM ${j['vm'] ?? '-'} · CN ${j['cn'] ?? '-'}'
            '${loc == null ? '' : '\n${_brief(<String, Object?>{'loc': loc}, 1200)}'}',
            structured: j,
          );
        }
        if (action == 'op') {
          final op = requireString(args, 'op', hint: 'pop / remove / push');
          if (!const <String>{'pop', 'remove', 'push'}.contains(op)) {
            throw McpToolException('op 只支持 pop / remove / push');
          }
          if (op == 'push' && (optionalString(args, 'name') ?? '').isEmpty) {
            throw McpToolException('push 需要 name（路由名）');
          }
          final j = await _gui(ctx, '/api/routeop', method: 'POST', q: <String, Object?>{
            'uri': uri,
            'op': op,
            'nav': optionalInt(args, 'nav') ?? 0,
            'idx': optionalInt(args, 'idx') ?? -1,
            if (optionalString(args, 'name') != null) 'name': optionalString(args, 'name'),
          });
          final msg = j['message'] ?? j['result'];
          return McpToolResult.text(
            j['ok'] == false ? '操作失败：${j['error'] ?? msg ?? '未知原因'}'
                : '已执行 $op${msg == null ? '' : '：$msg'}',
            structured: j,
          );
        }
        if (action != 'locate') {
          throw McpToolException('未知 action：$action',
              hint: '可用：locate / stack / info / op');
        }
        final nav = optionalInt(args, 'nav') ?? 0;
        var idx = optionalInt(args, 'idx') ?? -1;
        if (idx < 0) {
          // GUI 的 routelocate 只接受具体下标（-1 直接 400）：按栈顶换算。
          final st = await _gui(ctx, '/api/routestack',
              q: <String, Object?>{'uri': uri});
          for (final n in (st['navigators'] as List? ?? const <Object?>[])
              .whereType<Map>()) {
            if ((n['index'] as num?)?.toInt() != nav) continue;
            final len = (n['routes'] as List? ?? const <Object?>[]).length;
            if (len > 0) idx = len - 1;
          }
          if (idx < 0) {
            throw McpToolException('路由栈为空或 Navigator $nav 不存在',
                hint: '先 action=stack 看有哪些路由');
          }
        }
        final j = await _gui(ctx, '/api/routelocate', q: <String, Object?>{
          'uri': uri,
          'nav': nav,
          'idx': idx,
          'open': optionalBool(args, 'open') ? 1 : 0,
          // 直连会话：启发式定位要项目根，可选指定页面类名（比按路由名猜准）。
          if (optionalString(args, 'root') != null)
            'root': optionalString(args, 'root'),
          if (optionalString(args, 'class') != null)
            'class': optionalString(args, 'class'),
        });
        final cls = j['className'] ?? j['widget'] ?? '?';
        final file = j['file'] ?? j['path'];
        final line = j['line'];
        return McpToolResult.text(
          '$cls${file == null ? '' : ' · $file:${line ?? ''}'}'
          '${j['heuristic'] == true ? '（启发式，候选：${(j['candidates'] as List? ?? const <Object?>[]).take(4).join(' / ')}）' : ''}',
          structured: j,
        );
      },
    );

Future<String> _uriOr(
  McpToolContext ctx,
  Map<String, Object?> args,
  String sessionKey,
  String uriKey,
) async {
  final raw = optionalString(args, uriKey);
  if (raw != null && raw.trim().isNotEmpty) return raw.trim();
  final id = optionalString(args, sessionKey);
  if (id == null || id.trim().isEmpty) {
    throw McpToolException('需要 $sessionKey 或 $uriKey',
        hint: '先用 xbume_sessions 看有哪些会话');
  }
  try {
    return (await ctx.sessions.use(id.trim())).wsUrl;
  } on StateError catch (e) {
    throw McpToolException(e.message.toString());
  }
}

int _count(Map<String, Object?> j) {
  for (final k in <String>['items', 'instances', 'rows', 'result']) {
    final v = j[k];
    if (v is List) return v.length;
  }
  return 0;
}

// ── 公共辅助 ──

/// 曾出现在路由栈里的 State 类名：路由退出后仍参与泄漏检测，与工具箱
/// 前端「当前栈 + 历史已退出集合」的口径一致。
final Set<String> _seenStateClasses = <String>{};

/// 从当前路由栈反查各页面的 State 类名：
/// routestack → 逐路由 routelocate（open=0，不拉 IDE）→ routeinfo 取 State。
/// 单个路由解析失败不影响其余；全都解析不出时返回已见过的类名集合。
Future<List<String>> _stateClassesOfRoutes(
    McpToolContext ctx, String uri) async {
  final out = <String>{..._seenStateClasses};
  try {
    final st =
        await _gui(ctx, '/api/routestack', q: <String, Object?>{'uri': uri});
    for (final n in (st['navigators'] as List? ?? const <Object?>[])
        .whereType<Map>()) {
      final nav = (n['index'] as num?)?.toInt() ?? 0;
      final routes = n['routes'] as List? ?? const <Object?>[];
      for (var i = 0; i < routes.length; i++) {
        try {
          final loc = await _gui(ctx, '/api/routelocate', q: <String, Object?>{
            'uri': uri,
            'nav': nav,
            'idx': i,
            'open': 0,
          });
          final file = '${loc['file'] ?? ''}';
          final cls = '${loc['className'] ?? ''}';
          if (file.isEmpty || cls.isEmpty) continue;
          final info = await _gui(ctx, '/api/routeinfo',
              q: <String, Object?>{'file': file, 'class': cls});
          final state = '${info['state'] ?? ''}'.trim();
          if (state.isNotEmpty) out.add(state);
        } catch (_) {
          // 该路由没定位到源码（可能在依赖包里），跳过。
        }
      }
    }
  } catch (_) {
    // 取不到路由栈时只用已见过的类名。
  }
  _seenStateClasses
    ..clear()
    ..addAll(out);
  return out.toList();
}

/// 相对路径按 debug 项目根补成绝对路径；都不存在时返回 null
/// （GUI 的 /api/routeinfo 只接受本机存在的绝对路径）。
Future<String?> _absSourcePath(String uri, String file) async {
  final f = File(file);
  if (f.existsSync()) return f.absolute.path;
  if (f.isAbsolute) return null;
  final root = await _projectRootOf(uri);
  if (root == null) return null;
  final candidate = File('$root/${file.replaceFirst(RegExp(r'^\.\.?/'), '')}');
  return candidate.existsSync() ? candidate.path : null;
}

/// 自动收集泄漏检测用的 State 类名：
/// ① 路由栈能解析到源码的 State（含历史已退出页，最可能是泄漏源）；
/// ② VM 里按库归属筛出本项目全部 `*State` 类（覆盖不在栈里的页面）。
Future<List<String>> _autoLeakClasses(
    McpToolContext ctx, String uri) async {
  final out = <String>{...await _stateClassesOfRoutes(ctx, uri)};
  out.addAll(await _projectStateClassNames(uri));
  return out.take(80).toList();
}

/// 本项目源码里的 State 子类名：getClassList 里库 URI 是 file: 且在项目根
/// 下的类。框架 / 依赖包（package: 或 pub-cache）自然被排除。
Future<List<String>> _projectStateClassNames(String uri) async {
  final vm = VmClient(uri);
  try {
    final iso = await vm.isolateId();
    final r =
        await vm.rawRpc('getIsolate', <String, Object?>{'isolateId': iso});
    final root = _rootOfIsolate(r);
    if (root == null) return const <String>[];
    final list = await vm.rawRpc('getClassList', <String, Object?>{'isolateId': iso});
    final out = <String>{};
    for (final c in (list['classes'] as List? ?? const <Object?>[])
        .whereType<Map>()) {
      final name = '${c['name'] ?? ''}';
      if (!name.endsWith('State')) continue;
      final lib = c['library'];
      final lu = lib is Map ? '${lib['uri'] ?? ''}' : '';
      if (!lu.startsWith('file:')) continue;
      String path;
      try {
        path = Uri.parse(lu).toFilePath();
      } catch (_) {
        continue;
      }
      if (!path.startsWith('$root/') || path.contains('/test/')) continue;
      out.add(name);
      if (out.length >= 80) break;
    }
    return out.toList()..sort();
  } catch (_) {
    // 拿不到类列表时只靠路由栈那份。
    return const <String>[];
  } finally {
    await vm.close();
  }
}

/// 从 getIsolate 结果推项目根（与 DebugHub 同一套判断：只信 rootLib，
/// package: 时用 libraries 里的 file: 脚本按 pubspec name 校验）。
String? _rootOfIsolate(Map<String, Object?> r) {
  final rootLib = r['rootLib'];
  final u = rootLib is Map ? '${rootLib['uri'] ?? ''}' : '';
  if (u.startsWith('file:')) return projectRootFromScriptUri(u);
  if (!u.startsWith('package:')) return null;
  final pkg = u.substring('package:'.length).split('/').first;
  if (pkg.isEmpty) return null;
  for (final l in (r['libraries'] as List? ?? const <Object?>[])
      .whereType<Map>()) {
    final lu = '${l['uri'] ?? ''}';
    if (!lu.startsWith('file:')) continue;
    final root = projectRootFromScriptUri(lu);
    if (root != null && readPubspecName(root) == pkg) return root;
  }
  return null;
}

/// 从 VM 的 rootLib 反推项目根（相对源码路径补全用）。
Future<String?> _projectRootOf(String uri) async {
  final vm = VmClient(uri);
  try {
    final iso = await vm.isolateId();
    final r =
        await vm.rawRpc('getIsolate', <String, Object?>{'isolateId': iso});
    return _rootOfIsolate(r);
  } catch (_) {
    // 推不出来就让调用方传绝对路径。
  } finally {
    await vm.close();
  }
  return null;
}

Future<String> _uriOf(McpToolContext ctx, Map<String, Object?> args) async {
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
  bool bodyOnly = false,
  String? rawBody,
}) async {
  try {
    return await ctx.guiBridge.json(
      path,
      params: q,
      method: method,
      bodyOnly: bodyOnly,
      rawBody: rawBody,
    );
  } on GuiBridgeError catch (e) {
    // 桌面端（macOS/Windows）没有 shared_prefs 概念，GUI 报「取不到包名」：
    // 直接告诉模型改道，别让它误以为是连接问题。
    if (e.message.contains('包名') || e.message.contains('shared_prefs')) {
      throw McpToolException(e.message,
          hint: 'shared_prefs 查看只支持 Android / iOS / 鸿蒙；'
              '桌面端可改用 xbume_eval 读 SharedPreferences，或用 xbume_db / xbume_sandbox');
    }
    throw McpToolException(e.message, hint: e.hint);
  }
}

Future<String> _guiText(
  McpToolContext ctx,
  String path, {
  Map<String, Object?> q = const <String, Object?>{},
  String method = 'GET',
}) async {
  try {
    return await ctx.guiBridge.text(path, params: q, method: method);
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

/// 从 VM 直接采一次性能快照：与 GUI /api/perf 同源指标，但不碰 `ext.*`
/// （部分会话对服务扩展不应答，GUI 会等满 30s 超时）。
Future<Map<String, Object?>> _perfSnapshotFromVm(
    String uri, int windowMs) async {
  final vm = VmClient(uri);
  try {
    final info = await vm.rawRpc('getVM');
    final iso = await vm.isolateId();
    final out = <String, Object?>{
      'ok': true,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'windowMs': windowMs,
      'vm': <String, Object?>{
        'name': info['name']?.toString() ?? '',
        'os': info['operatingSystem']?.toString() ?? '',
        'version': info['version']?.toString() ?? '',
        'isolates': (info['isolates'] as List?)?.length ?? 0,
      },
    };
    try {
      final mem = await vm.rawRpc(
          'getMemoryUsage', <String, Object?>{'isolateId': iso});
      out['heap'] = <String, Object?>{
        'used': (mem['heapUsage'] as num?)?.toInt() ?? 0,
        'capacity': (mem['heapCapacity'] as num?)?.toInt() ?? 0,
        'external': (mem['externalUsage'] as num?)?.toInt() ?? 0,
      };
    } catch (e) {
      out['heapError'] = '$e';
    }
    try {
      out['process'] =
          perfProcessMemory(await vm.rawRpc('getProcessMemoryUsage'));
    } catch (e) {
      out['processError'] = '$e';
    }
    try {
      final now = await vm.rawRpc('getVMTimelineMicros');
      final nowUs = (now['timestamp'] as num?)?.toInt() ?? 0;
      if (nowUs <= 0) throw '无法读取 VM 单调时钟';
      final extentUs = windowMs * 1000;
      Map<String, Object?> win() => <String, Object?>{
            'isolateId': iso,
            'timeOriginMicros': nowUs - extentUs,
            'timeExtentMicros': extentUs,
          };
      Map<String, Object?> samples;
      try {
        samples = await vm.rawRpc('getCpuSamples', win());
      } catch (e) {
        if (!'$e'.contains('Profiler is disabled')) rethrow;
        // debug 构建可运行时打开采样后再试一次（product 会被拒）。
        await vm.rawRpc(
            'setFlag', <String, Object?>{'name': 'profiler', 'value': 'true'});
        out['cpuAutoEnabled'] = true;
        samples = await vm.rawRpc('getCpuSamples', win());
      }
      out['cpu'] = perfCpuFromSamples(samples);
    } catch (e) {
      final err = '$e';
      out['cpuError'] = err.contains('Profiler is disabled')
          ? '该构建未开启 CPU 采样（运行时打开失败）'
          : err;
    }
    try {
      final detail =
          await vm.rawRpc('getIsolate', <String, Object?>{'isolateId': iso});
      out['isolate'] = <String, Object?>{
        'id': iso,
        'name': detail['name'],
        'runnable': detail['runnable'],
      };
    } catch (_) {}
    return out;
  } catch (e) {
    throw McpToolException('性能采样失败：$e',
        hint: '确认会话还在（xbume_sessions）；release 包没有 VM service');
  } finally {
    await vm.close();
  }
}

String _mb(Object? v) {
  final n = v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  if (n <= 0) return '0';
  if (n >= 1024 * 1024 * 1024) {
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }
  if (n >= 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
  if (n >= 1024) return '${(n / 1024).toStringAsFixed(0)}KB';
  return '${n.toInt()}B';
}
