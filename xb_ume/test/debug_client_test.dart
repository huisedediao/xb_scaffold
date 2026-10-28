// 断点核心的单测：
// - 脚本 URI 候选 / 反解（file: 与 package: 两种写法）
// - Breakpoint / Frame / Debug 事件的解析
// - 用最小假 VM service（WebSocket + JSON-RPC）跑通：订阅 Debug 流、设断点、
//   条件不命中自动 resume、栈与步进参数。真实断点命中走 macOS example 端到端。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/debug/debug_client.dart';

void main() {
  group('breakpointScriptUriCandidates', () {
    test('项目内 lib/ 下的文件同时给 file: 与 package:', () {
      final out = breakpointScriptUriCandidates(
        '/tmp/proj/lib/src/a.dart',
        projectRoot: '/tmp/proj',
        packageName: 'app',
      );
      expect(out, contains('file:///tmp/proj/lib/src/a.dart'));
      expect(out, contains('package:app/src/a.dart'));
    });

    test('项目外的文件只有 file:（不猜 package）', () {
      final out = breakpointScriptUriCandidates(
        '/tmp/other/lib/a.dart',
        projectRoot: '/tmp/proj',
        packageName: 'app',
      );
      expect(out, <String>['file:///tmp/other/lib/a.dart']);
    });

    test('lib/ 之外的路径不生成 package: URI', () {
      final out = breakpointScriptUriCandidates(
        '/tmp/proj/test/a_test.dart',
        projectRoot: '/tmp/proj',
        packageName: 'app',
      );
      expect(out.any((u) => u.startsWith('package:')), isFalse);
    });

    test('空格路径按 URI 规则编码', () {
      final out = breakpointScriptUriCandidates('/tmp/my app/lib/a.dart');
      expect(out.single, 'file:///tmp/my%20app/lib/a.dart');
    });

    test('空路径返回空表', () {
      expect(breakpointScriptUriCandidates('   '), isEmpty);
    });

    test('相对路径按当前目录补全', () {
      final out = breakpointScriptUriCandidates('lib/main.dart');
      expect(out.single, contains(Uri.file(Directory.current.path).path));
      expect(out.single, endsWith('/lib/main.dart'));
    });
  });

  group('debugScriptUriToPath', () {
    test('file: URI 还原成本机路径', () {
      expect(
        debugScriptUriToPath('file:///tmp/my%20app/lib/a.dart'),
        '/tmp/my app/lib/a.dart',
      );
    });

    test('本项目的 package: URI 还原到 <root>/lib', () {
      expect(
        debugScriptUriToPath(
          'package:app/src/a.dart',
          projectRoot: '/tmp/proj',
          packageName: 'app',
        ),
        '/tmp/proj/lib/src/a.dart',
      );
    });

    test('别的包 / dart: / 缺项目根返回 null', () {
      expect(
        debugScriptUriToPath('package:dio/dio.dart',
            projectRoot: '/tmp/proj', packageName: 'app'),
        isNull,
      );
      expect(debugScriptUriToPath('dart:core'), isNull);
      expect(debugScriptUriToPath('package:app/main.dart'), isNull);
    });
  });

  group('pickMainIsolate', () {
    test('优先 name == main', () {
      expect(
        pickMainIsolate(<Object?>[
          <String, Object?>{'id': 'isolates/2', 'name': 'worker'},
          <String, Object?>{'id': 'isolates/1', 'name': 'main'},
        ]),
        'isolates/1',
      );
    });

    test('没有 main 时取第一个；空表返回 null', () {
      expect(
        pickMainIsolate(<Object?>[
          <String, Object?>{'id': 'isolates/9', 'name': 'x'},
        ]),
        'isolates/9',
      );
      expect(pickMainIsolate(const <Object?>[]), isNull);
      expect(pickMainIsolate(null), isNull);
    });
  });

  group('parseBreakpoint', () {
    test('已解析断点取 SourceLocation 的 script.uri', () {
      final bp = parseBreakpoint(<String, Object?>{
        'id': 'breakpoints/1',
        'resolved': true,
        'enabled': true,
        'location': <String, Object?>{
          'type': 'SourceLocation',
          'script': <String, Object?>{
            'type': 'ScriptRef',
            'uri': 'file:///tmp/proj/lib/main.dart',
          },
          'line': 12,
          'column': 5,
        },
      });
      expect(bp, isNotNull);
      expect(bp!.id, 'breakpoints/1');
      expect(bp.resolved, isTrue);
      expect(bp.scriptUri, 'file:///tmp/proj/lib/main.dart');
      expect(bp.line, 12);
      expect(bp.column, 5);
    });

    test('未解析断点取 UnresolvedSourceLocation.scriptUri，enabled 默认 true', () {
      final bp = parseBreakpoint(<String, Object?>{
        'id': 'breakpoints/2',
        'resolved': false,
        'location': <String, Object?>{
          'type': 'UnresolvedSourceLocation',
          'scriptUri': 'package:app/main.dart',
          'line': 3,
        },
      });
      expect(bp!.scriptUri, 'package:app/main.dart');
      expect(bp.resolved, isFalse);
      expect(bp.enabled, isTrue);
    });

    test('缺 id 视为无效', () {
      expect(parseBreakpoint(<String, Object?>{'resolved': true}), isNull);
      expect(parseBreakpoint(null), isNull);
      expect(parseBreakpoint('x'), isNull);
    });
  });

  group('parseStack / parseFrame', () {
    test('取帧位置、函数名与局部变量', () {
      final frames = parseStack(<String, Object?>{
        'frames': <Object?>[
          <String, Object?>{
            'id': 'frames/0',
            'index': 0,
            'function': <String, Object?>{'name': 'build'},
            'location': <String, Object?>{
              'script': <String, Object?>{
                'uri': 'file:///tmp/proj/lib/main.dart',
              },
              'line': 42,
              'column': 7,
            },
            'vars': <Object?>[
              <String, Object?>{
                'name': 'count',
                'value': <String, Object?>{
                  'kind': 'Int',
                  'valueAsString': '3',
                  // 真机 VM 把类名放在 class.name（不是 classRef）。
                  'class': <String, Object?>{'name': 'int'},
                  'id': 'objects/1',
                },
              },
              <String, Object?>{
                'name': 'user',
                'value': <String, Object?>{
                  'kind': 'PlainInstance',
                  'classRef': <String, Object?>{'name': 'User'},
                },
              },
            ],
          },
        ],
      });
      expect(frames, hasLength(1));
      final f = frames.single;
      expect(f.function, 'build');
      expect(f.line, 42);
      expect(f.vars.map((v) => v.name), <String>['count', 'user']);
      expect(f.vars.first.value, '3');
      expect(f.vars.first.type, 'int');
      expect(f.vars.first.objectId, 'objects/1');
      expect(f.vars.last.value, 'Instance of User');
    });

    test('没有 frames 的响应返回空表', () {
      expect(parseStack(<String, Object?>{'type': 'Stack'}), isEmpty);
      expect(parseStack(null), isEmpty);
    });
  });

  group('parseDebugEvent', () {
    test('PauseBreakpoint：带栈顶帧与命中断点', () {
      final e = parseDebugEvent(<String, Object?>{
        'kind': 'PauseBreakpoint',
        'isolateId': 'isolates/1',
        'pauseBreakpoints': <Object?>[
          <String, Object?>{
            'id': 'breakpoints/1',
            'resolved': true,
            'location': <String, Object?>{
              'script': <String, Object?>{'uri': 'package:app/main.dart'},
              'line': 10,
            },
          },
        ],
        'topFrame': <String, Object?>{
          'id': 'frames/0',
          'index': 0,
          'function': <String, Object?>{'name': 'main'},
          'location': <String, Object?>{
            'script': <String, Object?>{'uri': 'package:app/main.dart'},
            'line': 10,
          },
        },
      });
      expect(e!.kind, DebugEventKind.pause);
      expect(e.isPause, isTrue);
      expect(e.isolateId, 'isolates/1');
      expect(e.pause!.fromBreakpoint, isTrue);
      expect(e.pause!.breakpointIds, <String>['breakpoints/1']);
      expect(e.pause!.topFrame!.function, 'main');
      expect(e.pause!.scriptUri, 'package:app/main.dart');
      expect(e.pause!.line, 10);
    });

    test('PauseException：异常值可读', () {
      final e = parseDebugEvent(<String, Object?>{
        'kind': 'PauseException',
        'isolateId': 'isolates/1',
        'exception': <String, Object?>{
          'kind': 'PlainInstance',
          'valueAsString': 'Bad state: boom',
          'classRef': <String, Object?>{'name': 'StateError'},
        },
      });
      expect(e!.pause!.fromException, isTrue);
      expect(e.pause!.exception, 'Bad state: boom');
      expect(e.message, 'Bad state: boom');
    });

    test('Resume / BreakpointResolved / 未知 kind', () {
      expect(
        parseDebugEvent(<String, Object?>{'kind': 'Resume'})!.kind,
        DebugEventKind.resume,
      );
      final resolved = parseDebugEvent(<String, Object?>{
        'kind': 'BreakpointResolved',
        'breakpoint': <String, Object?>{
          'id': 'breakpoints/7',
          'resolved': true,
          'location': <String, Object?>{
            'script': <String, Object?>{'uri': 'file:///a.dart'},
            'line': 1,
          },
        },
      });
      expect(resolved!.kind, DebugEventKind.breakpointResolved);
      expect(resolved.breakpoint!.id, 'breakpoints/7');
      expect(
        parseDebugEvent(<String, Object?>{'kind': 'Whatever'})!.kind,
        DebugEventKind.unknown,
      );
      expect(parseDebugEvent(null), isNull);
    });
  });

  group('describeInstanceRef / DebugStep.wire', () {
    test('值优先 valueAsString，其次 classRef', () {
      expect(
        describeInstanceRef(<String, Object?>{
          'kind': 'String',
          'valueAsString': 'hi',
        }),
        'hi',
      );
      expect(
        describeInstanceRef(<String, Object?>{'kind': 'String'}),
        '""',
      );
      expect(
        describeInstanceRef(<String, Object?>{'kind': 'Null'}),
        'null',
      );
      expect(
        describeInstanceRef(<String, Object?>{
          'type': 'Error',
          'message': 'not a bool',
        }),
        'not a bool',
      );
    });

    test('步进映射到 VM 的 Into/Over/Out', () {
      expect(DebugStep.into.wire, 'Into');
      expect(DebugStep.over.wire, 'Over');
      expect(DebugStep.out.wire, 'Out');
    });
  });

  group('DebugClient（假 VM service）', () {
    late _FakeVm vm;
    late DebugClient client;

    setUp(() async {
      vm = await _FakeVm.start();
      client = DebugClient(
        vm.wsUrl,
        projectRoot: '/tmp/proj',
        packageName: 'app',
      );
    });

    tearDown(() async {
      await client.close();
      await vm.close();
    });

    test('连接后订阅 Debug 流并解析主 isolate', () async {
      await client.connect();
      expect(vm.calls.any((c) => c['method'] == 'streamListen'), isTrue);
      expect(vm.calls.lastWhere((c) => c['method'] == 'streamListen')['params'],
          <String, Object?>{'streamId': 'Debug'});
      expect(await client.isolateId(), 'isolates/1');
      expect(await client.isolateId(), 'isolates/1');
      expect(vm.calls.where((c) => c['method'] == 'getVM'), hasLength(1));
    });

    test('设断点优先用已加载的 package: URI，并带条件登记', () async {
      await client.connect();
      final bp = await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'count > 2',
      );
      expect(bp.id, 'breakpoints/1');
      expect(bp.condition, 'count > 2');
      final call = vm.calls.lastWhere(
          (c) => c['method'] == 'addBreakpointWithScriptUri');
      final params = call['params']! as Map<String, Object?>;
      expect(params['scriptUri'], 'package:app/main.dart');
      expect(params['line'], 12);
      expect(client.breakpoints.single.condition, 'count > 2');
    });

    test('条件为 false：自动 resume 并回 conditionMissed，不暴露暂停', () async {
      await client.connect();
      await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'count > 2',
      );
      vm.onCall = (method, params) async {
        if (method == 'evaluateInFrame') {
          return <String, Object?>{
            'type': '@Instance',
            'kind': 'Bool',
            'valueAsString': 'false',
          };
        }
        return null; // 其余走默认
      };
      final events = <DebugEvent>[];
      final sub = client.events.listen(events.add);
      addTearDown(sub.cancel);

      vm.pushEvent(_pauseBreakpointEvent(line: 12, bpId: 'breakpoints/1'));
      await _until(() =>
          events.any((e) => e.kind == DebugEventKind.conditionMissed));

      final evaluate =
          vm.calls.lastWhere((c) => c['method'] == 'evaluateInFrame')['params']!
              as Map<String, Object?>;
      expect(evaluate['expression'], 'count > 2');
      expect(evaluate['frameIndex'], 0);
      expect(evaluate['disableBreakpoints'], isTrue);
      expect(vm.calls.any((c) => c['method'] == 'resume'), isTrue);
      expect(events.any((e) => e.kind == DebugEventKind.pause), isFalse);
      expect(client.paused, isFalse);
    });

    test('条件求值失败：保持暂停并把原因带出来', () async {
      await client.connect();
      await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'bad ==',
      );
      vm.onCall = (method, params) async {
        if (method == 'evaluateInFrame') {
          return <String, Object?>{
            'type': 'Error',
            'message': 'Expression compilation error',
          };
        }
        return null;
      };
      final paused = client.events
          .firstWhere((e) => e.kind == DebugEventKind.pause)
          .timeout(const Duration(seconds: 3));

      vm.pushEvent(_pauseBreakpointEvent(line: 12, bpId: 'breakpoints/1'));
      final event = await paused;
      expect(event.message, contains('条件求值失败'));
      expect(event.message, contains('Expression compilation error'));
      expect(client.paused, isTrue);
      await client.resume();
    });

    test('Pause 事件的 topFrame 不带 vars：先 getStack 补帧再判条件', () async {
      await client.connect();
      await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'count == 1',
      );
      vm.onCall = (method, params) async {
        if (method == 'evaluateInFrame') {
          return <String, Object?>{
            'type': '@Instance',
            'kind': 'Bool',
            'valueAsString': 'true',
          };
        }
        return null;
      };
      final paused = client.events
          .firstWhere((e) => e.kind == DebugEventKind.pause)
          .timeout(const Duration(seconds: 3));

      vm.pushEvent(_pauseBreakpointEvent(
        line: 12,
        bpId: 'breakpoints/1',
        withVars: false,
      ));
      final event = await paused;
      // 补帧后事件里拿到的是 getStack 的真实帧（带变量）。
      expect(event.pause!.topFrame!.index, 0);
      expect(event.pause!.topFrame!.vars.single.name, 'count');
      final evaluate = vm.calls
          .lastWhere((c) => c['method'] == 'evaluateInFrame')['params']! as Map<String, Object?>;
      expect(evaluate['frameIndex'], 0);
      expect(vm.calls.where((c) => c['method'] == 'getStack'), isNotEmpty);

      await client.evaluateInFrame(0, 'count');
      final second = vm.calls
          .lastWhere((c) => c['method'] == 'evaluateInFrame')['params']! as Map<String, Object?>;
      expect(second['frameIndex'], 0);
      expect(second['disableBreakpoints'], isTrue);
      await client.resume();
    });

    test('条件为 true：保持暂停，栈可读，步进参数正确', () async {
      await client.connect();
      await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'count > 2',
      );
      vm.onCall = (method, params) async {
        if (method == 'evaluateInFrame') {
          return <String, Object?>{
            'type': '@Instance',
            'kind': 'Bool',
            'valueAsString': 'true',
          };
        }
        return null;
      };
      final paused = client.events
          .firstWhere((e) => e.kind == DebugEventKind.pause)
          .timeout(const Duration(seconds: 3));

      vm.pushEvent(_pauseBreakpointEvent(line: 12, bpId: 'breakpoints/1'));
      final event = await paused;
      expect(event.pause!.topFrame!.function, 'main');
      expect(client.paused, isTrue);
      expect(client.currentPause!.line, 12);

      final frames = await client.stack();
      expect(frames.single.vars.single.name, 'count');
      expect(frames.single.vars.single.value, '1');

      await client.resume(step: DebugStep.over);
      final resume = vm.calls.lastWhere((c) => c['method'] == 'resume')['params']!
          as Map<String, Object?>;
      expect(resume['step'], 'Over');
      expect(client.paused, isFalse);
    });

    test('断点事件同步到本地清单；removeBreakpoint 清条件', () async {
      await client.connect();
      final bp = await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'x == 1',
      );
      vm.pushEvent(<String, Object?>{
        'kind': 'BreakpointResolved',
        'isolateId': 'isolates/1',
        'breakpoint': <String, Object?>{
          'id': bp.id,
          'resolved': true,
          'location': <String, Object?>{
            'script': <String, Object?>{'uri': 'package:app/main.dart'},
            'line': 13,
          },
        },
      });
      await _until(() =>
          client.breakpoints.single.line == 13 &&
          client.breakpoints.single.condition == 'x == 1');

      await client.removeBreakpoint(bp.id);
      expect(client.breakpoints, isEmpty);
      final removed = vm.calls.lastWhere(
          (c) => c['method'] == 'removeBreakpoint')['params']!
          as Map<String, Object?>;
      expect(removed['breakpointId'], bp.id);
    });

    test('热重启后 resetIsolate + reapplyBreakpoints 重新下发', () async {
      await client.connect();
      await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'x == 1',
      );
      vm.onCall = (method, params) async {
        if (method == 'getVM') {
          return <String, Object?>{
            'type': 'VM',
            'isolates': <Object?>[
              <String, Object?>{'id': 'isolates/2', 'name': 'main'},
            ],
          };
        }
        if (method == 'addBreakpointWithScriptUri') {
          return <String, Object?>{
            'type': 'Breakpoint',
            'id': 'breakpoints/9',
            'resolved': true,
            'enabled': true,
            'location': <String, Object?>{
              'script': <String, Object?>{
                'uri': (params['scriptUri'] ?? '') as String,
              },
              'line': params['line'],
            },
          };
        }
        return null;
      };
      client.resetIsolate();
      final bps = await client.reapplyBreakpoints();
      expect(bps.single.id, 'breakpoints/9');
      expect(bps.single.condition, 'x == 1');
      final call = vm.calls.lastWhere(
          (c) => c['method'] == 'addBreakpointWithScriptUri');
      final params = call['params']! as Map<String, Object?>;
      expect(params['isolateId'], 'isolates/2');
      expect(params['line'], 12);
    });
  });
}

