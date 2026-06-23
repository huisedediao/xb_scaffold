import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBLogTestPage extends StatelessWidget {
  const XBLogTestPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('XB Print 日志测试')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('短文本测试'),
          _buildButton('xbLog (默认)', () => xbLog('这是一条普通日志')),
          _buildButton('xbDebug (默认)', () => xbDebug('这是一条调试日志')),
          _buildButton('xbInfo (蓝色)', () => xbInfo('这是一条信息日志')),
          _buildButton('xbWarn (黄色)', () => xbWarn('这是一条警告日志')),
          _buildButton('xbError (红色)', () => xbError('这是一条错误日志')),
          _buildButton('xbFatal (红色)', () => xbFatal('这是一条致命错误日志')),
          _buildButton(
            'xbUnDisappear (红色, 不受 kDebugMode 限制)',
            () => xbUnDisappear('这是一条始终显示的日志'),
          ),
          const SizedBox(height: 24),
          _sectionTitle('长文本测试 (分块打印)'),
          _buildButton(
            'xbLog 长文本 (900 字符)',
            () => xbLog(_longText(900)),
          ),
          _buildButton(
            'xbWarn 长文本 (900 字符)',
            () => xbWarn(_longText(900)),
          ),
          _buildButton(
            'xbError 超长文本 (2100 字符)',
            () => xbError(_longText(2100)),
          ),
          _buildButton(
            'xbFatal 超长文本 (3000 字符)',
            () => xbFatal(_longText(3000)),
          ),
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

  Widget _buildButton(String label, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ElevatedButton(
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }

  String _longText(int length) {
    final buffer = StringBuffer();
    for (int i = 0; i < length / 80; i++) {
      final line = 'Line ${i.toString().padLeft(4, '0')}: ';
      buffer.write(line);
      buffer.write('B' * (80 - line.length));
    }
    return buffer.toString().substring(0, length);
  }
}
