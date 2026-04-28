import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:xb_simple_router/xb_simple_router.dart';

import 'error_test_isolate_stub.dart'
    if (dart.library.io) 'error_test_isolate_io.dart';

class ErrorTestPage extends StatelessWidget {
  const ErrorTestPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('异常测试')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _btn("1. Flutter build 异常", _flutterBuildError),
          _btn("2. 同步异常", _syncError),
          _btn("3. Future 异常", _futureError),
          _btn("4. async await 异常", _asyncAwaitError),
          _btn("5. Timer 异常", _timerError),
          _btn("6. isolate 异常", _isolateError),
          _btn("7. 手动抛异常", _manualThrow),
          _btn("8. 测试真实异常", _realThrow),
        ],
      ),
    );
  }

  Widget _btn(String title, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ElevatedButton(
        onPressed: onTap,
        child: Text(title),
      ),
    );
  }

  /// 1️⃣ Flutter UI 构建异常
  // ErrorTestPage 内
  void _flutterBuildError() {
    push(const CrashPage());
  }

  /// 2️⃣ 同步异常
  void _syncError() {
    throw Exception("🔥 sync error");
  }

  /// 3️⃣ Future 异常（未 catch）
  void _futureError() {
    Future.delayed(const Duration(milliseconds: 300), () {
      throw Exception("🔥 Future error");
    });
  }

  /// 4️⃣ async await 异常
  void _asyncAwaitError() async {
    await Future.delayed(const Duration(milliseconds: 300));
    throw Exception("🔥 async/await error");
  }

  /// 5️⃣ Timer 异常
  void _timerError() {
    Timer(const Duration(milliseconds: 300), () {
      throw Exception("🔥 Timer error");
    });
  }

  /// 6️⃣ isolate 异常（重点）
  void _isolateError() async {
    await triggerIsolateError();
  }

  /// 7️⃣ 手动抛异常（测试上报）
  void _manualThrow() {
    try {
      throw Exception("🔥 manual throw error");
    } catch (e, s) {
      Zone.current.handleUncaughtError(e, s);
    }
  }

  ///
  void _realThrow() {
    Map<String, dynamic> map = jsonDecode("hh + 22");
    xbError(map);
  }
}

class CrashPage extends StatelessWidget {
  const CrashPage({super.key});

  @override
  Widget build(BuildContext context) {
    throw Exception('🔥 CrashPage build error');
  }
}
