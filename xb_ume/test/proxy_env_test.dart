import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/process.dart' show execEnvironment;
import '../bin/src/device/proxy_env.dart';

void main() {
  group('withLoopbackNoProxy', () {
    test('空环境补三条回环地址，小写与大写键一致', () {
      final env = withLoopbackNoProxy(<String, String>{});
      expect(env['no_proxy'], '127.0.0.1,localhost,::1');
      expect(env['NO_PROXY'], '127.0.0.1,localhost,::1');
    });

    test('保留已有值并去重（大小写不敏感）', () {
      final env = withLoopbackNoProxy(<String, String>{
        'no_proxy': '10.0.0.0/8, 127.0.0.1',
        'NO_PROXY': 'foo.local,LocalHost',
      });
      expect(
        env['no_proxy'],
        '10.0.0.0/8,127.0.0.1,foo.local,LocalHost,::1',
      );
      expect(env['NO_PROXY'], env['no_proxy']);
    });
  });

  test('execEnvironment 给子进程补回环 no_proxy', () {
    final env = execEnvironment();
    expect(env['no_proxy'], contains('127.0.0.1'));
    expect(env['no_proxy'], contains('localhost'));
    expect(env['no_proxy'], contains('::1'));
    expect(env['NO_PROXY'], env['no_proxy']);
  });
}
