import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 内存 Map 模拟持久化存储
  final storage = <String, int>{};

  tearDown(() {
    storage.clear();
    XBThemeVM().resetForTest();
    XBThemeVM().bindIndexWriter(null);
  });

  List<XBThemeConfig> twoThemes() => [
        XBThemeConfig(primaryColor: Colors.blue, imgPrefix: 'assets/t1/'),
        XBThemeConfig(primaryColor: Colors.red, imgPrefix: 'assets/t2/'),
      ];

  testWidgets('changeTheme 正常切换并调用 writer 持久化', (tester) async {
    final written = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: XBScaffold(
        themeConfigs: twoThemes(),
        // writer 必须通过 widget 注入：XBScaffold 会覆写手动 bind 的钩子
        themeIndexWriter: (i) => written.add(i),
        child: const SizedBox(),
      ),
    ));
    await tester.pumpAndSettle();

    XBThemeVM().changeTheme(1);
    expect(XBThemeVM().themeIndex, 1);
    expect(written, [1], reason: 'writer 应被调用并收到新 index');
    expect(XBThemeVM().theme.colors.primary, Colors.red,
        reason: 'theme getter 应返回 index 1 的主题');
  });

  testWidgets('changeTheme 越界：debug 抛 AssertionError，主题保持不变', (tester) async {
    final written = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: XBScaffold(
        themeConfigs: twoThemes(),
        themeIndexWriter: (i) => written.add(i),
        child: const SizedBox(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(XBThemeVM().registeredThemeCount, 2, reason: '前置：主题已注册');

    // debug 下越界抛 AssertionError（release 下为 no-op + return）
    expect(() => XBThemeVM().changeTheme(99),
        throwsA(isA<AssertionError>()));
    expect(XBThemeVM().themeIndex, 0, reason: '越界时主题应保持不变');
    expect(written, isEmpty, reason: '越界时 writer 不应被调用');

    // theme getter 不再静默新建空主题，而是回落到 index 0
    expect(XBThemeVM().theme.colors.primary, Colors.blue,
        reason: '越界读取应回落到默认主题而非新建空主题');
  });

  testWidgets('XBScaffold 持久化闭环：writer 存储 → reader 回灌生效', (tester) async {
    // 第一阶段：changeTheme 时写入内存存储
    await tester.pumpWidget(MaterialApp(
      home: XBScaffold(
        themeConfigs: twoThemes(),
        themeIndexWriter: (i) async => storage['theme'] = i,
        child: const SizedBox(),
      ),
    ));
    await tester.pumpAndSettle();

    XBThemeVM().changeTheme(1);
    expect(storage['theme'], 1, reason: '切换主题后应自动持久化');

    // 第二阶段：模拟重启——重置内存态，换 key 强制重建 State（走 initState）
    XBThemeVM().resetForTest();
    expect(XBThemeVM().themeIndex, 0, reason: '重置后回到默认主题');

    await tester.pumpWidget(MaterialApp(
      home: XBScaffold(
        key: UniqueKey(),
        themeConfigs: twoThemes(),
        themeIndexReader: () async => storage['theme'],
        child: const SizedBox(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(XBThemeVM().themeIndex, 1,
        reason: '初始化完成后应回灌到持久化的主题 index');
    expect(XBThemeVM().theme.colors.primary, Colors.red);
  });

  testWidgets('reader 返回 null（首次启动）保持默认主题', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: XBScaffold(
        themeConfigs: [XBThemeConfig(primaryColor: Colors.blue, imgPrefix: 'a/')],
        themeIndexReader: () async => null,
        child: const SizedBox(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(XBThemeVM().themeIndex, 0);
  });

  testWidgets('reader 返回越界值（历史遗留脏数据）：静默忽略不崩溃', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: XBScaffold(
        themeConfigs: [XBThemeConfig(primaryColor: Colors.blue, imgPrefix: 'a/')],
        themeIndexReader: () async => 42,
        child: const SizedBox(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(XBThemeVM().themeIndex, 0, reason: '脏数据越界时应保持默认主题');
    expect(XBThemeVM().theme.colors.primary, Colors.blue);
  });

  testWidgets('reader 返回负数：静默忽略保持默认主题', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: XBScaffold(
        themeConfigs: [XBThemeConfig(primaryColor: Colors.blue, imgPrefix: 'a/')],
        themeIndexReader: () async => -1,
        child: const SizedBox(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(XBThemeVM().themeIndex, 0);
  });

  testWidgets('ensureDefaultThemeRegistered：首帧未注册时同步占位，不命中断言', (tester) async {
    // 模拟冷启动：pump 后首帧立即读主题（不等 pumpAndSettle）
    Object? themeReadError;
    await tester.pumpWidget(MaterialApp(
      home: XBScaffold(
        themeConfigs: twoThemes(),
        child: Builder(builder: (context) {
          // 此时异步 _initThemes 尚未完成，占位主题应已可用
          themeReadError = null;
          try {
            expect(XBThemeVM().theme.colors.primary, isNotNull);
            // ignore: avoid_catches_without_on_clauses
          } catch (e) {
            themeReadError = e;
          }
          return const SizedBox();
        }),
      ),
    ));
    expect(themeReadError, isNull,
        reason: '首帧读主题不应抛 "themes not registered yet"');

    // 异步初始化完成后，占位被完整主题覆盖
    await tester.pumpAndSettle();
    expect(XBThemeVM().theme.colors.primary, Colors.blue);
    expect(XBThemeVM().registeredThemeCount, 2);
  });
}