/// PauseBreakpoint 事件样例（带一个命中断点、一个栈顶帧、一个局部变量）。
Map<String, Object?> _pauseBreakpointEvent({
  required int line,
  required String bpId,
  bool withVars = true,
}) =>
    <String, Object?>{
      'kind': 'PauseBreakpoint',
      'isolateId': 'isolates/1',
      'pauseBreakpoints': <Object?>[
        <String, Object?>{
          'id': bpId,
          'resolved': true,
          'location': <String, Object?>{
            'script': <String, Object?>{'uri': 'package:app/main.dart'},
            'line': line,
          },
        },
      ],
      'topFrame': <String, Object?>{
        // 真机的 Pause 事件 topFrame 只有位置：没有 id，也不带 vars。
        'index': 0,
        'function': <String, Object?>{'name': 'main'},
        'location': <String, Object?>{
          'script': <String, Object?>{'uri': 'package:app/main.dart'},
          'line': line,
        },
        'vars': withVars
            ? <Object?>[
                <String, Object?>{
                  'name': 'count',
                  'value': <String, Object?>{
                    'kind': 'Int',
                    'valueAsString': '1',
                    'classRef': <String, Object?>{'name': 'int'},
                  },
                },
              ]
            : null,
      },
    };

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待条件超时');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 最小假 VM service：一个 /ws 端点 + JSON-RPC 默认响应 + 主动推 Debug 事件。
class _FakeVm {
  _FakeVm._(this._server);

