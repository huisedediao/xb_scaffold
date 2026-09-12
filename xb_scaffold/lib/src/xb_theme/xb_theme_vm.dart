import 'dart:async';

import 'package:flutter/material.dart';
import 'xb_theme.dart';
export 'xb_theme.dart';

/// 主题索引持久化读取器：返回已存储的主题 index，未存储过返回 null
typedef XBThemeIndexReader = Future<int?> Function();

/// 主题索引持久化写入器
typedef XBThemeIndexWriter = FutureOr<void> Function(int themeIndex);

class XBThemeVM extends ChangeNotifier {
  static final XBThemeVM _singleton = XBThemeVM._internal();

  factory XBThemeVM() {
    return _singleton;
  }

  XBThemeVM._internal();

  final Map<int, XBTheme> _themeMap = {};

  /// 持久化钩子：由 XBScaffold(themeIndexWriter: ...) 注入
  XBThemeIndexWriter? _indexWriter;

  /// 供 XBScaffold 注入/更新持久化钩子（业务方不应直接调用）
  void bindIndexWriter(XBThemeIndexWriter? writer) {
    _indexWriter = writer;
  }

  /// 当前显示的主题的编号
  int _themeIndex = 0;
  int get themeIndex => _themeIndex;

  /// 已注册的主题数量（未完成初始化时为 0）
  int get registeredThemeCount => _themeMap.length;

  /// 获取主题
  ///
  /// 越界时返回默认主题（index 0）而非静默新建空主题；
  /// debug 下同时 assert 提示，便于尽早发现越界调用
  XBTheme get theme {
    assert(_themeMap.isNotEmpty, 'XBThemeVM: themes not registered yet. '
        'Themes are registered asynchronously by XBScaffold, '
        'avoid reading theme before the first frame completes.');
    final theme = _themeMap[_themeIndex] ?? _themeMap[0];
    return theme ?? XBTheme();
  }

  /// 修改主题
  ///
  /// 主题未注册完成（_themeMap 为空）时仅记录 index，
  /// 待初始化完成后的回灌会按最终 index 生效；
  /// 主题已注册但 index 越界时：保持当前主题不变，debug 下 assert 报错
  changeTheme(int themeIndex) {
    if (_themeMap.isNotEmpty && !_themeMap.containsKey(themeIndex)) {
      assert(false,
          'XBThemeVM.changeTheme: themeIndex $themeIndex out of range, '
          'registered indexes are ${_themeMap.keys.toList()..sort()}. '
          'Theme unchanged.');
      return;
    }
    if (themeIndex == _themeIndex && _themeMap.isNotEmpty) return;
    _themeIndex = themeIndex;
    notifyListeners();
    _indexWriter?.call(themeIndex);
  }

  /// 设置主题
  /// theme：主题
  /// themeIndex：主题编号
  setThemeForIndex(XBTheme theme, int themeIndex) {
    _themeMap[themeIndex] = theme;
    notifyListeners();
  }

  /// 供测试/重置使用：清空已注册主题
  @visibleForTesting
  void resetForTest() {
    _themeMap.clear();
    _themeIndex = 0;
    notifyListeners();
  }
}
