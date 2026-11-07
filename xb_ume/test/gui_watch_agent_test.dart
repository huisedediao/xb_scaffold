// 直连会话的 Watch：添加校验在 GuiState（可实例化），前端直连行只能源码级断言
// （脚本内联在 ide_gui.dart 的 HTML 字符串里，与 gui_timeline_clear_test 同思路）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/ide_gui.dart' as gui;

void main() {
  group('addWatch 直连类型校验', () {
    final state = gui.GuiState();
    const vm = 'ws://127.0.0.1:8888/ws';
    const agent = 'http://127.0.0.1:8889';

    test('inspect / file 只接受直连会话', () {
      final r1 = state.addWatch(<String, Object?>{
        'uri': vm,
        'kind': 'inspect',
        'targetId': 'demo',
      });
      expect(r1['ok'], isFalse);
      expect('${r1['error']}', contains('只支持直连会话'));
      final r2 = state.addWatch(<String, Object?>{
        'uri': vm,
        'kind': 'file',
        'expr': '/tmp/a.log',
      });
      expect(r2['ok'], isFalse);
    });

    test('inspect 要 inspectable id；file 要路径；expr 可空', () {
      final a = state.addWatch(<String, Object?>{
        'uri': agent,
        'kind': 'inspect',
        'expr': 'count',
      });
      expect(a['ok'], isFalse);
      expect('${a['error']}', contains('inspectable id'));
      final b = state.addWatch(<String, Object?>{
        'uri': agent,
        'kind': 'file',
      });
      expect(b['ok'], isFalse);
      expect('${b['error']}', contains('文件路径'));
      // 空 expr = 监听整棵树，允许。
      final c = state.addWatch(<String, Object?>{
        'uri': agent,
        'kind': 'inspect',
        'targetId': 'demo-memory',
        'intervalMs': 60000,
      });
      expect(c['ok'], isTrue);
      expect((c['item'] as Map)['kind'], 'inspect');
      expect((c['item'] as Map)['label'], contains('整棵树'));
      state.removeWatch('${(c['item'] as Map)['id']}');
    });

    test('直连条件语法在添加时就被拒绝，不留到轮询里反复报错', () {
      final r = state.addWatch(<String, Object?>{
        'uri': agent,
        'kind': 'inspect',
        'targetId': 'demo-memory',
        'condition': 'a && b',
      });
      expect(r['ok'], isFalse);
      expect('${r['error']}', contains('value'));
      final ok = state.addWatch(<String, Object?>{
        'uri': agent,
        'kind': 'inspect',
        'targetId': 'demo-memory',
        'condition': 'value > 10',
        'intervalMs': 60000,
      });
      expect(ok['ok'], isTrue);
      state.removeWatch('${(ok['item'] as Map)['id']}');
    });
  });

  group('前端直连 Watch 入口', () {
    final src = File('bin/ide_gui.dart').readAsStringSync();

    test('VM 行与直连行分开，直连行按 inspectable / fs 置灰', () {
      expect(src, contains('id="in-watch-vm"'));
      expect(src, contains('id="in-watch-agent"'));
      expect(src, contains('id="in-watch-store" data-need-caps="inspectable"'));
      expect(src, contains('id="in-watch-file"'));
      expect(src, contains('data-need-caps="fs"'));
      // 整块不再统一按 debug 置灰（否则直连行也一起点不动）。
      expect(src, isNot(contains('<div class="inwatch" data-need-caps="debug">')));
    });

    test('会话切换 / 进入 Tab 都刷新直连行显示', () {
      expect(src, contains('if (typeof inWatchMode === \'function\') inWatchMode();'));
      expect(src, contains("function inRefresh(){\n  if (!inActive()) return;\n  inWatchMode();"));
    });

    test('注册表加载顺带填充 inspectable 下拉框', () {
      expect(src, contains("var sel = document.getElementById('in-watch-store');"));
      expect(src, contains('sel.innerHTML = (d.items || []).map('));
    });
  });
}