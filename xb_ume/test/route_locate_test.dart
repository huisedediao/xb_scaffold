// 直连会话的启发式源码定位（无 VM）：候选类名生成 + 项目内类声明搜索。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/session/route_locate.dart';

void main() {
  group('routeClassCandidates', () {
    test('已经是类名时原样优先', () {
      expect(routeClassCandidates('UserDetailPage').first, 'UserDetailPage');
      // 原样类名排第一；后面仍保留后缀回退（路由名可能只报了类名前缀）。
      final c = routeClassCandidates('AppState');
      expect(c.first, 'AppState');
      expect(c, containsAll(<String>['AppStatePage', 'AppStateWidget']));
    });

    test('路径式路由名 → Page / Screen / View / Widget', () {
      final c = routeClassCandidates('/user/detail');
      expect(c, <String>[
        'UserDetailPage',
        'UserDetailScreen',
        'UserDetailView',
        'UserDetailWidget',
        'UserDetail',
      ]);
    });

    test('下划线 / 连字符都按分隔符拆', () {
      expect(routeClassCandidates('user_detail').first, 'UserDetailPage');
      expect(routeClassCandidates('user-detail').first, 'UserDetailPage');
    });

    test('空值与纯符号不出候选', () {
      expect(routeClassCandidates(''), isEmpty);
      expect(routeClassCandidates('///'), isEmpty);
    });
  });

  group('classDeclLineInSource', () {
    test('返回 1 起的声明行，支持修饰符', () {
      const src = 'import "x";\n\n'
          '@immutable\n'
          'class UserDetailPage extends StatelessWidget {\n'
          '}\n'
          'abstract class Repo {}\n';
      expect(classDeclLineInSource(src, 'UserDetailPage'), 4);
      expect(classDeclLineInSource(src, 'Repo'), 6);
      expect(classDeclLineInSource(src, 'Missing'), 0);
    });

    test('不会把前缀相同的类当成命中', () {
      const src = 'class UserDetailPageX {}\n';
      expect(classDeclLineInSource(src, 'UserDetailPage'), 0);
    });
  });

  group('findClassInProject', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xbume_route_locate_');
      Directory('${tmp.path}/lib/pages').createSync(recursive: true);
      File('${tmp.path}/lib/pages/detail.dart')
          .writeAsStringSync('// header\n\nclass UserDetailPage {}\n');
      // 生成文件不算命中（同一类名在 .g.dart 里出现时不应抢走结果）。
      File('${tmp.path}/lib/pages/detail.g.dart')
          .writeAsStringSync('class UserDetailPage {}\n');
      File('${tmp.path}/lib/pages/hidden.dart')
          .writeAsStringSync('class UserDetailScreen {}\n');
      Directory('${tmp.path}/lib/.cache').createSync(recursive: true);
      File('${tmp.path}/lib/.cache/x.dart')
          .writeAsStringSync('class ZzzPage {}\n');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('优先扫 lib/，候选优先级高于文件顺序', () {
      final hit = findClassInProject(
        tmp.path,
        <String>['UserDetailPage', 'UserDetailScreen'],
      );
      expect(hit, isNotNull);
      expect(hit!.className, 'UserDetailPage');
      expect(hit.file, endsWith('lib/pages/detail.dart'));
      expect(hit.line, 3);
      expect(hit.candidates.length, 2);
      expect(hit.scannedFiles, greaterThan(0));
    });

    test('首选候选没命中时退回次选', () {
      final hit = findClassInProject(
        tmp.path,
        <String>['NoSuchPage', 'UserDetailScreen'],
      );
      expect(hit?.className, 'UserDetailScreen');
    });

    test('跳过隐藏目录与生成文件；全不命中返回 null', () {
      expect(findClassInProject(tmp.path, <String>['ZzzPage']), isNull);
      expect(findClassInProject(tmp.path, <String>['Nope']), isNull);
      expect(findClassInProject('${tmp.path}/missing', <String>['A']), isNull);
      expect(findClassInProject(tmp.path, const <String>[]), isNull);
    });

    test('toJson 带 heuristic=true 与候选列表', () {
      final hit = findClassInProject(tmp.path, <String>['UserDetailScreen'])!;
      final j = hit.toJson();
      expect(j['heuristic'], isTrue);
      expect(j['className'], 'UserDetailScreen');
      expect(j['line'], 1);
      expect(j['candidates'], <String>['UserDetailScreen']);
    });
  });
}