import 'package:flutter/material.dart';

/// 截图遥控/场景录制的验收页：账号 + 密码 + 登录按钮。
/// 登录结果用固定文案展示，方便录制后回放断言。
class LoginDemoPage extends StatefulWidget {
  const LoginDemoPage({super.key});

  @override
  State<LoginDemoPage> createState() => _LoginDemoPageState();
}

class _LoginDemoPageState extends State<LoginDemoPage> {
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  String _message = '请输入账号和密码';
  bool _ok = false;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _login() {
    final user = _user.text.trim();
    final pass = _pass.text;
    setState(() {
      _ok = user.isNotEmpty && pass.isNotEmpty;
      _message = _ok ? '登录成功：$user' : '请输入账号和密码';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login Demo')),
      body: Center(
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _user,
                decoration: const InputDecoration(
                  labelText: '账号',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pass,
                obscureText: true,
                onSubmitted: (_) => _login(),
                decoration: const InputDecoration(
                  labelText: '密码',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _login,
                  child: const Text('登录'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _message,
                key: const ValueKey('login-message'),
                textAlign: TextAlign.center,
                style: TextStyle(color: _ok ? Colors.green : Colors.red),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回首页'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
