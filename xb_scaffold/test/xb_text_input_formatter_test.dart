import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  group('XBNumberTextInputFormatter（只允许数字）', () {
    final formatter = XBNumberTextInputFormatter();

    test('过滤非数字字符', () {
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: ''),
        const TextEditingValue(text: 'a1b2c3'),
      );
      expect(result.text, '123');
    });

    test('纯数字原样保留', () {
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: '12'),
        const TextEditingValue(text: '123'),
      );
      expect(result.text, '123');
    });

    test('光标落在末尾', () {
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: ''),
        const TextEditingValue(text: 'a1'),
      );
      expect(result.selection.isCollapsed, isTrue);
      expect(result.selection.extentOffset, 1);
    });
  });

  group('XBDoubleTextInputFormatter（数字 + 小数点）', () {
    final formatter = XBDoubleTextInputFormatter();

    test('合法数字与小数保留', () {
      for (final text in ['1', '12', '1.5', '0.25', '.', '1.']) {
        final result = formatter.formatEditUpdate(
          const TextEditingValue(text: ''),
          TextEditingValue(text: text),
        );
        expect(result.text, text, reason: '"$text" 应保留');
      }
    });

    test('非法输入回退旧值', () {
      const old = TextEditingValue(text: '1.5');
      for (final text in ['1.2.3', 'a', '1a.2']) {
        final result = formatter.formatEditUpdate(
          old,
          TextEditingValue(text: text),
        );
        expect(result, old, reason: '"$text" 非法应回退旧值');
      }
    });
  });

  group('XBNumberLimitTextInputFormatter（限制范围）', () {
    final formatter = XBNumberLimitTextInputFormatter(min: 1, max: 100);

    test('范围内原样保留', () {
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: '50'),
        const TextEditingValue(text: '55'),
      );
      expect(result.text, '55');
    });

    test('超上限截断为 max', () {
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: '99'),
        const TextEditingValue(text: '150'),
      );
      expect(result.text, '100');
    });

    test('低于下限提升为 min', () {
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: '5'),
        const TextEditingValue(text: '0'),
      );
      expect(result.text, '1');
    });

    test('非数字回退旧值', () {
      const old = TextEditingValue(text: '50');
      final result = formatter.formatEditUpdate(
        old,
        const TextEditingValue(text: 'abc'),
      );
      expect(result, old);
    });

    test('空值直接放行（允许清空再输入）', () {
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: '50'),
        const TextEditingValue(text: ''),
      );
      expect(result.text, '');
    });
  });

  group('XBTrimTextInputFormatter（去首尾空格）', () {
    final formatter = XBTrimTextInputFormatter();

    test('去除首尾空格', () {
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: 'hi'),
        const TextEditingValue(text: '  hi  '),
      );
      expect(result.text, 'hi');
    });

    test('中间空格保留', () {
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: 'a'),
        const TextEditingValue(text: ' a b '),
      );
      expect(result.text, 'a b');
    });
  });

  group('XBMaxLengthTextInputFormatter（限制长度）', () {
    final formatter = XBMaxLengthTextInputFormatter(3);

    test('未超长原样保留', () {
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: '12'),
        const TextEditingValue(text: '123'),
      );
      expect(result.text, '123');
    });

    test('超长回退旧值', () {
      const old = TextEditingValue(text: '123');
      final result = formatter.formatEditUpdate(
        old,
        const TextEditingValue(text: '1234'),
      );
      expect(result, old);
    });
  });
}
