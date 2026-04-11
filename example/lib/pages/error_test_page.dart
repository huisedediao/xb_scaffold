import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

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
  void _flutterBuildError() {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              throw Exception("🔥 Flutter build error");
            },
          ),
        ),
      ),
    );
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
    await Isolate.spawn(_isolateEntry, "test");
  }

  static void _isolateEntry(String msg) {
    throw Exception("🔥 Isolate error: $msg");
  }

  /// 7️⃣ 手动抛异常（测试上报）
  void _manualThrow() {
    try {
      throw Exception("🔥 manual throw error");
    } catch (e, s) {
      Zone.current.handleUncaughtError(e, s);
    }
  }
}
