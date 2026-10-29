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

  group('parseObjectFields（展开变量里的实例）', () {
    test('普通实例取 fields，名字取 decl.name', () {
      final r = parseObjectFields(<String, Object?>{
        'type': '@Instance',
        'kind': 'PlainInstance',
        'class': <String, Object?>{'name': '_DoorLockHomePageState'},
        'length': 2,
        'fields': <Object?>[
          <String, Object?>{
            'decl': <String, Object?>{'name': '_loading'},
            'value': <String, Object?>
                {'kind': 'Bool', 'valueAsString': 'true', 'id': 'objects/7'},
          },
          <String, Object?>{
            'decl': <String, Object?>{'name': '_lock'},
            'value': <String, Object?>{
              'kind': 'PlainInstance',
              'class': <String, Object?>{'name': 'DoorLock'},
              'id': 'objects/9',
            },
          },
        ],
      });
      expect(r.vars.map((v) => v.name), <String>['_loading', '_lock']);
      expect(r.vars.first.value, 'true');
      expect(r.vars.last.value, 'Instance of DoorLock');
      expect(r.vars.last.objectId, 'objects/9');
      expect(r.total, 2);
      expect(r.truncated, isFalse);
    });

    test('List 取 elements，名字是 [下标]，超出 length 标 truncated', () {
      final r = parseObjectFields(<String, Object?>{
        'type': '@Instance',
        'kind': 'List',
        'length': 5,
        'elements': <Object?>[
          <String, Object?>{'kind': 'Int', 'valueAsString': '1'},
          <String, Object?>{'kind': 'Int', 'valueAsString': '2'},
        ],
      });
      expect(r.vars.map((v) => v.name), <String>['[0]', '[1]']);
      expect(r.vars.map((v) => v.value), <String>['1', '2']);
      expect(r.total, 5);
      expect(r.truncated, isTrue);
    });

    test('Map 取 associations，名字是键的可读值', () {
      final r = parseObjectFields(<String, Object?>{
        'type': '@Instance',
        'kind': 'Map',
        'length': 1,
        'associations': <Object?>[
          <String, Object?>{
            'key': <String, Object?>{'kind': 'String', 'valueAsString': 'name'},
            'value': <String, Object?>{'kind': 'String', 'valueAsString': 'xb'},
          },
        ],
      });
      expect(r.vars, hasLength(1));
      expect(r.vars.single.name, 'name');
      expect(r.vars.single.value, 'xb');
    });

    test('Sentinel / 空响应不抛异常，返回空表', () {
      expect(
          parseObjectFields(<String, Object?>{'type': 'Sentinel'}).vars, isEmpty);
      expect(parseObjectFields(null).vars, isEmpty);
    });
  });

  group('字段归属（own / fw：把框架噪音和业务字段分开）', () {
    test('ownLibrary：dart:* / package:flutter* / 外部包不算我的，本包 / 项目内文件算', () {
      const pkg = 'xb_ume_example';
      const root = '/tmp/proj';
      bool own(String? u) =>
          ownLibrary(u, packageName: pkg, projectRoot: root);

      expect(own('dart:core'), isFalse);
      expect(own('package:flutter/src/foundation/change_notifier.dart'),
          isFalse);
      expect(own('package:$pkg/lib/src/page.dart'), isTrue);
      // 第三方依赖：按「只留自己项目」的口径也算不是我的
      expect(own('package:dio/src/dio.dart'), isFalse);
      expect(own('file:///tmp/proj/lib/a.dart'), isTrue);
      expect(own('file:///tmp/other/lib/a.dart'), isFalse);
      // 判断不出的一律当自己的：宁可多显示，不藏掉业务字段
      expect(own(null), isTrue);
      expect(own(''), isTrue);
      expect(ownLibrary('package:whatever/x.dart'), isTrue);
    });

    test('scanIntoValue：集合照常下钻，框架 / 依赖对象不下钻', () {
      const pkg = 'xb_ume_example';
      bool scan(String? lib, [String? kind]) =>
          scanIntoValue(lib, kind: kind, packageName: pkg);

      expect(scan('dart:core', 'List'), isTrue);
      expect(scan('dart:core', 'Map'), isTrue);
      expect(scan('dart:core', 'Set'), isTrue);
      // 框架对象（Element / RenderObject 子树）不下钻
      expect(scan('package:flutter/src/widgets/framework.dart', 'PlainInstance'),
          isFalse);
      expect(scan('package:$pkg/lib/model.dart', 'PlainInstance'), isTrue);
      expect(scan(null), isTrue);
    });

    test('parseObjectFields：带声明类库 → 框架字段标 own=false，框架对象标 fw=true', () {
      const flutterLib =
          'package:flutter/src/foundation/change_notifier.dart';
      const appLib = 'package:xb_ume_example/src/door_lock_controller.dart';
      Object? field(String name, String declLib, Map<String, Object?> value) =>
          <String, Object?>{
            'decl': <String, Object?>{
              'name': name,
              'owner': <String, Object?>{
                'name': 'ChangeNotifier',
                'library': <String, Object?>{'uri': declLib},
              },
            },
            'value': value,
          };

      final r = parseObjectFields(
        <String, Object?>{
          'type': '@Instance',
          'kind': 'PlainInstance',
          'fields': <Object?>[
            // ChangeNotifier 的监听器计数：和业务字段同名，但不该露出
            field('_count', flutterLib,
                <String, Object?>{'kind': 'Int', 'valueAsString': '1'}),
            field(
                '_listeners',
                flutterLib,
                <String, Object?>{
                  'kind': 'List',
                  'class': <String, Object?>{
                    'name': '_GrowableList',
                    'library': <String, Object?>{'uri': 'dart:core'},
                  },
                  'id': 'objects/3',
                }),
            field(
                'count',
                appLib,
                <String, Object?>{'kind': 'Int', 'valueAsString': '7'}),
            field(
                '_element',
                appLib,
                <String, Object?>{
                  'kind': 'PlainInstance',
                  'class': <String, Object?>{
                    'name': 'StatefulElement',
                    'library': <String, Object?>{
                      'uri': 'package:flutter/src/widgets/framework.dart',
                    },
                  },
                  'id': 'objects/9',
                }),
          ],
        },
        packageName: 'xb_ume_example',
      );
      final byName = <String, DebugVar>{
        for (final v in r.vars) v.name: v,
      };
      // 框架库里声明的：默认收起
      expect(byName['_count']!.own, isFalse);
      expect(byName['_listeners']!.own, isFalse);
      // 自己类里声明的：即使值是框架对象也保留，但扫描不往里钻
      expect(byName['count']!.own, isTrue);
      expect(byName['count']!.fw, isFalse);
      expect(byName['_element']!.own, isTrue);
      expect(byName['_element']!.fw, isTrue);
      // List 值不剪枝（里面往往装着自己的对象）
      expect(byName['_listeners']!.fw, isFalse);
    });

    test('parseObjectFields：拿不到库信息时 own=true、fw=false（不误藏）', () {
      final r = parseObjectFields(<String, Object?>{
        'type': '@Instance',
        'kind': 'PlainInstance',
        'fields': <Object?>[
          <String, Object?>{
            'decl': <String, Object?>{'name': 'page'},
            'value': <String, Object?>{'kind': 'Int', 'valueAsString': '1'},
          },
        ],
      });
      expect(r.vars.single.own, isTrue);
      expect(r.vars.single.fw, isFalse);
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
      // 真实 VM 给的是 ErrorRef（type 带 @）。
      expect(
        describeInstanceRef(<String, Object?>{
          'type': '@Error',
          'kind': 'CompileError',
          'message': 'Expression compilation error',
        }),
        'Expression compilation error',
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

    test('日志断点命中：求值输出 logpointHit 并自动 resume，不暴露暂停', () async {
      await client.connect();
      final bp = await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        logMessage: 'count',
      );
      expect(bp.logMessage, 'count');
      expect(client.breakpoints.single.logMessage, 'count');
      vm.onCall = (method, params) async {
        if (method == 'evaluateInFrame') {
          return <String, Object?>{
            'type': '@Instance',
            'kind': 'Int',
            'valueAsString': '7',
            'classRef': <String, Object?>{'name': 'int'},
          };
        }
        return null;
      };
      final events = <DebugEvent>[];
      final sub = client.events.listen(events.add);
      addTearDown(sub.cancel);

      vm.pushEvent(_pauseBreakpointEvent(line: 12, bpId: bp.id));
      await _until(() => events.any((e) => e.kind == DebugEventKind.logpointHit));

      final hit = events.lastWhere((e) => e.kind == DebugEventKind.logpointHit);
      expect(hit.message, contains('[logpoint]'));
      expect(hit.message, contains('main.dart:12'));
      expect(hit.message, contains('count => 7'));
      expect(vm.calls.any((c) => c['method'] == 'resume'), isTrue);
      expect(events.any((e) => e.kind == DebugEventKind.pause), isFalse);
      expect(client.paused, isFalse);
    });

    test('日志表达式写裸模板（i=\$i）：按字符串插值再试', () async {
      await client.connect();
      final bp = await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        logMessage: r'i=$i',
      );
      vm.onCall = (method, params) async {
        if (method != 'evaluateInFrame') return null;
        final expr = '${params['expression']}';
        // 裸模板不是合法表达式：只有被包成字符串字面量后才能求值。
        if (expr.startsWith("'")) {
          return <String, Object?>{
            'type': '@Instance',
            'kind': 'String',
            'valueAsString': 'i=7',
            'classRef': <String, Object?>{'name': 'String'},
          };
        }
        return <String, Object?>{'type': 'Error', 'message': 'syntax error'};
      };
      final events = <DebugEvent>[];
      final sub = client.events.listen(events.add);
      addTearDown(sub.cancel);

      vm.pushEvent(_pauseBreakpointEvent(line: 12, bpId: bp.id));
      await _until(() => events.any((e) => e.kind == DebugEventKind.logpointHit));
      final hit = events.lastWhere((e) => e.kind == DebugEventKind.logpointHit);
      expect(hit.message, contains('i=7'));
      expect(client.paused, isFalse);
    });

    test('日志断点求值失败：输出原因并继续，不把日志断点变成普通断点', () async {
      await client.connect();
      final bp = await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        logMessage: 'bad ==',
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
      final events = <DebugEvent>[];
      final sub = client.events.listen(events.add);
      addTearDown(sub.cancel);

      vm.pushEvent(_pauseBreakpointEvent(line: 12, bpId: bp.id));
      await _until(() => events.any((e) => e.kind == DebugEventKind.logpointHit));
      final hit = events.lastWhere((e) => e.kind == DebugEventKind.logpointHit);
      expect(hit.message, contains('求值失败'));
      expect(events.any((e) => e.kind == DebugEventKind.pause), isFalse);
      expect(vm.calls.any((c) => c['method'] == 'resume'), isTrue);
      expect(client.paused, isFalse);
    });

    test('条件 + 日志：条件为 false 时不打印，直接继续', () async {
      await client.connect();
      final bp = await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'count > 5',
        logMessage: 'count',
      );
      vm.onCall = (method, params) async {
        if (method == 'evaluateInFrame') {
          return <String, Object?>{
            'type': '@Instance',
            'kind': 'Bool',
            'valueAsString': 'false',
          };
        }
        return null;
      };
      final events = <DebugEvent>[];
      final sub = client.events.listen(events.add);
      addTearDown(sub.cancel);

      vm.pushEvent(_pauseBreakpointEvent(line: 12, bpId: bp.id));
      await _until(() =>
          events.any((e) => e.kind == DebugEventKind.conditionMissed));
      expect(events.any((e) => e.kind == DebugEventKind.logpointHit), isFalse);
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

    test('updateBreakpoint：改条件 / 日志，空白即清空，热重启重下发带回最新登记', () async {
      await client.connect();
      final bp = await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'x == 1',
      );
      final up = client.updateBreakpoint(bp.id, condition: 'x > 2', logMessage: 'x');
      expect(up.id, bp.id);
      expect(up.line, bp.line);
      expect(up.condition, 'x > 2');
      expect(up.logMessage, 'x');
      expect(client.breakpoints.single.logMessage, 'x');

      // 空白即清空（不换位置把条件 / 日志去掉）。
      final cleared = client.updateBreakpoint(bp.id, condition: '   ', logMessage: '');
      expect(cleared.condition, isNull);
      expect(cleared.logMessage, isNull);

      // 改回带日志，再模拟热重启：重下发要带最新登记（靠 _owned 同步）。
      client.updateBreakpoint(bp.id, condition: 'x > 2', logMessage: 'x');
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
      expect(bps.single.condition, 'x > 2');
      expect(bps.single.logMessage, 'x');

      expect(
        () => client.updateBreakpoint('breakpoints/404', condition: 'x'),
        throwsA(isA<DebugException>()),
      );
    });

    test('热重启后 resetIsolate + reapplyBreakpoints 重新下发', () async {
      await client.connect();
      await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'x == 1',
        logMessage: r'i=$i',
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
      expect(bps.single.logMessage, r'i=$i');
      final call = vm.calls.lastWhere(
          (c) => c['method'] == 'addBreakpointWithScriptUri');
      final params = call['params']! as Map<String, Object?>;
      expect(params['isolateId'], 'isolates/2');
      expect(params['line'], 12);
    });

    test('热重启期间 BreakpointRemoved 清空登记清单，靠快照仍能重下', () async {
      await client.connect();
      final bp = await client.addBreakpoint(
        path: '/tmp/proj/lib/main.dart',
        line: 12,
        condition: 'x == 1',
        logMessage: 'x',
      );
      expect(client.ownedBreakpointCount, 1);
      // 动手前留快照（真实流程里 launcher.hotReload 之前就取）。
      final snap = client.snapshotBreakpoints();

      // 旧 isolate 退出：VM 把该断点一起发 BreakpointRemoved。
      vm.pushEvent(<String, Object?>{
        'kind': 'BreakpointRemoved',
        'isolateId': 'isolates/1',
        'breakpoint': <String, Object?>{
          'id': bp.id,
          'resolved': true,
          'location': <String, Object?>{
            'script': <String, Object?>{'uri': 'package:app/main.dart'},
            'line': 12,
          },
        },
      });
      await _until(() => client.breakpoints.isEmpty);
      // 事件把「本客户端登记过的清单」也清了，这正是重启后断点丢失的原因。
      expect(client.ownedBreakpointCount, 0);

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
      final bps = await client.reapplyBreakpoints(from: snap);
      expect(bps.single.id, 'breakpoints/9');
      expect(bps.single.condition, 'x == 1');
      expect(bps.single.logMessage, 'x');
      expect(client.ownedBreakpointCount, 1);
      final params = vm.calls
          .lastWhere((c) => c['method'] == 'addBreakpointWithScriptUri')['params']!
          as Map<String, Object?>;
      expect(params['isolateId'], 'isolates/2');
      expect(params['line'], 12);
    });

    test('接入已在暂停中的会话时同步现场（GUI 重启 / 复用别人的调试）', () async {
      final pauseEvent = <String, Object?>{
        'kind': 'PauseBreakpoint',
        'isolateId': 'isolates/1',
        'pauseBreakpoints': <Object?>[
          <String, Object?>{
            'id': 'breakpoints/7',
            'resolved': true,
            'location': <String, Object?>{
              'script': <String, Object?>{
                'uri': 'package:flutter/src/material/theme_data.dart',
              },
              'line': 363,
            },
          },
        ],
        'topFrame': <String, Object?>{
          'index': 0,
          'function': <String, Object?>{'name': 'ThemeData'},
          'location': <String, Object?>{
            'script': <String, Object?>{
              'uri': 'package:flutter/src/material/theme_data.dart',
            },
            'line': 363,
          },
          'vars': <Object?>[
            <String, Object?>{
              'name': 'x',
              'value': <String, Object?>{'kind': 'Null'},
            },
          ],
        },
      };
      vm.onCall = (method, params) async {
        if (method == 'getIsolate') {
          return <String, Object?>{
            'type': 'Isolate',
            'id': 'isolates/1',
            'pauseEvent': pauseEvent,
          };
        }
        return null;
      };
      await client.connect();
      expect(client.paused, isFalse);
      final events = <DebugEvent>[];
      final sub = client.events.listen(events.add);
      await client.syncPause();
      await _until(() => events.isNotEmpty);
      expect(client.paused, isTrue);
      expect(client.currentPause!.line, 363);
      expect(client.currentPause!.topFrame!.function, 'ThemeData');
      expect(client.currentPause!.breakpointIds, <String>['breakpoints/7']);
      final ev = events.single;
      expect(ev.kind, DebugEventKind.pause);
      expect(ev.pause!.scriptUri,
          'package:flutter/src/material/theme_data.dart');
      await sub.cancel();
    });

    test('运行中（pauseEvent 不是 Pause*）保持未暂停、不推事件', () async {
      vm.onCall = (method, params) async => method == 'getIsolate'
          ? <String, Object?>{
              'type': 'Isolate',
              'id': 'isolates/1',
              'pauseEvent': <String, Object?>{'kind': 'Resume'},
            }
          : null;
      await client.connect();
      final events = <DebugEvent>[];
      final sub = client.events.listen(events.add);
      await client.syncPause();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.paused, isFalse);
      expect(events, isEmpty);
      await sub.cancel();
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