  final HttpServer _server;
  final List<WebSocket> _sockets = <WebSocket>[];

  /// 已收到的调用（method + params），断言用。
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  /// 覆盖默认响应；返回 null 表示用默认。
  Future<Map<String, Object?>?> Function(
    String method,
    Map<String, Object?> params,
  )? onCall;

  static Future<_FakeVm> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final vm = _FakeVm._(server);
    server.listen((req) async {
      if (req.uri.path != '/ws') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      vm._sockets.add(ws);
      ws.listen((data) => unawaited(vm._handle(ws, data as String)));
    });
    return vm;
  }

  String get wsUrl => 'ws://127.0.0.1:${_server.port}/ws';

  Future<void> close() async {
    for (final ws in _sockets) {
      await ws.close();
    }
    _sockets.clear();
    await _server.close(force: true);
  }

  /// 主动推一条 Debug 事件。
  void pushEvent(Map<String, Object?> event) {
    final message = jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'method': 'streamNotify',
      'params': <String, Object?>{
        'streamId': 'Debug',
        'event': event,
      },
    });
    for (final ws in _sockets) {
      ws.add(message);
    }
  }

  Future<void> _handle(WebSocket ws, String data) async {
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final method = decoded['method']?.toString() ?? '';
    final params = <String, Object?>{};
    final rawParams = decoded['params'];
    if (rawParams is Map) {
      rawParams.forEach((k, v) => params[k.toString()] = v);
    }
    calls.add(<String, Object?>{'method': method, 'params': params});

    Map<String, Object?>? result;
    if (onCall != null) result = await onCall!(method, params);
    result ??= _defaultResponse(method, params);
    final id = decoded['id'];
    if (id == null) return;
    ws.add(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    }));
  }

  Map<String, Object?> _defaultResponse(
    String method,
    Map<String, Object?> params,
  ) {
    switch (method) {
      case 'getVM':
        return <String, Object?>{
          'type': 'VM',
          'isolates': <Object?>[
            <String, Object?>{'id': 'isolates/1', 'name': 'main'},
          ],
        };
      case 'getScripts':
        return <String, Object?>{
          'type': 'ScriptList',
          'scripts': <Object?>[
            <String, Object?>{'id': 'scripts/1', 'uri': 'package:app/main.dart'},
          ],
        };
      case 'addBreakpointWithScriptUri':
        return <String, Object?>{
          'type': 'Breakpoint',
          'id': 'breakpoints/1',
          'resolved': true,
          'enabled': true,
          'location': <String, Object?>{
            'type': 'SourceLocation',
            'script': <String, Object?>{
              'type': 'ScriptRef',
              'uri': params['scriptUri'],
            },
            'line': params['line'],
          },
        };
      case 'getStack':
        return <String, Object?>{
          'type': 'Stack',
          'frames': <Object?>[
            <String, Object?>{
              'index': 0,
              'function': <String, Object?>{'name': 'main'},
              'location': <String, Object?>{
                'script': <String, Object?>{'uri': 'package:app/main.dart'},
                'line': 12,
              },
              'vars': <Object?>[
                <String, Object?>{
                  'name': 'count',
                  'value': <String, Object?>{
                    'kind': 'Int',
                    'valueAsString': '1',
                    'classRef': <String, Object?>{'name': 'int'},
                  },
                },
              ],
            },
          ],
        };
      case 'getIsolate':
        return <String, Object?>{
          'type': 'Isolate',
          'id': 'isolates/1',
          'breakpoints': <Object?>[],
        };
      case 'evaluateInFrame':
        return <String, Object?>{
          'type': '@Instance',
          'kind': 'Bool',
          'valueAsString': 'true',
        };
      default:
        return <String, Object?>{'type': 'Success'};
    }
  }
}
