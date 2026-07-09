import 'package:flutter/material.dart';
import 'package:xb_echo_logger/xb_echo_logger.dart';

class XBEchoLoggerTestPage extends StatefulWidget {
  const XBEchoLoggerTestPage({super.key});

  @override
  State<XBEchoLoggerTestPage> createState() => _XBEchoLoggerTestPageState();
}

class _XBEchoLoggerTestPageState extends State<XBEchoLoggerTestPage> {
  final _echoHostController =
      TextEditingController(text: 'http://144.168.61.190:3000');
  final _appIdController =
      TextEditingController(text: 'com.example.echo_test');
  final _echoContentController =
      TextEditingController(text: '这是一条测试日志');
  final _errContentController =
      TextEditingController(text: '这是一条测试错误');

  final List<String> _logs = [];
  bool _initialized = false;
  int _errorSendCount = 0;

  @override
  void dispose() {
    _echoHostController.dispose();
    _appIdController.dispose();
    _echoContentController.dispose();
    _errContentController.dispose();
    super.dispose();
  }

  void _addLog(String msg) {
    setState(() {
      final time =
          '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}';
      _logs.insert(0, '[$time] $msg');
      if (_logs.length > 100) {
        _logs.removeLast();
      }
    });
  }

  Future<void> _initLogger() async {
    try {
      await XBEchoLogger.init(
        config: EchoConfig(
          echoHost: _echoHostController.text.trim(),
          appId: _appIdController.text.trim(),
          isDebugMode: true,
          userIdProvider: () => 'test_user_${DateTime.now().millisecond}',
          sidProvider: () => 'test_sid_${DateTime.now().millisecond}',
          appVersionProvider: () => '1.0.0',
          deviceProvider: () => 'flutter_test_device',
          systemVersionProvider: () => 'test_os_1.0',
          environmentProvider: () => 'test',
          errorReceivers: ['test@example.com'],
          queueMaxSize: 100,
        ),
      );
      setState(() => _initialized = true);
      _addLog('初始化成功');
    } catch (e) {
      _addLog('初始化失败: $e');
    }
  }

  Future<void> _sendEcho() async {
    if (!_initialized) {
      _addLog('请先初始化');
      return;
    }
    final content = _echoContentController.text.trim();
    if (content.isEmpty) {
      _addLog('请输入 echo 内容');
      return;
    }
    try {
      await XBEchoLogger.instance.echo(content: content);
      _addLog('echo 发送成功: $content');
    } catch (e) {
      _addLog('echo 发送失败: $e');
    }
  }

  Future<void> _sendErr() async {
    if (!_initialized) {
      _addLog('请先初始化');
      return;
    }
    final content = _errContentController.text.trim();
    if (content.isEmpty) {
      _addLog('请输入 err 内容');
      return;
    }
    try {
      _errorSendCount++;
      await XBEchoLogger.instance.err(content: content);
      _addLog('err 发送成功 (第$_errorSendCount次): $content');
    } catch (e) {
      _addLog('err 发送失败: $e');
    }
  }

  Future<void> _sendErrDedup() async {
    if (!_initialized) {
      _addLog('请先初始化');
      return;
    }
    final content = _errContentController.text.trim();
    if (content.isEmpty) {
      _addLog('请输入 err 内容');
      return;
    }
    _addLog('连续发送3次相同 err，验证去重...');
    for (int i = 0; i < 3; i++) {
      _errorSendCount++;
      await XBEchoLogger.instance.err(content: content);
      _addLog('  err 第${i + 1}次调用完成 (实际发送次数=$_errorSendCount)');
    }
  }

  Future<void> _checkConnectivity() async {
    if (!_initialized) {
      _addLog('请先初始化');
      return;
    }
    try {
      _addLog('正在检测连通性...');
      final ok = await XBEchoLogger.instance.checkConnectivity();
      _addLog('连通性检测: ${ok ? "可达" : "不可达"}');
    } catch (e) {
      _addLog('连通性检测异常: $e');
    }
  }

  void _showPendingCount() {
    if (!_initialized) {
      _addLog('请先初始化');
      return;
    }
    _addLog('队列待发送数量: ${XBEchoLogger.instance.pendingCount}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('XBEchoLogger 测试')),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sectionTitle('初始化配置'),
                  _buildTextField('Echo Host', _echoHostController),
                  const SizedBox(height: 8),
                  _buildTextField('App ID', _appIdController),
                  const SizedBox(height: 8),
                  _buildButton(
                    _initialized ? '已初始化' : '初始化',
                    _initialized ? null : _initLogger,
                    color: _initialized ? Colors.grey : Colors.blue,
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle('Echo 日志上报 (队列)'),
                  _buildTextField('日志内容', _echoContentController),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildButton('发送 Echo', _sendEcho,
                            color: Colors.teal),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildButton('查看队列数量', _showPendingCount,
                            color: Colors.orange),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle('Err 错误上报 (直接发送 + 去重)'),
                  _buildTextField('错误内容', _errContentController),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildButton('发送 Err', _sendErr,
                            color: Colors.red),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildButton('Err 去重测试 (连续3次)',
                            _sendErrDedup,
                            color: Colors.deepOrange),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle('连通性检测'),
                  _buildButton('检测服务器连通性', _checkConnectivity,
                      color: Colors.purple),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          _buildLogPanel(),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildTextField(String label, TextEditingController controller) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _buildButton(String label, VoidCallback? onPressed,
      {Color color = Colors.blue}) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }

  Widget _buildLogPanel() {
    return Container(
      height: 200,
      color: Colors.grey[900],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.grey[800],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '操作日志',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                TextButton(
                  onPressed: () => setState(() => _logs.clear()),
                  child: const Text('清空',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                ),
              ],
            ),
          ),
          Expanded(
            child: _logs.isEmpty
                ? const Center(
                    child: Text('暂无日志',
                        style: TextStyle(color: Colors.white54)),
                  )
                : ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 2),
                        child: Text(
                          _logs[index],
                          style:
                              const TextStyle(color: Colors.greenAccent, fontSize: 12),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
