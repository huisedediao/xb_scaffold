// 「错误 widget → 源码位置」解析器单测。
//
// 输入全部取自 Flutter 真实错误输出（informationCollector 的渲染结果），
// 重点是：路径含空格/百分号编码、全文里 framework 帧比业务帧更靠前、
// 没有位置信息时不能瞎猜。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/core/xb_ume_error_source.dart';

void main() {
  test('溢出错误：从 relevant error-causing widget 段取到业务位置', () {
    const text = '''
The following assertion was thrown during layout:
A RenderFlex overflowed by 27 pixels on the right.

The relevant error-causing widget was:
  Row Row:file:///Users/me/proj/lib/pages/order_row.dart:42:12

When the exception was thrown, this was the stack:
#0      RenderFlex.performLayout (file:///sdk/flutter/lib/src/rendering/flex.dart:1092:17)
''';
    final src = XBUmeErrorSource.parse(text);
    expect(src, isNotNull);
    expect(src!.widgetType, 'Row');
    expect(src.file, '/Users/me/proj/lib/pages/order_row.dart');
    expect(src.line, 42);
    expect(src.column, 12);
  });

  test('framework 帧排在前面时仍优先取 widget 段，不抓 flex.dart', () {
    const text = '''
#0      RenderFlex.performLayout (file:///sdk/flutter/lib/src/rendering/flex.dart:1092:17)
#1      RenderObject.layout (file:///sdk/flutter/lib/src/rendering/object.dart:2611:17)

The relevant error-causing widget was:
  Column Column:file:///Users/me/proj/lib/home.dart:30:9
''';
    final src = XBUmeErrorSource.parse(text);
    expect(src, isNotNull);
    expect(src!.widgetType, 'Column');
    expect(src.file, endsWith('/lib/home.dart'));
    expect(src.line, 30);
    expect(src.column, 9);
  });

  test('路径含百分号编码时还原成真实路径', () {
    const text = '  Row Row:file:///Users/me/My%20App/lib/pages/order_row.dart:42:12';
    final src = XBUmeErrorSource.parse(text);
    expect(src, isNotNull);
    expect(src!.file, '/Users/me/My App/lib/pages/order_row.dart');
  });

  test('路径含空格（未编码）也能整段取到', () {
    const text = '  Row Row:file:///Users/me/My App/lib/a.dart:7:3';
    final src = XBUmeErrorSource.parse(text);
    expect(src, isNotNull);
    expect(src!.file, '/Users/me/My App/lib/a.dart');
    expect(src.line, 7);
  });

  test('只有位置没有 widget 名时，类型为空串而不是整行', () {
    const text = '  KeyedSubtree:file:///tmp/a.dart:7:3';
    final src = XBUmeErrorSource.parse(text);
    expect(src, isNotNull);
    expect(src!.widgetType, 'KeyedSubtree');
    expect(src.line, 7);
  });

  test('没有任何位置信息时返回 null（不编造）', () {
    expect(XBUmeErrorSource.parse('A RenderFlex overflowed by 27 pixels.'), isNull);
    expect(XBUmeErrorSource.parse(''), isNull);
    expect(XBUmeErrorSource.parse(null), isNull);
  });

  test('非 .dart 的 file 链接不算位置', () {
    expect(
      XBUmeErrorSource.parse('see file:///Users/me/notes.txt:3:1'),
      isNull,
    );
  });

  test('CRLF 换行也能解析', () {
    const text = 'The relevant error-causing widget was:\r\n'
        '  Text Text:file:///Users/me/app/lib/a.dart:11:5\r\n';
    final src = XBUmeErrorSource.parse(text);
    expect(src, isNotNull);
    expect(src!.widgetType, 'Text');
    expect(src.file, '/Users/me/app/lib/a.dart');
    expect(src.line, 11);
  });
}
