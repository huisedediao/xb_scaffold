import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xb_network/xb_network.dart';

class XBNetworkTestPage extends StatefulWidget {
  const XBNetworkTestPage({super.key});

  @override
  State<XBNetworkTestPage> createState() => _XBNetworkTestPageState();
}

class _XBNetworkTestPageState extends State<XBNetworkTestPage> {
  static const String _demoBaseUrl = 'https://postman-echo.com';
  final List<String> _logs = <String>[];
  bool _loading = false;

  @override
  void dispose() {
    XBDioConfig.reset();
    super.dispose();
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[${DateTime.now().toIso8601String()}] $message');
      if (_logs.length > 60) {
        _logs.removeLast();
      }
    });
  }

  Future<void> _run(String action, Future<void> Function() task) async {
    if (_loading) return;
    setState(() {
      _loading = true;
    });
    try {
      _addLog('开始执行: $action');
      await task();
      _addLog('执行完成: $action');
    } catch (e) {
      _addLog('执行失败: $action, err=$e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  String _pretty(dynamic data) {
    try {
      if (data is Map || data is List) {
        return const JsonEncoder.withIndent('  ').convert(data);
      }
      return '$data';
    } catch (_) {
      return '$data';
    }
  }

  void _initDio() {
    XBDioConfig.init(
      baseUrl: _demoBaseUrl,
      connectTimeout: 10,
      receiveTimeout: 10,
      sendTimeout: 10,
      force: true,
    );
    _addLog('XBDioConfig.init 完成, baseUrl=$_demoBaseUrl');
  }

  void _resetDio() {
    XBDioConfig.reset();
    _addLog('XBDioConfig.reset 完成');
  }

  Future<void> _testGet() async {
    if (!XBDioConfig.isInitialized) {
      _addLog('请先执行 init');
      return;
    }
    final data = await XBHttp.get<Map<String, dynamic>>(
      '/get',
      queryParams: {
        'source': 'xb_network_demo',
        'ts': DateTime.now().millisecondsSinceEpoch
      },
    );
    _addLog('GET /get 返回:\n${_pretty(data)}');
  }

  Future<void> _testPost() async {
    if (!XBDioConfig.isInitialized) {
      _addLog('请先执行 init');
      return;
    }
    final data = await XBHttp.post<Map<String, dynamic>>(
      '/post',
      bodyParams: {
        'action': 'xb_network_post_demo',
        'time': DateTime.now().toIso8601String(),
      },
    );
    _addLog('POST /post 返回:\n${_pretty(data)}');
  }

  Widget _btn(String title, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ElevatedButton(
        onPressed: _loading ? null : onTap,
        child: Text(title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('xb_network 测试页')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '说明：先 init，再执行 GET/POST。离开页面会自动 reset。',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          _btn('1. init(baseUrl: https://postman-echo.com)', _initDio),
          _btn('2. GET /get', () {
            _run('GET /get', _testGet);
          }),
          _btn('3. POST /post', () {
            _run('POST /post', _testPost);
          }),
          _btn('4. reset', _resetDio),
          _btn('5. 清空日志', () {
            setState(_logs.clear);
          }),
          if (_loading) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 14),
          const Text(
            '执行日志（最新在上）',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (_logs.isEmpty)
            const Text('暂无日志，点击上方按钮开始测试。')
          else
            ..._logs.map(
              (e) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(e),
              ),
            ),
        ],
      ),
    );
  }
}
