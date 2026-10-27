// 时间轴「清空」的行为约束：点一次就清掉当前视图里的全部事件，不弹二次
// 确认；清空后会话掉线（uri 变空）也不能让下限失效，否则已清空的日志会
// 重新冒出来。前端脚本内联在 ide_gui.dart 的 HTML 字符串里，只能做源码级
// 断言 —— 和 ide_deploy_deps_test.dart 同一套思路。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('bin/ide_gui.dart').readAsStringSync();

  /// 取出顶层函数体（从 `function name(` 到下一处行首的 `}`）。
  String fnBody(String name) {
    final start = source.indexOf('function $name(');
    expect(start, greaterThanOrEqualTo(0), reason: '未找到 function $name');
    final end = source.indexOf('\n}\n', start);
    expect(end, greaterThan(start), reason: 'function $name 未闭合');
    return source.substring(start, end);
  }

  test('tlClear 不再二次确认', () {
    expect(fnBody('tlClear'), isNot(contains('confirm(')));
  });

  test('tlClear 同时清服务端时间轴与监听', () {
    final body = fnBody('tlClear');
    expect(body, contains('/api/timeline/clear'));
    expect(body, contains('/api/watch/clear'));
  });

  test('五类事件与回填都受清空下限约束', () {
    // 只清路由/网络/监听时，页面上还留着一屏日志与异常，看起来就像没清空。
    final build = fnBody('tlBuild');
    for (final id in <String>[
      'tl-t-route',
      'tl-t-net',
      'tl-t-log',
      'tl-t-exc',
      'tl-t-watch',
    ]) {
      expect(build, contains(id), reason: 'tlBuild 缺少 $id 分支');
    }
    expect('tlBeforeFloor'.allMatches(build).length, greaterThanOrEqualTo(5),
        reason: '五类事件都要过 tlBeforeFloor');
    // 服务端清空失败或订阅重放时不能把旧事件 merge 回来。
    expect(fnBody('tlMerge'), contains('tlBeforeFloor'));
  });

  test('会话掉线时清空下限仍然生效', () {
    final body = fnBody('tlFloorMs');
    expect(body, contains('u && tlFloor.uri && u !== tlFloor.uri'),
        reason: '只在两个非空会话之间切换才失效，掉线不算切换');
  });
}
